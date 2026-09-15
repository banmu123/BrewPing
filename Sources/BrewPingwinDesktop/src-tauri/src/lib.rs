#![allow(dead_code, unused_variables)]

mod services;

use services::agent_discovery::AgentEntryApi;
use services::approval_gate::{ApprovalGate, ApprovalMode};
use services::cli_takeover::{CliTakeover, CliTakeoverInfo, CliKind};
use services::conversation_store::ConversationStore;
use services::http_server::{AppState, CommandStore};
use services::model_prefs::ModelPrefs;
use services::model_provider_store::{
    ModelProviderConfig, ModelProviderStore, ProviderView, StoredSnapshot,
};
use services::model_proxy::ModelProxyManager;
use services::pairing_store::PairingStore;
use services::terminal_state::{AgentTerminalState, TerminalManager};
use services::workdir_prefs::WorkdirPrefs;
use std::collections::HashMap;
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
    /// 环境安装会话状态（设置页「环境与 AI CLI」区块：本会话经 NVM 装好的 Node 版本）。
    pub env_setup: Arc<services::env_setup::EnvSetupState>,
    /// 模型供应商配置（多厂商接入，内置 cc-switch 能力）。
    pub model_providers: Arc<ModelProviderStore>,
    /// 模型转发代理管理器（按 model_providers 的开关/端口启停）。
    pub model_proxy: Arc<ModelProxyManager>,
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
    // 🚨 每次生成配对信息都重新探测 LAN IP（对齐 macOS 8839809）：启动时缓存的
    // lan_ip 在网络/网段切换后会过期（实测 Mac 从 192.168.0.x 切到 192.168.5.x 后，
    // QR 里仍是旧 IP → iPhone 配对请求根本到不了这台电脑，表现为扫码后一直转圈）。
    // 探测失败回落缓存值（离线/无网段时仍能展示信息，不 panic）。
    let lan_ip = match services::lan_address::detect_primary_lan() {
        Some(info) if !info.ip.is_unspecified() && !info.ip.is_loopback() => {
            let fresh = info.ip.to_string();
            {
                let mut cached = core.lan_ip.write().await;
                if fresh != *cached {
                    *cached = fresh.clone();
                }
            }
            fresh
        }
        _ => core.lan_ip.read().await.clone(),
    };
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
    // 草稿物化时绑定的目录（`conversation_id` 为 None 时生效；
    // 空串 = 明确不绑定）。已有对话的改绑走 `set_conversation_workdir`。
    workdir: Option<String>,
    // 草稿物化时固化的授权档位（`conversation_id` 为 None 时生效）。
    // 授权是对话级设置：不传 / 非法值 = 未设置（回落全局默认）。
    // 已有对话的改档位走 `set_conversation_approval_mode`。
    approval_mode: Option<String>,
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
            let conv = core.state.conversations.create_with_options(
                &agent_id,
                workdir.as_deref(),
                approval_mode.as_deref(),
            );
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
    let preferred_provider = core.state.model_prefs.get_provider(&agent_id);

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

    // 绑定有效性（G6）：preferredModelId 是否仍属于某个已发现 provider
    // （若设了 preferredProviderId 还需 provider 匹配）。换厂商后旧绑定悬空时，
    // 前端据此显示警示。
    let preferred_still_valid = preferred
        .as_deref()
        .map(|pid| {
            config.providers.iter().any(|p| {
                p.models.iter().any(|m| m.id == pid)
                    && preferred_provider
                        .as_deref()
                        .map_or(true, |pp| pp == p.id)
            })
        })
        .unwrap_or(false);

    Ok(serde_json::json!({
        "agentId": agent_id,
        "providers": providers,
        "activeModelId": config.active_model_id,
        "preferredModelId": preferred,
        "preferredProviderId": preferred_provider,
        "preferredStillValid": preferred_still_valid,
        // 配置指纹：前端把它并进"要不要重拉"的依赖里，配置一变就自动刷新
        // （否则用户在设置里加完厂商回到主界面，模型列表还是旧的）。
        "configVersion": config.config_version,
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
    provider_id: Option<String>,
) -> Result<(), String> {
    if agent_id.trim().is_empty() {
        return Err("agentId is empty".to_string());
    }
    core.state
        .model_prefs
        .set(&agent_id, model_id.as_deref(), provider_id.as_deref());
    log::info!(
        "Default model for '{}' set to {:?} (provider {:?})",
        agent_id,
        model_id,
        provider_id
    );
    Ok(())
}

// ─── Workdir 命令（composer 目录条；复用 folder_browser 的白名单与校验）───────

/// 某个 Agent 当前生效的工作目录（用户偏好；未设置时 None = CLI 默认 cwd）。
#[tauri::command]
async fn get_agent_workdir(
    core: tauri::State<'_, DesktopCore>,
    agent_id: String,
) -> Result<Option<String>, String> {
    Ok(core.state.workdir_prefs.get(&agent_id))
}

/// 设置 / 清除某个 Agent 的工作目录（经 `validate_workdir` 白名单校验）。
#[tauri::command]
async fn set_agent_workdir(
    core: tauri::State<'_, DesktopCore>,
    agent_id: String,
    path: Option<String>,
) -> Result<Option<String>, String> {
    match path.as_deref().map(str::trim) {
        None | Some("") => {
            core.state.workdir_prefs.set(&agent_id, None);
            Ok(None)
        }
        Some(p) => match services::folder_browser::validate_workdir(p) {
            Ok(dir) => {
                core.state.workdir_prefs.set(&agent_id, Some(&dir));
                log::info!("Workdir for '{}' set to {}", agent_id, dir);
                Ok(Some(dir))
            }
            Err(e) => Err(format!("invalid workdir ({})", e.code())),
        },
    }
}

/// 目录浏览根列表（主目录 + 各盘符，仅固定盘/可移动盘/网络盘）。
#[tauri::command]
async fn browse_roots() -> Result<services::folder_browser::BrowseRoots, String> {
    Ok(services::folder_browser::list_roots())
}

/// 浏览某个目录（None = 主目录；受 allowlist 约束，UNC 拒绝）。
#[tauri::command]
async fn browse_folder(
    path: Option<String>,
) -> Result<services::folder_browser::BrowseResult, String> {
    services::folder_browser::browse_directory(path.as_deref(), false, None, None)
        .map_err(|e| format!("browse failed ({})", e.code()))
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

/// 更改对话的绑定目录（`None` / 空串 = 解绑，回落 CLI 默认 / agent 偏好）。
/// 目录历史分组与执行 cwd 都以该字段为准；目录不存在时后端拒绝。
#[tauri::command]
async fn set_conversation_workdir(
    core: tauri::State<'_, DesktopCore>,
    conversation_id: String,
    workdir: Option<String>,
    app: tauri::AppHandle,
) -> Result<(), String> {
    core.state
        .conversations
        .set_workdir(&conversation_id, workdir.as_deref())
        .map_err(|e| e.to_string())?;
    let _ = app.emit("conversations-changed", serde_json::json!({ "id": conversation_id }));
    Ok(())
}

/// 更改对话的授权档位（`None` / 非法值 = 清除，回落全局默认）。
/// 授权是**对话级**设置：只影响这一个对话，其它对话不受影响。
#[tauri::command]
async fn set_conversation_approval_mode(
    core: tauri::State<'_, DesktopCore>,
    conversation_id: String,
    mode: Option<String>,
    app: tauri::AppHandle,
) -> Result<(), String> {
    core.state
        .conversations
        .set_approval_mode(&conversation_id, mode.as_deref())
        .map_err(|e| e.to_string())?;
    let _ = app.emit("conversations-changed", serde_json::json!({ "id": conversation_id }));
    Ok(())
}

/// 更改对话的模型覆盖（`model_id` 为空 = 清除覆盖，回落该 Agent 的默认模型）。
/// `provider_id` 与 `model_id` 成对写入 —— 同名模型可能来自多个厂商。
/// 同样是**对话级**设置：只影响这一个对话。
#[tauri::command]
async fn set_conversation_model(
    core: tauri::State<'_, DesktopCore>,
    conversation_id: String,
    model_id: Option<String>,
    provider_id: Option<String>,
) -> Result<(), String> {
    core.state
        .conversations
        .set_model(&conversation_id, model_id.as_deref(), provider_id.as_deref())
        .map_err(|e| e.to_string())?;
    log::info!(
        "Conversation {} model override set to {:?} (provider {:?})",
        conversation_id,
        model_id,
        provider_id
    );
    Ok(())
}

// ─── 环境与 CLI 安装命令（设置页「环境与 AI CLI」区块，env_setup.rs）──────────

// 注意：Tauri 命令的参数上不能写 `///` 文档注释（error: only allowed built-in
// attributes in function parameters），函数体注释用 `//`。

/// 全量环境检测：Node / npm / NVM / Python / 各 CLI 的安装状态与版本。
/// 探测要 spawn 若干进程，放 spawn_blocking（返回结构与前端 types.ts 对齐）。
#[tauri::command]
async fn check_environment() -> Result<services::env_setup::EnvironmentStatus, String> {
    Ok(
        tokio::task::spawn_blocking(services::env_setup::check_environment)
            .await
            .map_err(|e| format!("join error: {e}"))?,
    )
}

/// 可安装的 Node 版本清单（nodejs.org dist index 按大版本聚合；离线回落 latest/lts 别名）。
#[tauri::command]
async fn get_node_versions() -> Result<Vec<services::env_setup::NodeVersionOption>, String> {
    Ok(
        tokio::task::spawn_blocking(services::env_setup::fetch_node_versions)
            .await
            .map_err(|e| format!("join error: {e}"))?,
    )
}

/// 安装 NVM（winget 优先，官方静默安装包兜底；可能弹 UAC）。
/// 进度经 `env-setup-log` / `env-setup-done` 事件流给前端。
#[tauri::command]
async fn install_nvm(core: tauri::State<'_, DesktopCore>) -> Result<serde_json::Value, String> {
    let sink = core.state.app_events.clone();
    Ok(
        tokio::task::spawn_blocking(move || services::env_setup::install_nvm(sink.as_ref()))
            .await
            .map_err(|e| format!("join error: {e}"))??,
    )
}

/// 经 NVM 安装指定版本的 Node（install → use → 验证），返回实际安装的版本号。
/// 成功后记入会话状态，CLI 安装即可用（无需重启等 PATH 刷新）。
#[tauri::command]
async fn install_node(
    core: tauri::State<'_, DesktopCore>,
    version: String,
) -> Result<String, String> {
    let sink = core.state.app_events.clone();
    let session = core.env_setup.clone();
    let normalized = services::env_setup::validate_version_input(&version)?;
    let normalized_for_session = normalized.clone();
    tokio::task::spawn_blocking(move || {
        services::env_setup::install_node(&normalized, sink.as_ref())
    })
    .await
    .map_err(|e| format!("join error: {e}"))??;
    if let Ok(mut slot) = session.session_node_version.lock() {
        *slot = Some(normalized_for_session.clone());
    }
    Ok(normalized_for_session)
}

/// 安装某个 Agent 的官方 CLI（methodId 见检测结果的 methods[].id）。
/// 成功后重新检测并返回最新状态；进度经事件流给前端。
#[tauri::command]
async fn install_agent_cli(
    core: tauri::State<'_, DesktopCore>,
    agent_id: String,
    method_id: String,
) -> Result<services::env_setup::AgentCliStatus, String> {
    let sink = core.state.app_events.clone();
    Ok(
        tokio::task::spawn_blocking(move || {
            services::env_setup::install_agent_cli(&agent_id, &method_id, sink.as_ref())
        })
        .await
        .map_err(|e| format!("join error: {e}"))??,
    )
}

/// 更新某个已安装的 Agent CLI 到最新版（官方更新通道），返回更新后的状态。
#[tauri::command]
async fn update_agent_cli(
    core: tauri::State<'_, DesktopCore>,
    agent_id: String,
) -> Result<services::env_setup::AgentCliStatus, String> {
    let sink = core.state.app_events.clone();
    Ok(
        tokio::task::spawn_blocking(move || {
            services::env_setup::update_agent_cli(&agent_id, sink.as_ref())
        })
        .await
        .map_err(|e| format!("join error: {e}"))??,
    )
}

/// 本机已安装的全部 Node 版本（nvm 管理 + 独立安装），含 default/active/compatible
/// 标记（对齐 macOS `installedNodeVersions`；default = NVM_SYMLINK 当前指向的版本）。
#[tauri::command]
async fn installed_node_versions(
    active_node_path: Option<String>,
) -> Result<Vec<services::env_setup::NodeInstallOption>, String> {
    Ok(
        tokio::task::spawn_blocking(move || {
            services::env_setup::installed_node_versions(active_node_path.as_deref())
        })
        .await
        .map_err(|e| format!("join error: {e}"))?,
    )
}

/// 切换 nvm 启用的 Node 版本（等价 `nvm use <v>`；用户主动触发，可能弹 UAC）。
/// 日志经 `env-setup-log` / `env-setup-done` 事件流给前端。
#[tauri::command]
async fn switch_node_default(
    core: tauri::State<'_, DesktopCore>,
    version: String,
) -> Result<(), String> {
    let sink = core.state.app_events.clone();
    tokio::task::spawn_blocking(move || services::env_setup::switch_node(&version, sink.as_ref()))
        .await
        .map_err(|e| format!("join error: {e}"))?
}

// ─── Model providers（设置页「模型配置」；内置 cc-switch 供应商接入 + 转发代理）──

/// 设置页模型配置区块的完整快照（配置列表 + 当前项 + 代理运行态）。
#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelProvidersInfo {
    pub providers: Vec<ProviderView>,
    pub current_id: Option<String>,
    /// Agent 专属当前（key = agent id；前端解析顺序：专属 → current_id → None）。
    pub current_by_agent: HashMap<String, String>,
    pub proxy_enabled: bool,
    pub proxy_port: u16,
    pub proxy_running: bool,
    /// 故障转移开关（开 = 上游失败自动按队列换下一家）。
    pub failover_enabled: bool,
    /// 最近一次代理启动失败的原因（运行中为 None）。
    pub proxy_error: Option<String>,
}

async fn model_providers_info(core: &DesktopCore) -> ModelProvidersInfo {
    let snap: StoredSnapshot = core.model_providers.snapshot();
    let proxy = core.model_proxy.status().await;
    ModelProvidersInfo {
        providers: snap.providers,
        current_id: snap.current_id,
        current_by_agent: snap.current_by_agent,
        proxy_enabled: snap.proxy_enabled,
        proxy_port: snap.proxy_port,
        proxy_running: proxy.running,
        failover_enabled: snap.failover_enabled,
        proxy_error: proxy.error,
    }
}

/// 读取模型配置全量快照。
#[tauri::command]
async fn get_model_providers(
    core: tauri::State<'_, DesktopCore>,
) -> Result<ModelProvidersInfo, String> {
    Ok(model_providers_info(&core).await)
}

/// 新增或更新一条模型配置（id 为空 = 新建；返回刷新后的快照）。
#[tauri::command]
async fn save_model_provider(
    core: tauri::State<'_, DesktopCore>,
    provider: ModelProviderConfig,
) -> Result<ModelProvidersInfo, String> {
    core.model_providers.upsert(provider)?;
    Ok(model_providers_info(&core).await)
}

/// 删除一条模型配置（删当前项时 current 一并清空）。
#[tauri::command]
async fn delete_model_provider(
    core: tauri::State<'_, DesktopCore>,
    id: String,
) -> Result<ModelProvidersInfo, String> {
    core.model_providers.delete(&id)?;
    Ok(model_providers_info(&core).await)
}

/// 切换当前生效的模型配置（即时生效：转发代理按请求读当前值，CLI 无感）。
/// `agent_id` 非空 = 写该 Agent 的专属当前（Agent→厂商归属）；
/// 空/缺省 = 通用槽（旧版语义，全 Agent 回落）。
#[tauri::command]
async fn switch_model_provider(
    core: tauri::State<'_, DesktopCore>,
    id: String,
    agent_id: Option<String>,
) -> Result<ModelProvidersInfo, String> {
    core.model_providers
        .switch_current_for(agent_id.as_deref().unwrap_or(""), &id)?;
    Ok(model_providers_info(&core).await)
}

/// 设置转发代理开关与端口（落盘 + 立即启停代理实例）。
#[tauri::command]
async fn set_model_proxy(
    core: tauri::State<'_, DesktopCore>,
    enabled: bool,
    port: u16,
) -> Result<ModelProvidersInfo, String> {
    core.model_providers.set_proxy(enabled, port);
    core.model_proxy.apply(enabled, port).await;
    Ok(model_providers_info(&core).await)
}

/// 设置故障转移开关（开 = 当前供应商失败时按列表顺序自动换下一家）。
#[tauri::command]
async fn set_model_failover(
    core: tauri::State<'_, DesktopCore>,
    enabled: bool,
) -> Result<ModelProvidersInfo, String> {
    core.model_providers.set_failover(enabled);
    Ok(model_providers_info(&core).await)
}

/// 读取 CLI 接入状态（动态列表：Claude Code / Codex / OpenCode / pi …，
/// 含 installed 检测；claude_code / codex / pi 支持配置接管）。
#[tauri::command]
async fn get_cli_takeover(
    core: tauri::State<'_, DesktopCore>,
) -> Result<CliTakeoverInfo, String> {
    let port = core.model_providers.snapshot().proxy_port;
    Ok(CliTakeover::new().status(port))
}

/// 启用/还原 CLI 配置接管（写或还原 ~/.claude/settings.json、~/.codex/config.toml）。
#[tauri::command]
async fn set_cli_takeover(
    core: tauri::State<'_, DesktopCore>,
    cli: String,
    enable: bool,
) -> Result<CliTakeoverInfo, String> {
    let kind = CliKind::parse(&cli).ok_or_else(|| format!("unknown cli: {cli}"))?;
    let snap = core.model_providers.snapshot();
    let takeover = CliTakeover::new();
    if enable {
        takeover.enable(kind, snap.proxy_port)?;
        // 首次接入自动拉起转发代理（否则 CLI 指到 127.0.0.1:port 无人监听）
        let running = core.model_proxy.status().await.running;
        if !running || !snap.proxy_enabled {
            core.model_providers.set_proxy(true, snap.proxy_port);
            core.model_proxy.apply(true, snap.proxy_port).await;
        }
    } else {
        takeover.disable(kind, snap.proxy_port)?;
    }
    Ok(takeover.status(snap.proxy_port))
}

/// 返回内置厂商目录（纯静态预填模板，不含任何密钥）。
#[tauri::command]
async fn get_provider_catalog() -> Result<Vec<services::provider_catalog::CatalogEntry>, String> {
    Ok(services::provider_catalog::CATALOG.to_vec())
}

// ─── OpenCode 厂商（写 opencode.json）────────────────────────────────────────
// 对标 cc-switch：「添加厂商」表单保存后直接写本机 opencode 的配置文件，
// 用户免手改。数据归属 = opencode.json 唯一真相（不做二次存储）。

/// 列出本机 opencode 已配置的厂商（含配置文件路径与可选 npm 接口包）。
#[tauri::command]
async fn get_opencode_providers() -> Result<services::opencode_config::OpenCodeProvidersInfo, String>
{
    Ok(services::opencode_config::list_providers())
}

/// 新增 / 更新一个 opencode 厂商（写 `provider.<id>`，保留用户其他配置）。
#[tauri::command]
async fn save_opencode_provider(
    entry: services::opencode_config::OpenCodeProviderEntry,
) -> Result<services::opencode_config::OpenCodeProvidersInfo, String> {
    services::opencode_config::save_provider(&entry)
}

/// 删除一个 opencode 厂商（按 id；幂等）。
#[tauri::command]
async fn delete_opencode_provider(
    id: String,
) -> Result<services::opencode_config::OpenCodeProvidersInfo, String> {
    services::opencode_config::delete_provider(&id)
}

// ─── Claude Code 厂商（写 ~/.claude/settings.json）──────────────────────────
// 对标 cc-switch 的 Claude 分支：**整体覆盖** settings.json，厂商信息落在
// env.ANTHROPIC_BASE_URL / env.ANTHROPIC_AUTH_TOKEN，写前剥离内部元字段。

/// 读取本机 Claude Code 的厂商配置（env 段）。
#[tauri::command]
async fn get_claude_provider() -> Result<services::claude_config::ClaudeProvidersInfo, String> {
    Ok(services::claude_config::get_provider())
}

/// 写入 Claude Code 厂商配置（整体覆盖 settings.json，用户其他键保留）。
#[tauri::command]
async fn save_claude_provider(
    entry: services::claude_config::ClaudeProviderEntry,
) -> Result<services::claude_config::ClaudeProvidersInfo, String> {
    services::claude_config::save_provider(&entry)
}

/// 清除 Claude Code 厂商配置（摘掉 env 里的 ANTHROPIC_* 键，其余保留）。
#[tauri::command]
async fn delete_claude_provider() -> Result<services::claude_config::ClaudeProvidersInfo, String> {
    services::claude_config::delete_provider()
}

// ─── Codex 厂商（写 ~/.codex/config.toml）──────────────────────────────────
// 对标 cc-switch 的 Codex 分支：写 [model_providers.<key>] + 顶层 model_provider，
// Key 走 provider 作用域的 experimental_bearer_token。**绝不触碰 auth.json**
// （那是用户 ChatGPT 登录缓存）。

/// 列出本机 Codex 已配置的全部厂商（读 config.toml）。
#[tauri::command]
async fn get_codex_providers() -> Result<services::codex_provider_config::CodexProvidersInfo, String>
{
    Ok(services::codex_provider_config::list_providers())
}

/// 新增 / 更新一个 Codex 厂商（写 [model_providers.<key>]，保留注释与其他表）。
#[tauri::command]
async fn save_codex_provider(
    entry: services::codex_provider_config::CodexProviderEntry,
) -> Result<services::codex_provider_config::CodexProvidersInfo, String> {
    services::codex_provider_config::save_provider(&entry)
}

/// 删除一个 Codex 厂商（按 key；幂等；若是当前生效则一并清 model_provider）。
#[tauri::command]
async fn delete_codex_provider(
    id: String,
) -> Result<services::codex_provider_config::CodexProvidersInfo, String> {
    services::codex_provider_config::delete_provider(&id)
}

/// 切换当前生效的 Codex 厂商（只改顶层 model_provider）。
#[tauri::command]
async fn activate_codex_provider(
    id: String,
) -> Result<services::codex_provider_config::CodexProvidersInfo, String> {
    services::codex_provider_config::activate_provider(&id)
}

// ─── pi 厂商（写 ~/.pi/agent/models.json）──────────────────────────────────
// 对标 cc-switch 的 pi 分支：**增量模式**，只动 providers.<key>，其余键保留。
// Key 不可改名；Key 走 provider 节点内的 apiKey。**绝不触碰 auth.json**
// （那是 pi 自己的 /login 凭据）。

/// 列出本机 pi 已配置的全部厂商（含默认 provider / model）。
#[tauri::command]
async fn get_pi_providers() -> Result<services::pi_config::PiProvidersInfo, String> {
    Ok(services::pi_config::list_providers())
}

/// 新增 / 更新一个 pi 厂商（写 providers.<key>，保留用户其他配置）。
#[tauri::command]
async fn save_pi_provider(
    entry: services::pi_config::PiProviderEntry,
) -> Result<services::pi_config::PiProvidersInfo, String> {
    services::pi_config::save_provider(&entry)
}

/// 删除一个 pi 厂商（按 key；幂等；若为默认则默认项一并清）。
#[tauri::command]
async fn delete_pi_provider(id: String) -> Result<services::pi_config::PiProvidersInfo, String> {
    services::pi_config::delete_provider(&id)
}

/// 把某家 pi 厂商设为默认（settings.defaultProvider + defaultModel 成对写）。
#[tauri::command]
async fn activate_pi_provider(
    id: String,
    model: Option<String>,
) -> Result<services::pi_config::PiProvidersInfo, String> {
    services::pi_config::activate_provider(&id, model.as_deref())
}

/// 拉取某厂商的真实可用模型清单（走目录里的 OpenAI 端点 `models_url`；
/// 转发用的 Anthropic 端点没有 GET /models，二者地址不同）。
///
/// Key 解析：优先用前端刚填的明文（尚未保存场景）；为空 / 掩码（•）时
/// 回落已存配置里同 base_url 的真实 Key —— 明文 Key 绝不写日志、
/// 绝不回显到错误信息（错误只带状态码）。任何失败前端都回落静态候选。
#[tauri::command]
async fn fetch_provider_models(
    core: tauri::State<'_, DesktopCore>,
    provider_id: String,
    api_key: Option<String>,
) -> Result<Vec<String>, String> {
    let entry = services::provider_catalog::find(&provider_id)
        .ok_or_else(|| format!("unknown provider: {provider_id}"))?;
    if entry.models_url.is_empty() {
        return Err("no models endpoint for this provider".into());
    }

    // 解析 Key：掩码（•）视为未提供，避免把掩码串当真实 Key 发出去
    let provided = api_key.unwrap_or_default();
    let provided = provided.trim();
    let provided: &str = if provided.contains('•') { "" } else { provided };
    let key: String = if !provided.is_empty() {
        provided.to_string()
    } else {
        // 从已存配置里找同 base_url 且配过 Key 的条目（route_chain 内部携带真实 Key）
        let (chain, _) = core.model_providers.route_chain();
        let base = entry.base_url.trim_end_matches('/');
        chain
            .iter()
            .find(|p| !p.api_key.is_empty() && p.base_url.trim_end_matches('/') == base)
            .map(|p| p.api_key.clone())
            .ok_or_else(|| "missing api key: fill it in the form first".to_string())?
    };

    let resp = services::model_proxy::http_client()
        .get(entry.models_url)
        .header("Authorization", format!("Bearer {key}"))
        .send()
        .await
        .map_err(|e| format!("request failed: {e}"))?;
    let code = resp.status().as_u16();
    if code == 401 || code == 403 {
        return Err(format!("upstream {code}: invalid api key"));
    }
    if !(200..300).contains(&code) {
        return Err(format!("upstream returned {code}"));
    }
    let body = resp
        .text()
        .await
        .map_err(|e| format!("read body failed: {e}"))?;
    let list = services::model_list::parse_openai_models(&body);
    if list.is_empty() {
        // 404 类 / 解析失败：报错让前端回落目录静态候选，不 panic 不硬失败
        return Err("no models parsed from upstream response".into());
    }
    Ok(list)
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
            // 环境安装会话状态（设置页：刚经 NVM 装好的 Node 版本，供 CLI 安装补 PATH）
            let env_setup = Arc::new(services::env_setup::EnvSetupState::new());
            // 模型供应商配置 + 转发代理（内置 cc-switch 能力；默认关闭 = 行为零差异）
            let model_providers = Arc::new(ModelProviderStore::new());
            let model_proxy = Arc::new(ModelProxyManager::new(model_providers.clone()));
            // 故障转移切到备用供应商时向前端广播（model-provider-switched 事件）
            let proxy_app = app.handle().clone();
            model_proxy.set_event_sink(Arc::new(move |event, payload| {
                let _ = proxy_app.emit(event, payload);
            }));

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
                exec_lock: Arc::new(tokio::sync::Mutex::new(())),
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
                env_setup,
                model_providers: model_providers.clone(),
                model_proxy: model_proxy.clone(),
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

            // 按落盘配置自启动转发代理（端口被占用等失败只记日志 + 状态可查，
            // 不影响主服务 —— 设置页会显示启动失败原因）
            let proxy_manager = model_proxy.clone();
            let proxy_snapshot = model_providers.snapshot();
            tauri::async_runtime::spawn(async move {
                let st = proxy_manager
                    .apply(proxy_snapshot.proxy_enabled, proxy_snapshot.proxy_port)
                    .await;
                if let Some(e) = st.error {
                    log::warn!("[ModelProxy] auto-start issue: {e}");
                }
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
            get_agent_workdir,
            set_agent_workdir,
            browse_roots,
            browse_folder,
            list_conversations,
            get_conversation,
            rename_conversation,
            set_conversation_archived,
            delete_conversation,
            activate_conversation,
            toggle_pin_conversation,
            set_conversation_workdir,
            set_conversation_approval_mode,
            set_conversation_model,
            check_environment,
            get_node_versions,
            install_nvm,
            install_node,
            installed_node_versions,
            switch_node_default,
            install_agent_cli,
            update_agent_cli,
            get_model_providers,
            save_model_provider,
            delete_model_provider,
            switch_model_provider,
            set_model_proxy,
            set_model_failover,
            get_cli_takeover,
            set_cli_takeover,
            get_provider_catalog,
            fetch_provider_models,
            get_opencode_providers,
            save_opencode_provider,
            delete_opencode_provider,
            get_claude_provider,
            save_claude_provider,
            delete_claude_provider,
            get_codex_providers,
            save_codex_provider,
            delete_codex_provider,
            activate_codex_provider,
            get_pi_providers,
            save_pi_provider,
            delete_pi_provider,
            activate_pi_provider,
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
