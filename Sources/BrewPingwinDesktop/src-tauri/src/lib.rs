#![allow(dead_code, unused_variables)]

mod services;

use services::agent_discovery::AgentEntryApi;
use services::approval_gate::{ApprovalGate, ApprovalMode, PendingApproval};
use services::http_server::{AppState, CommandStore};
use services::model_prefs::ModelPrefs;
use services::pairing_store::PairingStore;
use services::terminal_state::{AgentStatus, AgentTerminalState, OutputType, TerminalManager};
use services::workdir_prefs::WorkdirPrefs;
use std::sync::Arc;
use tauri::{Emitter, Manager};
use tokio::sync::RwLock;

const DEFAULT_PORT: u16 = 8787;

/// 三段式运行时状态。UI / 托盘用它来判断指示灯颜色与文案。
///
/// - `Idle`：从未启动（默认）。
/// - `Starting`：进程已起来，但 HTTP 服务还没 listen 完。
///   这一段是启动最慢的环节（端口绑定 + mDNS 广播），可能持续数秒。
///   UI 在此期间显示灰点 + "Starting…"，避免被误判为离线。
/// - `Online`：HTTP 服务已开始 accept，可以接受手机端的命令。
/// - `Offline`：启动失败（端口全部被占用等）。
///
/// 与 macOS `DesktopCore.RuntimeState` 语义一致。
/// NOTE: macOS 端靠轮询 `/api/status` 感知状态；Windows 端 HTTP 服务就长在本进程里，
/// 因此直接在服务就绪 / 失败时改写状态，行为等价但不需要轮询。
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RuntimeState {
    Idle,
    Starting,
    Online,
    Offline,
}

/// Desktop core state accessible from Tauri commands.
pub struct DesktopCore {
    pub state: AppState,
    pub http_port: Arc<RwLock<u16>>,
    pub mdns_running: Arc<RwLock<bool>>,
    pub server_handle: Arc<RwLock<Option<tokio::task::JoinHandle<()>>>>,
    pub lan_ip: Arc<RwLock<String>>,
    pub terminal: TerminalManager,
    /// 三段式运行时状态。
    /// 用 `std::sync::RwLock`：托盘菜单事件是同步上下文，不能 await。
    pub runtime_state: Arc<std::sync::RwLock<RuntimeState>>,
}

// ─── Pairing payload ─────────────────────────────────────────────────────────

/// 配对信息（供桌面 UI 展示配对码 + 二维码）。
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingInfo {
    /// 当前仍有效的配对码；未揭示 / 已过期 / 已被消费时为 null。
    pub code: Option<String>,
    /// 配对码过期时刻（ISO8601）。
    pub expires_at: Option<String>,
    /// `brewping://pair?...` 深链，iPhone 扫码后可直接配对。
    pub url: Option<String>,
    pub device_id: String,
    pub device_name: String,
    pub host: String,
    pub port: u16,
}

/// 构造 `brewping://pair?host=&port=&deviceId=&name=&osType=&code=` 深链。
///
/// host 取自局域网 IP，端口取自 HTTP 端口。
/// `code` 可选：iPhone 端打开链接时如果带 code 会直接发起配对；不带则弹 pair sheet。
/// 与 macOS `DesktopCore.pairingURL(code:)` 的字段与顺序保持一致。
///
/// `osType` 固定为 `windows`：iPhone 端据此把设备标成 Windows，
/// 而不是回落成默认的 Mac（见 `ios/BrewPing/PairingURLHandler.swift`）。
fn pairing_url(
    lan_ip: &str,
    port: u16,
    device_id: &str,
    device_name: &str,
    code: Option<&str>,
) -> Option<String> {
    if lan_ip.is_empty() || lan_ip == "0.0.0.0" || port == 0 {
        return None;
    }
    let encode = services::pairing_store::percent_encode;
    let mut url = format!(
        "brewping://pair?host={}&port={}&deviceId={}&name={}&osType=windows",
        encode(lan_ip),
        port,
        encode(device_id),
        encode(device_name)
    );
    if let Some(code) = code {
        if !code.is_empty() {
            url.push_str(&format!("&code={}", encode(code)));
        }
    }
    Some(url)
}

async fn build_pairing_info(core: &DesktopCore) -> PairingInfo {
    let port = *core.http_port.read().await;
    let lan_ip = core.lan_ip.read().await.clone();
    let device_name = services::device_identity::get_device_name();
    let device_id = core.state.identity.device_id.clone();

    // 只有仍有效的码才会被展示（不点开就不该存在）。
    let code = core.state.pairing.current_code();
    let expires_at = if code.is_some() {
        core.state
            .pairing
            .pairing_code_expiry()
            .map(|expiry| expiry.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
    } else {
        None
    };
    let url = pairing_url(&lan_ip, port, &device_id, &device_name, code.as_deref());

    PairingInfo {
        code,
        expires_at,
        url,
        device_id,
        device_name,
        host: lan_ip,
        port,
    }
}

// ─── Tauri Commands ──────────────────────────────────────────────────────────

#[tauri::command]
async fn get_status(core: tauri::State<'_, DesktopCore>) -> Result<serde_json::Value, String> {
    let host = services::device_identity::get_device_name();
    let default_agent = core.state.default_agent.read().await.clone();
    let session = core.state.session.read().await.clone();
    let agents = core.state.agents.read().await.clone();
    let port = *core.http_port.read().await;
    let lan_ip = core.lan_ip.read().await.clone();
    let mdns = *core.mdns_running.read().await;
    let active_agent_id = core.terminal.active_agent_id.read().await.clone();
    let device_id = core.state.identity.device_id.clone();

    // 同步锁在独立作用域内释放，避免跨 await 持有（std guard 不是 Send）。
    let runtime_state = {
        core.runtime_state
            .read()
            .map(|s| *s)
            .unwrap_or(RuntimeState::Idle)
    };

    let api_agents: Vec<AgentEntryApi> = agents
        .iter()
        .map(|a| {
            let mut api = AgentEntryApi::from(a);
            api.active = api.installed && a.id == default_agent;
            api.workdir = core.state.workdir_prefs.get(&a.id);
            api
        })
        .collect();

    Ok(serde_json::json!({
        "host": host,
        "defaultAgent": default_agent,
        "session": session,
        "agents": api_agents,
        "port": port,
        "lanIp": lan_ip,
        "mdnsRunning": mdns,
        "platform": std::env::consts::OS,
        "version": "0.1.0",
        "deviceId": device_id,
        "activeAgentId": active_agent_id,
        "runtimeState": runtime_state,
    }))
}

#[tauri::command]
async fn get_agents(core: tauri::State<'_, DesktopCore>) -> Result<Vec<AgentEntryApi>, String> {
    let agents = core.state.agents.read().await.clone();
    let default_agent = core.state.default_agent.read().await.clone();
    let api_agents: Vec<AgentEntryApi> = agents
        .iter()
        .map(|a| {
            let mut api = AgentEntryApi::from(a);
            api.active = api.installed && a.id == default_agent;
            api
        })
        .collect();
    Ok(api_agents)
}

#[tauri::command]
async fn set_default_agent(
    core: tauri::State<'_, DesktopCore>,
    agent: String,
) -> Result<String, String> {
    let mut default = core.state.default_agent.write().await;
    *default = agent.clone();
    Ok(agent)
}

#[tauri::command]
async fn get_lan_ip(core: tauri::State<'_, DesktopCore>) -> Result<String, String> {
    let ip = core.lan_ip.read().await.clone();
    Ok(ip)
}

#[tauri::command]
async fn get_port(core: tauri::State<'_, DesktopCore>) -> Result<u16, String> {
    let port = *core.http_port.read().await;
    Ok(port)
}

// ─── Pairing commands (对齐 macOS MenuBarView 的配对区块) ─────────────────────

/// 读取当前配对信息（**不会**生成新码，用于界面初始化）。
#[tauri::command]
async fn get_pairing_info(core: tauri::State<'_, DesktopCore>) -> Result<PairingInfo, String> {
    Ok(build_pairing_info(&core).await)
}

/// 显示配对码：生成（或复用未过期的）配对码，并同步到托盘。
#[tauri::command]
async fn reveal_pairing_code(
    app: tauri::AppHandle,
    core: tauri::State<'_, DesktopCore>,
) -> Result<PairingInfo, String> {
    let code = core.state.pairing.issue_pairing_code();
    services::tray::update_tray_pairing(&app, Some(&code));
    Ok(build_pairing_info(&core).await)
}

/// 强制轮换配对码（旧的立即作废，已换过 token 的设备不受影响）。
#[tauri::command]
async fn regenerate_pairing_code(
    app: tauri::AppHandle,
    core: tauri::State<'_, DesktopCore>,
) -> Result<PairingInfo, String> {
    let code = core.state.pairing.regenerate_pairing_code();
    services::tray::update_tray_pairing(&app, Some(&code));
    Ok(build_pairing_info(&core).await)
}

// ─── Approval commands (对齐 macOS ApprovalGate) ─────────────────────────────

#[tauri::command]
async fn get_approval_mode(core: tauri::State<'_, DesktopCore>) -> Result<String, String> {
    Ok(core.state.approval.mode().as_str().to_string())
}

#[tauri::command]
async fn set_approval_mode(
    core: tauri::State<'_, DesktopCore>,
    mode: String,
) -> Result<String, String> {
    let parsed = ApprovalMode::parse(&mode)
        .ok_or_else(|| format!("unknown approval mode: {mode}"))?;
    core.state.approval.set_mode(parsed);
    log::info!("Approval mode changed to: {}", parsed.as_str());
    Ok(parsed.as_str().to_string())
}

#[tauri::command]
async fn get_pending_approvals(
    core: tauri::State<'_, DesktopCore>,
) -> Result<Vec<PendingApproval>, String> {
    Ok(core.state.approval.pending_approvals())
}

/// 桌面端直接处理一条挂起命令（与手机端 `/api/approvals/:id` 等价）。
#[tauri::command]
async fn decide_approval(
    core: tauri::State<'_, DesktopCore>,
    id: String,
    action: String,
) -> Result<String, String> {
    let resolution = core
        .state
        .approval
        .decide(&id, &action)
        .ok_or_else(|| "unknown or expired approval".to_string())?;

    match resolution.action.as_str() {
        "deny" => Ok("denied".to_string()),
        "approve" | "always_approve" => {
            let text = resolution
                .text
                .ok_or_else(|| "approval has no command text".to_string())?;
            // 复用 HTTP 层同一条执行路径，保证回显与状态机一致。
            match services::http_server::submit_command(&core.state, &text).await {
                Ok(_) => Ok("submitted".to_string()),
                Err(status) => Err(format!("no active session (HTTP {})", status.as_u16())),
            }
        }
        _ => Err("unknown action".to_string()),
    }
}

/// Get the terminal state for all agents.
#[tauri::command]
async fn get_terminal_state(
    core: tauri::State<'_, DesktopCore>,
) -> Result<Vec<AgentTerminalState>, String> {
    let map = core.terminal.agents.read().await;
    let mut states: Vec<AgentTerminalState> = map.values().cloned().collect();
    // Sort by agent ID for stable order
    states.sort_by(|a, b| a.agent_id.cmp(&b.agent_id));
    Ok(states)
}

/// Get the currently active agent ID.
#[tauri::command]
async fn get_active_agent_id(core: tauri::State<'_, DesktopCore>) -> Result<String, String> {
    let id = core.terminal.active_agent_id.read().await.clone();
    Ok(id)
}

/// Switch the active terminal agent (matches macOS switchToAgent).
#[tauri::command]
async fn switch_active_agent(
    core: tauri::State<'_, DesktopCore>,
    agent_id: String,
    app: tauri::AppHandle,
) -> Result<(), String> {
    {
        let mut active = core.terminal.active_agent_id.write().await;
        if *active == agent_id {
            return Ok(());
        }
        *active = agent_id.clone();
    }

    // Also update the HTTP server's default agent
    {
        let mut default = core.state.default_agent.write().await;
        *default = agent_id.clone();
    }

    log::info!("Active agent switched to: {}", agent_id);
    let _ = app.emit("active-agent-changed", &agent_id);
    Ok(())
}

/// Send a command to the active agent (matches macOS sendInput).
#[tauri::command]
async fn send_command(
    core: tauri::State<'_, DesktopCore>,
    text: String,
    app: tauri::AppHandle,
) -> Result<(), String> {
    let agent_id = core.terminal.active_agent_id.read().await.clone();

    // Ensure terminal state exists
    {
        let mut map = core.terminal.agents.write().await;
        if !map.contains_key(&agent_id) {
            let agents = core.state.agents.read().await;
            let name = agents
                .iter()
                .find(|a| a.id == agent_id)
                .map(|a| a.name.clone())
                .unwrap_or_else(|| agent_id.clone());
            map.insert(
                agent_id.clone(),
                AgentTerminalState::new(agent_id.clone(), name),
            );
        }
    }

    // Show user input
    {
        let mut map = core.terminal.agents.write().await;
        if let Some(state) = map.get_mut(&agent_id) {
            state.append_line(&format!("> {}", text), OutputType::System);
        }
    }
    let _ = app.emit("terminal-updated", ());

    // Route based on agent type
    if agent_id == "opencode" {
        // Session agent: route through session management
        let session = core.state.session.read().await;
        if session.is_none() {
            let mut map = core.terminal.agents.write().await;
            if let Some(state) = map.get_mut(&agent_id) {
                state.append_line("Error: no active session — start a session first", OutputType::Error);
            }
            let _ = app.emit("terminal-updated", ());
            return Ok(());
        }
        drop(session);

        let command_id = format!("cmd_{}", &uuid::Uuid::new_v4().to_string()[..8]);
        let agent_name = {
            let agents = core.state.agents.read().await;
            agents
                .iter()
                .find(|a| a.id == agent_id)
                .map(|a| a.name.clone())
                .unwrap_or_else(|| "OpenCode".to_string())
        };

        {
            let mut map = core.terminal.agents.write().await;
            if let Some(state) = map.get_mut(&agent_id) {
                state.append_line(
                    &format!("Message sent to {}", agent_name),
                    OutputType::System,
                );
            }
        }
        let _ = app.emit("terminal-updated", ());
        return Ok(());
    }

    // Non-session agent: run CLI executable
    let agents = core.state.agents.read().await;
    let agent_entry = agents.iter().find(|a| a.id == agent_id).cloned();
    drop(agents);

    let Some(agent) = agent_entry else {
        let mut map = core.terminal.agents.write().await;
        if let Some(state) = map.get_mut(&agent_id) {
            state.append_line(
                &format!("Error: agent '{}' not available", agent_id),
                OutputType::Error,
            );
        }
        let _ = app.emit("terminal-updated", ());
        return Ok(());
    };

    let Some(ref executable) = agent.executable else {
        let mut map = core.terminal.agents.write().await;
        if let Some(state) = map.get_mut(&agent_id) {
            state.append_line(
                &format!("Error: executable not found for {}", agent_id),
                OutputType::Error,
            );
            state.set_status(AgentStatus::Error);
        }
        let _ = app.emit("terminal-updated", ());
        return Ok(());
    };

    // Set running
    {
        let mut map = core.terminal.agents.write().await;
        if let Some(state) = map.get_mut(&agent_id) {
            state.set_status(AgentStatus::Running);
        }
    }
    let _ = app.emit("terminal-updated", ());

    // ★ cwd 预检（与 http_server::submit_command 同构，方案 §5.10 要求两处一致）：
    //   目录没了必须报 invalid_workdir，不能静默回退到进程 cwd，也不能笼统报
    //   process_exited。is_dir 在断开的网络盘上可能阻塞，所以放进 spawn_blocking。
    let selected_workdir = core.state.workdir_prefs.get(&agent_id);
    if let Some(dir) = selected_workdir.as_deref() {
        let probe = dir.to_string();
        let dir_ok = tokio::task::spawn_blocking(move || std::path::Path::new(&probe).is_dir())
            .await
            .unwrap_or(false);
        if !dir_ok {
            {
                let mut map = core.terminal.agents.write().await;
                if let Some(state) = map.get_mut(&agent_id) {
                    state.append_line(
                        &format!("Error: Workdir not available: {}", dir),
                        OutputType::Error,
                    );
                    state.set_status(AgentStatus::Error);
                }
            }
            let _ = app.emit("terminal-updated", ());
            return Ok(());
        }
    }

    let terminal = core.terminal.clone();
    let agent_id_clone = agent_id.clone();
    let executable_clone = executable.clone();
    let text_clone = text.clone();
    let workdir_clone = selected_workdir.clone();
    let app_clone = app.clone();

    // Use spawn_blocking for synchronous process execution
    tokio::task::spawn_blocking(move || {
        let mut cmd = std::process::Command::new(&executable_clone);
        cmd.arg(&text_clone)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        // ★ 关键一行：注入用户选定的工作目录（子进程级，不用 set_current_dir）。
        if let Some(dir) = workdir_clone.as_deref() {
            cmd.current_dir(dir);
        }

        // Add common PATH entries on Windows
        #[cfg(windows)]
        {
            if let Ok(path) = std::env::var("PATH") {
                let home = dirs::home_dir().unwrap_or_default();
                let extra = format!(
                    "{}\\.local\\bin;{}\\scoop\\shims",
                    home.display(),
                    home.display()
                );
                cmd.env("PATH", format!("{};{}", extra, path));
            }
        }

        // We need to block on async operations inside spawn_blocking
        let rt = tokio::runtime::Handle::current();

        match cmd.output() {
            Ok(output) => {
                let stdout = String::from_utf8_lossy(&output.stdout);
                let stderr = String::from_utf8_lossy(&output.stderr);

                let mut map = rt.block_on(terminal.agents.write());
                if let Some(state) = map.get_mut(&agent_id_clone) {
                    if output.status.success() {
                        let lines: Vec<&str> =
                            stdout.split('\n').collect();
                        for line in &lines {
                            if !line.is_empty() {
                                state.append_line(line, OutputType::Normal);
                            }
                        }
                        if stdout.trim().is_empty() {
                            state.append_line("(no output)", OutputType::System);
                        }
                    } else {
                        state.append_line(
                            &format!("Exit code: {}", output.status.code().unwrap_or(-1)),
                            OutputType::Error,
                        );
                        if !stderr.trim().is_empty() {
                            state.append_line(stderr.trim(), OutputType::Error);
                        }
                    }
                    state.set_status(AgentStatus::Idle);
                }
            }
            Err(e) => {
                let mut map = rt.block_on(terminal.agents.write());
                if let Some(state) = map.get_mut(&agent_id_clone) {
                    state.append_line(
                        &format!("Error: failed to start process: {}", e),
                        OutputType::Error,
                    );
                    state.set_status(AgentStatus::Error);
                }
            }
        }
        let _ = app_clone.emit("terminal-updated", ());
    });

    Ok(())
}

/// Clear the terminal output for an agent.
#[tauri::command]
async fn clear_terminal(
    core: tauri::State<'_, DesktopCore>,
    agent_id: String,
) -> Result<(), String> {
    let mut map = core.terminal.agents.write().await;
    if let Some(state) = map.get_mut(&agent_id) {
        state.clear_output();
    }
    Ok(())
}

// ─── App Entry Point ─────────────────────────────────────────────────────────

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    env_logger::init();

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .setup(|app| {
            // Load device identity
            let identity = services::device_identity::load_or_create();
            let device_name = services::device_identity::get_device_name();

            // Detect LAN IP
            let lan_ip = services::lan_address::detect_primary_lan()
                .map(|info| info.ip.to_string())
                .unwrap_or_else(|| "0.0.0.0".to_string());

            log::info!(
                "Device: {} ({}) on {}",
                device_name,
                identity.device_id,
                lan_ip
            );

            // Discover agents
            let agents = services::agent_discovery::discover();
            log::info!(
                "Discovered {} agents",
                agents.iter().filter(|a| a.installed).count()
            );

            // Determine default agent
            let default_agent = agents
                .iter()
                .find(|a| a.installed && a.id == "opencode")
                .or_else(|| agents.iter().find(|a| a.installed))
                .map(|a| a.id.clone())
                .unwrap_or_else(|| "opencode".to_string());

            // Create shared state
            let terminal = TerminalManager::new();
            let command_store = CommandStore::new();
            // 配对与授权是进程内唯一实例：HTTP 层（手机端）与桌面前端共用同一份状态。
            let pairing = Arc::new(PairingStore::new());
            let approval = Arc::new(ApprovalGate::new());
            // 模型偏好同理：手机端写入、执行命令时读取，必须是同一份。
            let model_prefs = Arc::new(ModelPrefs::new());
            // 工作目录偏好同理：手机端选目录、执行命令时注入 cwd，必须是同一份。
            let workdir_prefs = Arc::new(WorkdirPrefs::new());

            let app_state = AppState {
                identity: identity.clone(),
                lan_ip: lan_ip.clone(),
                port: DEFAULT_PORT,
                agents: Arc::new(RwLock::new(agents.clone())),
                default_agent: Arc::new(RwLock::new(default_agent.clone())),
                session: Arc::new(RwLock::new(None)),
                terminal: terminal.clone(),
                command_store: command_store.clone(),
                pairing: pairing.clone(),
                approval: approval.clone(),
                model_prefs: model_prefs.clone(),
                workdir_prefs: workdir_prefs.clone(),
            };

            let core = DesktopCore {
                state: app_state.clone(),
                http_port: Arc::new(RwLock::new(DEFAULT_PORT)),
                mdns_running: Arc::new(RwLock::new(false)),
                server_handle: Arc::new(RwLock::new(None)),
                lan_ip: Arc::new(RwLock::new(lan_ip.clone())),
                terminal: terminal.clone(),
                // 立刻置 starting：让 UI 在服务 listen 完之前显示灰点 + "Starting…"，
                // 而不是停在 idle（会被渲染成红色 Offline，让用户以为没启起来）。
                runtime_state: Arc::new(std::sync::RwLock::new(RuntimeState::Starting)),
            };

            // Clone Arc handles BEFORE app.manage(core) consumes core
            let port_handle = core.http_port.clone();
            let server_handle = core.server_handle.clone();
            let mdns_flag = core.mdns_running.clone();
            let runtime_state_handle = core.runtime_state.clone();

            app.manage(core);

            // Initialize terminal states from discovered agents
            let terminal_clone = terminal.clone();
            let agents_clone = agents.clone();
            tauri::async_runtime::spawn(async move {
                terminal_clone.init_from_agents(&agents_clone).await;
            });

            // Setup system tray FIRST so TrayHandles are registered before async task
            services::tray::setup_system_tray(app.handle())?;
            services::tray::update_tray_status(app.handle(), "正在启动…", DEFAULT_PORT, &device_name, &lan_ip);
            // 若上次会话留下了未过期的配对码，保持托盘同步（不主动生成新码）。
            services::tray::update_tray_pairing(app.handle(), app_state.pairing.current_code().as_deref());

            // Start HTTP server in background
            let state_for_server = app_state.clone();
            let identity_clone = identity.clone();
            let device_name_clone = device_name.clone();
            let lan_ip_clone = lan_ip.clone();
            let default_agent_clone = default_agent.clone();

            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let lan_for_server = if lan_ip_clone != "0.0.0.0" {
                    Some(lan_ip_clone.as_str())
                } else {
                    None
                };

                match services::http_server::start_server(
                    state_for_server.clone(),
                    DEFAULT_PORT,
                    lan_for_server,
                )
                .await
                {
                    Ok((bound_port, srv_handle)) => {
                        // Update port
                        {
                            let mut p = port_handle.write().await;
                            *p = bound_port;
                        }
                        {
                            let mut h = server_handle.write().await;
                            *h = Some(srv_handle);
                        }

                        // Start mDNS broadcasting
                        let mut mdns = services::mdns_broadcast::MdnsBroadcaster::new();
                        let lan_for_mdns = if lan_ip_clone != "0.0.0.0" {
                            lan_ip_clone.clone()
                        } else {
                            "127.0.0.1".to_string()
                        };

                        let mdns_ok = match mdns.start(
                            bound_port,
                            &identity_clone.device_id,
                            &device_name_clone,
                            &lan_for_mdns,
                            &default_agent_clone,
                        ) {
                            Ok(()) => {
                                let mut flag = mdns_flag.write().await;
                                *flag = true;
                                log::info!("mDNS broadcasting started");
                                true
                            }
                            Err(e) => {
                                log::error!("mDNS start failed: {}", e);
                                false
                            }
                        };

                        // HTTP 服务已经在 accept 了 —— 这才算 online。
                        {
                            let mut state = runtime_state_handle
                                .write()
                                .expect("runtime state poisoned");
                            *state = RuntimeState::Online;
                        }
                        services::tray::update_tray_status(
                            &handle,
                            if mdns_ok { "在线" } else { "在线（mDNS 失败）" },
                            bound_port,
                            &device_name_clone,
                            &lan_ip_clone,
                        );
                        let _ = handle.emit("runtime-state-changed", "online");

                        std::mem::forget(mdns);
                    }
                    Err(e) => {
                        log::error!("HTTP server failed: {}", e);
                        {
                            let mut state = runtime_state_handle
                                .write()
                                .expect("runtime state poisoned");
                            *state = RuntimeState::Offline;
                        }
                        services::tray::update_tray_status(&handle, "启动失败", 0, &device_name_clone, "0.0.0.0");
                        let _ = handle.emit("runtime-state-changed", "offline");
                    }
                }
            });

            Ok(())
        })
        .on_window_event(|window, event| {
            // Hide to tray instead of closing
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                let _ = window.hide();
                api.prevent_close();
            }
        })
        .invoke_handler(tauri::generate_handler![
            get_status,
            get_agents,
            set_default_agent,
            get_lan_ip,
            get_port,
            get_pairing_info,
            reveal_pairing_code,
            regenerate_pairing_code,
            get_approval_mode,
            set_approval_mode,
            get_pending_approvals,
            decide_approval,
            get_terminal_state,
            get_active_agent_id,
            switch_active_agent,
            send_command,
            clear_terminal,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    use super::pairing_url;

    // TC-LB-01  配对深链必须带上 osType=windows
    //
    // 不带的话 iPhone 只能猜，会把 Windows 主机在设备列表里标成 Mac
    // （iOS 侧回落到 `DeviceOSType.parse(nil) == .mac`）。
    #[test]
    fn pairing_url_declares_windows_os_type() {
        let url = pairing_url("192.168.3.93", 8787, "bp_win_8e0c3402", "DESKTOP-T9KL6K9", Some("881989"))
            .expect("lan_ip/port 合法时必须给出 URL");
        assert!(url.starts_with("brewping://pair?"), "URL 前缀不对: {url}");
        assert!(url.contains("osType=windows"), "必须声明主机类型: {url}");
        assert!(url.contains("host=192.168.3.93"));
        assert!(url.contains("deviceId=bp_win_8e0c3402"));
        assert!(url.ends_with("&code=881989"), "code 排最后: {url}");
    }

    // TC-LB-02  设备名含空格/中文时必须百分号编码，且不带 code 时不出现空参数
    #[test]
    fn pairing_url_encodes_name_and_omits_empty_code() {
        let url = pairing_url("100.96.193.117", 8787, "bp_win_1", "我的 电脑", None)
            .expect("应当生成 URL");
        assert!(!url.contains(" 电脑"), "名字必须编码: {url}");
        assert!(url.contains("name=%E6%88%91%E7%9A%84%20%E7%94%B5%E8%84%91"), "编码结果不对: {url}");
        assert!(!url.contains("code="), "无 code 时不应出现该参数: {url}");
    }

    // TC-LB-03  边界：无局域网 IP / 端口为 0 时不给链接（宁可不显示二维码）
    #[test]
    fn pairing_url_requires_routable_target() {
        assert!(pairing_url("", 8787, "id", "name", None).is_none());
        assert!(pairing_url("0.0.0.0", 8787, "id", "name", None).is_none());
        assert!(pairing_url("192.168.3.93", 0, "id", "name", None).is_none());
    }
}
