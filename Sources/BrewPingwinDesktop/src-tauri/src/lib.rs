#![allow(dead_code, unused_variables)]

mod services;

use services::agent_discovery::AgentEntryApi;
use services::approval_gate::{ApprovalGate, ApprovalMode};
use services::conversation_store::ConversationStore;
use services::http_server::{AppState, CommandStore};
use services::model_prefs::ModelPrefs;
use services::pairing_store::PairingStore;
use services::terminal_state::{AgentTerminalState, TerminalManager};
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
    // 多对话语义：session = active 对话渲染（与 HTTP /api/status 契约一致）
    let session = {
        let conv_id = core.state.active_conversation_id.read().await.clone();
        match conv_id.and_then(|id| core.state.conversations.get(&id)) {
            Some(conv) => {
                let agents = core.state.agents.read().await;
                let agent_name = agents
                    .iter()
                    .find(|a| a.id == conv.agent_id)
                    .map(|a| a.name.clone())
                    .unwrap_or_else(|| conv.agent_id.clone());
                Some(serde_json::json!({
                    "id": conv.id,
                    "agent": conv.agent_id,
                    "agentName": agent_name,
                    "status": "running",
                }))
            }
            None => None,
        }
    };
    let active_conversation_id = core.state.active_conversation_id.read().await.clone();
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
        "activeConversationId": active_conversation_id,
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

/// Send a command to a conversation (matches macOS sendInput).
///
/// 多对话路由（方案 §6.2）：`conversation_id` 缺省（前端草稿态）时创建新对话
/// 并激活；否则发进指定对话。执行复用 HTTP 层 `submit_command` 同一条路径
/// （写路径单一出口 + command_runner 唯一状态写入点）。返回对话 ID 供前端切换。
#[tauri::command]
async fn send_command(
    core: tauri::State<'_, DesktopCore>,
    text: String,
    conversation_id: Option<String>,
    app: tauri::AppHandle,
) -> Result<String, String> {
    let text = text.trim().to_string();
    if text.is_empty() {
        return Err("text is empty".to_string());
    }

    // 解析目标对话：显式指定 → 校验存在且未归档；缺省 → 新建并激活。
    let conv_id = match conversation_id.as_deref() {
        Some(cid) => {
            let conv = core
                .state
                .conversations
                .get(cid)
                .ok_or_else(|| format!("conversation not found: {cid}"))?;
            if conv.archived {
                return Err("conversation is archived — restore it first".to_string());
            }
            // 桌面发消息 = 把该对话设为当前对话（与 UI 视图一致）
            {
                let mut active = core.state.active_conversation_id.write().await;
                if active.as_deref() != Some(cid) {
                    *active = Some(conv.id.clone());
                    let _ = app.emit("active-conversation-changed", conv.id.clone());
                }
            }
            conv.id
        }
        None => {
            let agent_id = core.terminal.active_agent_id.read().await.clone();
            let conv = core.state.conversations.create(&agent_id);
            {
                let mut active = core.state.active_conversation_id.write().await;
                *active = Some(conv.id.clone());
            }
            log::info!("Draft materialized as conversation {}", conv.id);
            let _ = app.emit("conversations-changed", serde_json::json!({ "id": conv.id }));
            let _ = app.emit("active-conversation-changed", conv.id.clone());
            conv.id
        }
    };

    match services::http_server::submit_command(
        &core.state,
        &text,
        Some(&conv_id),
        None,
        Some("desktop"),
    )
    .await
    {
        Ok(_) => Ok(conv_id),
        Err(status) => Err(format!("submit failed (HTTP {})", status.as_u16())),
    }
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

/// List the models of an agent (desktop composer entry point).
///
/// Mirrors `http_server::handle_agent_models`: reads the real config files,
/// and includes the user's preferred model (if any). Unknown agents return Err.
#[tauri::command]
async fn get_agent_models(
    core: tauri::State<'_, DesktopCore>,
    agent_id: String,
) -> Result<serde_json::Value, String> {
    if !services::agent_config::is_known_agent(&agent_id) {
        return Err("unknown agent".to_string());
    }
    let config = services::agent_config::discover(&agent_id);
    let preferred = core.state.model_prefs.get(&agent_id);

    let providers: Vec<serde_json::Value> = config
        .providers
        .iter()
        .map(|provider| {
            let models: Vec<serde_json::Value> = provider
                .models
                .iter()
                .map(|model| {
                    serde_json::json!({
                        "id": model.id,
                        "name": model.name,
                        "available": model.available,
                        "isActive": model.is_active,
                        "isDefault": preferred.as_deref() == Some(model.id.as_str()),
                    })
                })
                .collect();
            let mut value = serde_json::json!({
                "id": provider.id,
                "name": provider.name,
                "models": models,
            });
            if let Some(base) = &provider.base_url {
                value["baseURL"] = serde_json::Value::String(base.clone());
            }
            value
        })
        .collect();

    Ok(serde_json::json!({
        "agentId": agent_id,
        "providers": providers,
        "activeModelId": config.active_model_id,
        "preferredModelId": preferred,
    }))
}

/// Set the user's preferred model for an agent (persisted in ~/.brewping).
///
/// Mirrors `handle_set_default_model`: does NOT rewrite the agent's config file,
/// only records the preference, which is passed as `--model <id>` when spawning.
#[tauri::command]
async fn set_default_model(
    core: tauri::State<'_, DesktopCore>,
    agent_id: String,
    model_id: Option<String>,
) -> Result<(), String> {
    if agent_id.trim().is_empty() {
        return Err("agentId is empty".to_string());
    }
    core.state.model_prefs.set(&agent_id, model_id.as_deref());
    log::info!("Default model for '{}' set to {:?}", agent_id, model_id);
    Ok(())
}

// ─── Conversation commands（多对话管理，方案 §5.2）────────────────────────────

/// 列出对话（列表页数据源；pinned 优先 + updated_at 降序已由 store 排好）。
#[tauri::command]
async fn list_conversations(
    core: tauri::State<'_, DesktopCore>,
    include_archived: Option<bool>,
) -> Result<Vec<services::conversation_store::ConversationSummary>, String> {
    Ok(core
        .state
        .conversations
        .list(include_archived.unwrap_or(false)))
}

/// 读取单个对话的完整转录。
#[tauri::command]
async fn get_conversation(
    core: tauri::State<'_, DesktopCore>,
    conversation_id: String,
) -> Result<services::conversation_store::Conversation, String> {
    core.state
        .conversations
        .get(&conversation_id)
        .ok_or_else(|| "conversation not found".to_string())
}

/// 改名（title_source = "manual"，此后永不被自动命名覆盖）。
#[tauri::command]
async fn rename_conversation(
    core: tauri::State<'_, DesktopCore>,
    conversation_id: String,
    title: String,
) -> Result<(), String> {
    core.state
        .conversations
        .patch(&conversation_id, Some(&title), None, None)
        .map(|_| ())
        .map_err(|e| e.to_string())
}

/// 归档 / 恢复。恢复前校验 workdir_override 目录仍存在（方案 §2-A8）。
/// 归档 active 对话时清除 active 指针（landing 态，不自动跳转）。
#[tauri::command]
async fn set_conversation_archived(
    core: tauri::State<'_, DesktopCore>,
    conversation_id: String,
    archived: bool,
    app: tauri::AppHandle,
) -> Result<(), String> {
    if archived {
        if let Some(conv) = core.state.conversations.get(&conversation_id) {
            if let Some(cmd) = &conv.latest_command_id {
                if core.state.command_store.is_in_flight(cmd).await {
                    return Err("conversation has a command in flight".to_string());
                }
            }
        }
    } else if let Some(conv) = core.state.conversations.get(&conversation_id) {
        if let Some(dir) = ConversationStore::workdir_missing(&conv) {
            return Err(format!(
                "workdir no longer exists: {dir} — change the working folder before restoring"
            ));
        }
    }

    core.state
        .conversations
        .patch(&conversation_id, None, Some(archived), None)
        .map_err(|e| e.to_string())?;

    if archived {
        let mut active = core.state.active_conversation_id.write().await;
        if active.as_deref() == Some(conversation_id.as_str()) {
            *active = None;
            let _ = app.emit("active-conversation-changed", serde_json::json!(null));
        }
    }
    let _ = app.emit("conversations-changed", serde_json::json!({ "id": conversation_id }));
    Ok(())
}

/// 删除（两段式：仅归档态可删）。
#[tauri::command]
async fn delete_conversation(
    core: tauri::State<'_, DesktopCore>,
    conversation_id: String,
    app: tauri::AppHandle,
) -> Result<(), String> {
    core.state
        .conversations
        .delete(&conversation_id)
        .map_err(|e| e.to_string())?;
    let _ = app.emit("conversations-changed", serde_json::json!({ "id": conversation_id }));
    Ok(())
}

/// 切换为当前对话（归档对话必须先恢复）。
#[tauri::command]
async fn activate_conversation(
    core: tauri::State<'_, DesktopCore>,
    conversation_id: String,
    app: tauri::AppHandle,
) -> Result<(), String> {
    let conv = core
        .state
        .conversations
        .get(&conversation_id)
        .ok_or_else(|| "conversation not found".to_string())?;
    if conv.archived {
        return Err("conversation is archived — restore it first".to_string());
    }
    {
        let mut active = core.state.active_conversation_id.write().await;
        *active = Some(conv.id.clone());
    }
    let _ = app.emit("active-conversation-changed", conv.id.clone());
    Ok(())
}

/// 置顶 / 取消置顶（一次 meta patch，无级联）。
#[tauri::command]
async fn toggle_pin_conversation(
    core: tauri::State<'_, DesktopCore>,
    conversation_id: String,
    pinned: bool,
    app: tauri::AppHandle,
) -> Result<(), String> {
    core.state
        .conversations
        .patch(&conversation_id, None, None, Some(pinned))
        .map_err(|e| e.to_string())?;
    let _ = app.emit("conversations-changed", serde_json::json!({ "id": conversation_id }));
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
            // 多对话仓库（方案 §4）：启动时做中断恢复 + 空对话清理。
            let conversations = Arc::new(ConversationStore::new());

            // 事件广播回调：把 tauri emit 包成通用 sink 注入 HTTP 层
            // （http_server / command_runner 不依赖 tauri 类型，见 EventSink 注释）。
            let event_app = app.handle().clone();
            let event_sink: services::http_server::EventSink = Arc::new(move |event, payload| {
                use tauri::Emitter;
                let _ = event_app.emit(event, payload);
            });

            let app_state = AppState {
                identity: identity.clone(),
                lan_ip: lan_ip.clone(),
                port: DEFAULT_PORT,
                agents: Arc::new(RwLock::new(agents.clone())),
                default_agent: Arc::new(RwLock::new(default_agent.clone())),
                conversations: conversations.clone(),
                active_conversation_id: Arc::new(RwLock::new(None)),
                terminal: terminal.clone(),
                command_store: command_store.clone(),
                pairing: pairing.clone(),
                approval: approval.clone(),
                model_prefs: model_prefs.clone(),
                workdir_prefs: workdir_prefs.clone(),
                app_events: Some(event_sink),
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
            get_terminal_state,
            get_active_agent_id,
            switch_active_agent,
            send_command,
            clear_terminal,
            get_agent_models,
            set_default_model,
            list_conversations,
            get_conversation,
            rename_conversation,
            set_conversation_archived,
            delete_conversation,
            activate_conversation,
            toggle_pin_conversation,
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
