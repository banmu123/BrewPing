use axum::{
    extract::{Path, Request, State},
    http::StatusCode,
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::sync::RwLock;

use super::agent_config;
use super::agent_discovery::{AgentEntry, AgentEntryApi};
use super::approval_gate::{ApprovalGate, ApprovalMode, Decision, PendingApproval};
use super::command_runner;
use super::conversation_store::ConversationStore;
use super::device_identity::DeviceIdentity;
use super::model_prefs::ModelPrefs;
use super::pairing_store::{AuthDecision, PairingStore};
use super::terminal_state::{OutputType, TerminalManager};
use super::workdir_prefs::WorkdirPrefs;

/// 事件广播回调：由 lib.rs 注入 tauri 的 emit 实现，HTTP/命令层通过它广播事件。
/// 抽象成回调是为了让 http_server / command_runner 不依赖 tauri 类型——
/// 否则 `cargo test` 的测试二进制会把整个 GUI 窗口栈链进来（无应用 manifest
/// 时加载失败：STATUS_ENTRYPOINT_NOT_FOUND，实测踩坑）。
pub type EventSink = Arc<dyn Fn(&str, serde_json::Value) + Send + Sync>;

/// Shared application state for the HTTP server.
#[derive(Clone)]
pub struct AppState {
    pub identity: DeviceIdentity,
    pub lan_ip: String,
    pub port: u16,
    pub agents: Arc<RwLock<Vec<AgentEntry>>>,
    pub default_agent: Arc<RwLock<String>>,
    /// 多对话仓库（方案 §4：单例 session 的替代，元数据/转录两层）。
    pub conversations: Arc<ConversationStore>,
    /// 当前激活的对话 ID（切 Agent 不再杀会话——对话各自绑定 agent_id）。
    pub active_conversation_id: Arc<RwLock<Option<String>>>,
    pub terminal: TerminalManager,
    pub command_store: CommandStore,
    /// 配对与鉴权（与 macOS `PairingStore.shared` 对应）。
    pub pairing: Arc<PairingStore>,
    /// 授权网关（与 macOS `ApprovalGate.shared` 对应）。
    pub approval: Arc<ApprovalGate>,
    /// 用户通过 App 选定的默认模型（与 macOS `AgentManager._defaultModels` 对应）。
    pub model_prefs: Arc<ModelPrefs>,
    /// 用户通过 App 选定的工作目录（agentId → 绝对路径，`None` = 跟随进程 cwd）。
    pub workdir_prefs: Arc<WorkdirPrefs>,
    /// 事件广播（测试环境为 None）。
    pub app_events: Option<EventSink>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SessionInfo {
    pub id: String,
    pub agent: String,
    #[serde(rename = "agentName")]
    pub agent_name: String,
    pub status: String,
}

// ─── Command Store (tracks in-flight command results) ────────────────────────

#[derive(Clone)]
pub struct CommandStore {
    commands: Arc<RwLock<HashMap<String, CommandEntry>>>,
}

#[derive(Debug, Clone)]
struct CommandEntry {
    status: String,
    response: Option<String>,
    error: Option<String>,
    failure_reason: Option<String>,
    model_id: Option<String>,
    duration: Option<f64>,
    /// 命令归属的对话（方案 §4.2：轮询响应据此回填真 sessionId）。
    conversation_id: Option<String>,
}

impl CommandStore {
    pub fn new() -> Self {
        Self {
            commands: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    pub async fn insert_pending(&self, command_id: &str, conversation_id: Option<&str>) {
        let mut map = self.commands.write().await;
        map.insert(
            command_id.to_string(),
            CommandEntry {
                status: "queued".to_string(),
                response: None,
                error: None,
                failure_reason: None,
                model_id: None,
                duration: None,
                conversation_id: conversation_id.map(|c| c.to_string()),
            },
        );
    }

    /// 命令是否仍在飞行中（queued / working）——归档前置检查用。
    pub async fn is_in_flight(&self, command_id: &str) -> bool {
        matches!(
            self.commands
                .read()
                .await
                .get(command_id)
                .map(|e| e.status.as_str()),
            Some("queued") | Some("working")
        )
    }

    pub async fn set_working(&self, command_id: &str) {
        let mut map = self.commands.write().await;
        if let Some(entry) = map.get_mut(command_id) {
            entry.status = "working".to_string();
        }
    }

    pub async fn set_completed(&self, command_id: &str, response: String, duration: Option<f64>) {
        let mut map = self.commands.write().await;
        if let Some(entry) = map.get_mut(command_id) {
            entry.status = "completed".to_string();
            entry.response = Some(response);
            entry.duration = duration;
        }
    }

    pub async fn set_failed(
        &self,
        command_id: &str,
        error: String,
        failure_reason: Option<String>,
        duration: Option<f64>,
    ) {
        let mut map = self.commands.write().await;
        if let Some(entry) = map.get_mut(command_id) {
            entry.status = "failed".to_string();
            entry.error = Some(error);
            entry.failure_reason = failure_reason;
            entry.duration = duration;
        }
    }

    async fn get(&self, command_id: &str) -> Option<CommandEntry> {
        let map = self.commands.read().await;
        map.get(command_id).cloned()
    }
}

#[derive(Debug, Deserialize)]
struct SetAgentBody {
    agent: String,
}

#[derive(Debug, Deserialize)]
struct MessageBody {
    text: String,
    /// 显式指定目标对话（方案 §6.2 三层回落的第一层）。
    #[serde(rename = "conversationId", default)]
    conversation_id: Option<String>,
    /// 显式指定 agent：路由到当前 active 对话（不改变对话绑定的 agent）。
    #[serde(rename = "agentId", default)]
    agent_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct PairBody {
    #[serde(default)]
    code: String,
    #[serde(default, rename = "deviceName")]
    #[allow(dead_code)]
    device_name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ApprovalModeBody {
    mode: String,
}

#[derive(Debug, Deserialize)]
struct ApprovalDecisionBody {
    action: String,
}

/// `POST /api/agents/models/default` 的请求体。
/// `modelId` 缺省 / 为空 = 清除该 Agent 的模型偏好（回到配置文件里的值）。
#[derive(Debug, Deserialize)]
struct SetModelBody {
    #[serde(rename = "agentId")]
    agent_id: String,
    #[serde(rename = "modelId", default)]
    model_id: Option<String>,
    /// 可选：模型所属 providerId。不同 provider 会暴露相同 modelId，
    /// 带上才能区分同名模型（旧客户端不传 = None，行为不变）。
    #[serde(rename = "providerId", default)]
    provider_id: Option<String>,
}

/// `POST /api/message` 命中危险模式时的响应（与 macOS `pendingApprovalResponse` 一致）。
#[derive(Serialize)]
struct PendingApprovalResponse {
    success: bool,
    status: &'static str,
    approval: PendingApproval,
}

/// 统一构造 JSON 响应（含自定义状态码）。
pub fn json_response<T: Serialize>(status: u16, body: T) -> Response {
    let status = StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    (status, Json(body)).into_response()
}

// --- Response types ---

#[derive(Serialize)]
struct StatusResponse {
    status: &'static str,
    host: String,
    #[serde(rename = "defaultAgent")]
    default_agent: String,
    session: Option<SessionInfo>,
}

#[derive(Serialize)]
struct AgentsResponse {
    agents: Vec<AgentEntryApi>,
    #[serde(rename = "defaultAgent")]
    default_agent: String,
}

#[derive(Serialize)]
pub struct SuccessResponse {
    pub success: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "defaultAgent")]
    pub default_agent: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "sessionId")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "commandId")]
    pub command_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// 鉴权中间件：与 macOS `HTTPAPI.handle` 顶部的判定等价。
///
/// 公开端点（不需要 token）：
///  1. `POST /api/pair` —— 本身就是用来换取 token 的入口；
///  2. `GET /api/status` —— 只读健康检查，桌面端自己也用它判活，
///     不泄露命令内容，因此保持公开。
/// 其余全部要求 `Authorization: Bearer <token>`，写操作还要 timestamp + nonce。
async fn auth_middleware(State(state): State<AppState>, req: Request, next: Next) -> Response {
    let method = req.method().as_str().to_string();
    let path = req.uri().path().to_string();
    let is_public = (method == "POST" && path == "/api/pair")
        || (method == "GET" && path == "/api/status");

    if !is_public {
        if let AuthDecision::Denied { status, error } = state.pairing.authorize(&method, req.headers())
        {
            return json_response(status, serde_json::json!({ "success": false, "error": error }));
        }
    }
    next.run(req).await
}

/// Build the axum router with all API routes.
pub fn build_router(state: AppState) -> Router {
    Router::new()
        .route("/api/status", get(handle_status))
        .route("/api/agents", get(handle_agents))
        .route("/api/agents/default", post(handle_set_default_agent))
        .route("/api/agents/{agent_id}/models", get(handle_agent_models))
        .route("/api/agents/models/default", post(handle_set_default_model))
        .route("/api/agents/workdir", post(super::folder_api::handle_set_agent_workdir))
        .route("/api/folders/roots", get(super::folder_api::handle_folder_roots))
        .route("/api/folders", get(super::folder_api::handle_browse_folder))
        .route("/api/pair", post(handle_pair))
        .route("/api/message", post(handle_send_message))
        .route("/api/message/{id}", get(handle_get_message))
        .route(
            "/api/approvals/mode",
            get(handle_get_approval_mode).post(handle_set_approval_mode),
        )
        .route("/api/approvals", get(handle_list_approvals))
        .route("/api/approvals/{id}", post(handle_decide_approval))
        .route("/api/session/start", post(handle_start_session))
        .route("/api/session/stop", post(handle_stop_session))
        .route(
            "/api/conversations",
            get(super::conversation_api::handle_list_conversations)
                .post(super::conversation_api::handle_create_conversation),
        )
        .route(
            "/api/conversations/{id}",
            get(super::conversation_api::handle_get_conversation)
                .patch(super::conversation_api::handle_patch_conversation)
                .delete(super::conversation_api::handle_delete_conversation),
        )
        .route(
            "/api/conversations/{id}/activate",
            post(super::conversation_api::handle_activate_conversation),
        )
        .route("/api/discovery/refresh", post(handle_discovery_refresh))
        .fallback(handle_not_found)
        .route_layer(middleware::from_fn_with_state(state.clone(), auth_middleware))
        .with_state(state)
}

/// 未知路由统一返回 JSON。
///
/// axum 默认的 404 是**空 body**：客户端把它们当 JSON 解析时会得到
/// "The data couldn't be read because it isn't in the correct format."
/// —— 明明只是"这台主机没有这个接口"，却报成"返回数据格式不正确"，非常误导。
/// 统一回一个带 `error` 字段的 JSON，客户端就能给出准确提示。
async fn handle_not_found(method: axum::http::Method, uri: axum::http::Uri) -> Response {
    json_response(
        404,
        serde_json::json!({
            "success": false,
            "error": format!("no such endpoint: {} {}", method, uri.path()),
        }),
    )
}

/// Start the HTTP server on the given port (with fallback).
pub async fn start_server(
    state: AppState,
    preferred_port: u16,
    lan_ip: Option<&str>,
) -> Result<(u16, tokio::task::JoinHandle<()>), String> {
    let ports_to_try: Vec<u16> = vec![
        preferred_port,
        preferred_port + 1,
        preferred_port + 2,
        preferred_port + 3,
    ];

    for port in &ports_to_try {
        let addr: SocketAddr = format!("0.0.0.0:{}", port).parse().unwrap();
        let router = build_router(state.clone());
        let listener = match tokio::net::TcpListener::bind(&addr).await {
            Ok(l) => l,
            Err(_) => continue,
        };
        let bound_port = listener.local_addr().map(|a| a.port()).unwrap_or(*port);
        log::info!("HTTP server bound to {} (port {})", addr, bound_port);

        let handle = tokio::spawn(async move {
            if let Err(e) = axum::serve(listener, router).await {
                log::error!("HTTP server error: {}", e);
            }
        });

        return Ok((bound_port, handle));
    }

    Err(format!(
        "Failed to bind HTTP server on ports {}-{}",
        preferred_port,
        preferred_port + 3
    ))
}

// --- Route handlers ---

async fn handle_status(
    axum::extract::State(state): axum::extract::State<AppState>,
) -> Json<StatusResponse> {
    let default_agent = state.default_agent.read().await.clone();
    // 多对话语义（方案 §7.3）：session = active 对话渲染出的 SessionInfo（无 active → null）。
    let session = active_session_info(&state).await;
    Json(StatusResponse {
        status: "online",
        host: super::device_identity::get_device_name(),
        default_agent,
        session,
    })
}

/// 把 active 对话渲染成 iOS 兼容的 SessionInfo（`/api/status.session` 契约不变）。
async fn active_session_info(state: &AppState) -> Option<SessionInfo> {
    let conv_id = state.active_conversation_id.read().await.clone()?;
    let conv = state.conversations.get(&conv_id)?;
    let agent_name = state
        .agents
        .read()
        .await
        .iter()
        .find(|a| a.id == conv.agent_id)
        .map(|a| a.name.clone())
        .unwrap_or_else(|| conv.agent_id.clone());
    Some(SessionInfo {
        id: conv.id,
        agent: conv.agent_id,
        agent_name,
        status: "running".to_string(),
    })
}

async fn handle_agents(
    axum::extract::State(state): axum::extract::State<AppState>,
) -> Json<AgentsResponse> {
    let agents = state.agents.read().await.clone();
    let default_agent = state.default_agent.read().await.clone();

    // Convert to API format with correct active flag
    let api_agents: Vec<AgentEntryApi> = agents
        .iter()
        .map(|a| {
            let mut api = AgentEntryApi::from(a);
            api.active = api.installed && a.id == default_agent;
            api.workdir = state.workdir_prefs.get(&a.id);
            api
        })
        .collect();

    Json(AgentsResponse {
        agents: api_agents,
        default_agent,
    })
}

// ─── Models (模型列表 / 切换) ─────────────────────────────────────────────────

/// `GET /api/agents/{agent_id}/models` —— 列出某个 Agent 真实配置里的 Provider / Model。
///
/// 响应结构与 macOS `HTTPAPI.agentModelsResponse` **逐字段对齐**（iOS `ModelsResponse` 依赖它）：
/// ```json
/// { "agentId": "opencode",
///   "providers": [ { "id","name","baseURL"?,"models":[{"id","name","available","isActive","isDefault"}] } ],
///   "activeModelId": "...", "preferredModelId": "..." }
/// ```
/// `activeModelId` = 配置文件里正在用的；`preferredModelId` = 用户通过 App 选过的（权威）。
async fn handle_agent_models(
    Path(agent_id): Path<String>,
    axum::extract::State(state): axum::extract::State<AppState>,
) -> Response {
    // 与 macOS 一致：目录之外的 agent id 直接 404，不返回空列表
    // （空列表的语义是"这个 Agent 没有可选模型"，两者不能混）。
    if !agent_config::is_known_agent(&agent_id) {
        return json_response(
            404,
            serde_json::json!({ "success": false, "error": "unknown agent" }),
        );
    }

    let config = agent_config::discover(&agent_id);
    let preferred = state.model_prefs.get(&agent_id);
    let preferred_provider = state.model_prefs.get_provider(&agent_id);

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

    json_response(
        200,
        serde_json::json!({
            "agentId": agent_id,
            "providers": providers,
            "activeModelId": config.active_model_id,
            "preferredModelId": preferred,
            "preferredProviderId": preferred_provider,
        }),
    )
}

/// `POST /api/agents/models/default` —— 记住用户选定的默认模型。
///
/// 与 macOS 行为一致：**不改写 Agent 自己的配置文件**（那些文件只读），
/// 只记"用户偏好"，在启动该 Agent 时以 `--model <id>` 传下去（见 `submit_command`）。
async fn handle_set_default_model(
    axum::extract::State(state): axum::extract::State<AppState>,
    Json(body): Json<SetModelBody>,
) -> Response {
    if body.agent_id.trim().is_empty() {
        return json_response(
            400,
            serde_json::json!({
                "success": false,
                "error": "expected JSON body {\"agentId\": \"...\", \"modelId\": \"...\"}"
            }),
        );
    }
    state.model_prefs.set(
        &body.agent_id,
        body.model_id.as_deref(),
        body.provider_id.as_deref(),
    );
    log::info!(
        "Default model for '{}' set to {:?} (provider {:?})",
        body.agent_id,
        body.model_id,
        body.provider_id
    );
    json_response(
        200,
        serde_json::json!({
            "success": true,
            "agentId": body.agent_id,
            "modelId": body.model_id,
        }),
    )
}

async fn handle_set_default_agent(
    axum::extract::State(state): axum::extract::State<AppState>,
    Json(body): Json<SetAgentBody>,
) -> Json<SuccessResponse> {
    // 多对话语义（方案 §6.2）：切换 Agent 只是换默认，已有对话各自绑定
    // agent_id，**不再杀会话**（原 TC-HT-07 行为已废弃）。
    let mut default = state.default_agent.write().await;
    *default = body.agent.clone();
    log::info!("Default agent set to: {}", body.agent);
    Json(SuccessResponse {
        success: true,
        default_agent: Some(body.agent),
        session_id: None,
        status: None,
        command_id: None,
        error: None,
    })
}

/// POST /api/session/start —— 等价于「创建新对话并激活」（方案 §7.3 声明的
/// 语义变更：旧对话保留，只是不再 active）。
async fn handle_start_session(
    axum::extract::State(state): axum::extract::State<AppState>,
) -> Json<SuccessResponse> {
    let default_agent = state.default_agent.read().await.clone();
    let conv = state.conversations.create(&default_agent);
    {
        let mut active = state.active_conversation_id.write().await;
        *active = Some(conv.id.clone());
    }
    command_runner::emit(
        &state,
        "conversations-changed",
        serde_json::json!({ "id": conv.id }),
    );
    command_runner::emit(
        &state,
        "active-conversation-changed",
        serde_json::json!(conv.id),
    );

    log::info!("Session started (conversation: {})", conv.id);
    Json(SuccessResponse {
        success: true,
        default_agent: None,
        session_id: Some(conv.id),
        status: Some("running".to_string()),
        command_id: None,
        error: None,
    })
}

/// POST /api/session/stop —— 清除 active 指针（对话保留，不删除）。
async fn handle_stop_session(
    axum::extract::State(state): axum::extract::State<AppState>,
) -> Json<SuccessResponse> {
    let mut active = state.active_conversation_id.write().await;
    let sid = active.take();
    drop(active);

    log::info!("Session stopped: {:?}", sid);
    command_runner::emit(&state, "active-conversation-changed", serde_json::json!(null));
    Json(SuccessResponse {
        success: true,
        default_agent: None,
        session_id: sid,
        status: Some("stopped".to_string()),
        command_id: None,
        error: None,
    })
}

/// POST /api/message —— 提交命令并交由 TerminalManager 执行。
///
/// 授权门卫：safe 模式命中危险模式 / askAll 模式下挂起，返回 `pending_approval`
/// 让手机端弹确认；未命中则放行。auto 模式永远放行。
/// 判定点必须在「写进 TerminalState 之前」，与 macOS `HTTPAPI.messageResponse` 一致。
async fn handle_send_message(
    State(state): State<AppState>,
    Json(body): Json<MessageBody>,
) -> Response {
    if body.text.trim().is_empty() {
        return json_response(
            400,
            serde_json::json!({ "success": false, "error": "text is empty" }),
        );
    }

    match state.approval.check(&body.text) {
        Decision::Pending(approval) => pending_approval_response(approval),
        Decision::Allow => match submit_command(
            &state,
            &body.text,
            body.conversation_id.as_deref(),
            body.agent_id.as_deref(),
            None,
        )
        .await
        {
            Ok(response) => Json(response).into_response(),
            Err(StatusCode::NOT_FOUND) => json_response(
                404,
                serde_json::json!({
                    "success": false,
                    "error": "conversation not found"
                }),
            ),
            Err(StatusCode::CONFLICT) => json_response(
                409,
                serde_json::json!({
                    "success": false,
                    "error": "conversation is archived — restore it first"
                }),
            ),
            Err(_) => json_response(
                400,
                serde_json::json!({
                    "success": false,
                    "error": "no active session — start a session first"
                }),
            ),
        },
    }
}

/// 命中危险模式时的响应体（`status` 为 `pending_approval`，携带领取确认的命令）。
fn pending_approval_response(approval: PendingApproval) -> Response {
    json_response(
        200,
        PendingApprovalResponse {
            success: true,
            status: "pending_approval",
            approval,
        },
    )
}

/// 三层回落（方案 §6.2）：显式 conversationId → 该对话；显式 agentId →
/// active 对话；都没有 → active 对话。无 active → 400（原 "no active session" 文案）。
async fn resolve_command_target(
    state: &AppState,
    conversation_id: Option<&str>,
    _agent_id: Option<&str>,
) -> Result<(String, String), StatusCode> {
    if let Some(cid) = conversation_id {
        let Some(conv) = state.conversations.get(cid) else {
            return Err(StatusCode::NOT_FOUND);
        };
        if conv.archived {
            return Err(StatusCode::CONFLICT);
        }
        return Ok((conv.id, conv.agent_id));
    }
    let active = state.active_conversation_id.read().await.clone();
    if let Some(cid) = active {
        if let Some(conv) = state.conversations.get(&cid) {
            if !conv.archived {
                return Ok((conv.id, conv.agent_id));
            }
        }
        return Err(StatusCode::BAD_REQUEST);
    }
    Err(StatusCode::BAD_REQUEST)
}

/// 公共执行入口：授权放行后的命令提交（`handle_send_message`、批准后的
/// `handle_decide_approval`、桌面 Tauri 命令共用同一条路径）。
///
/// 用户消息由这里唯一写入对话转录（方案 §6.3 写路径单一出口），
/// 执行交给 `command_runner::execute_agent_command`（命令状态唯一写入点）。
pub async fn submit_command(
    state: &AppState,
    text: &str,
    conversation_id: Option<&str>,
    agent_id: Option<&str>,
    source: Option<&str>,
) -> Result<SuccessResponse, StatusCode> {
    let (conv_id, agent_id) = resolve_command_target(state, conversation_id, agent_id).await?;

    // Ensure terminal entry exists（桌面路径原有行为，HTTP 路径此前缺失，统一补上）
    command_runner::ensure_terminal_entry(state, &agent_id).await;

    let command_id = format!("cmd_{}", &uuid::Uuid::new_v4().to_string()[..8]);
    log::info!(
        "Message received: '{}' -> {} (command: {}, agent: {})",
        text,
        conv_id,
        command_id,
        agent_id
    );

    // Register command as pending（挂上对话归属，轮询响应据此回填 sessionId）
    state
        .command_store
        .insert_pending(&command_id, Some(&conv_id))
        .await;

    // 用户消息：转录 + 终端回显 + 调度指针（单一写出口，方案 §6.3）
    command_runner::append_to_conversation(state, &conv_id, "user", text, source, Some(&command_id))
        .await;
    {
        let mut map = state.terminal.agents.write().await;
        if let Some(term) = map.get_mut(&agent_id) {
            term.append_line(&format!("> {}", text), OutputType::System);
        }
    }
    state
        .conversations
        .set_latest_command(&conv_id, Some(&command_id));
    command_runner::emit(state, "terminal-updated", serde_json::json!({}));

    // Spawn async execution（headless 一次性执行；opencode 不再走假回显）
    let state_clone = state.clone();
    let cmd_id = command_id.clone();
    let cid = conv_id.clone();
    let aid = agent_id.clone();
    let text_owned = text.to_string();
    tokio::spawn(async move {
        command_runner::execute_agent_command(&state_clone, cmd_id, cid, aid, text_owned).await;
    });

    Ok(SuccessResponse {
        success: true,
        default_agent: None,
        session_id: Some(conv_id),
        status: Some("queued".to_string()),
        command_id: Some(command_id),
        error: None,
    })
}

#[derive(Serialize)]
struct CommandStatusResponse {
    #[serde(rename = "commandId")]
    command_id: String,
    #[serde(rename = "sessionId")]
    session_id: String,
    status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    response: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "rawOutput")]
    raw_output: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "failureReason")]
    failure_reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "modelId")]
    model_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    duration: Option<f64>,
}

/// GET /api/message/{id} — poll command status from CommandStore.
async fn handle_get_message(
    Path(id): Path<String>,
    axum::extract::State(state): axum::extract::State<AppState>,
) -> Json<CommandStatusResponse> {
    let entry = state.command_store.get(&id).await;

    match entry {
        Some(e) => Json(CommandStatusResponse {
            command_id: id.clone(),
            // 真实的对话归属（TC-CA-04）；未知命令回落 "unknown"（与旧契约一致）。
            session_id: e.conversation_id.clone().unwrap_or_else(|| "unknown".to_string()),
            status: e.status,
            response: e.response,
            raw_output: None,
            error: e.error,
            failure_reason: e.failure_reason,
            model_id: e.model_id,
            duration: e.duration,
        }),
        None => Json(CommandStatusResponse {
            command_id: id,
            session_id: "unknown".to_string(),
            status: "failed".to_string(),
            response: None,
            raw_output: None,
            error: Some("Command not found".to_string()),
            failure_reason: None,
            model_id: None,
            duration: None,
        }),
    }
}

async fn handle_discovery_refresh(
    axum::extract::State(state): axum::extract::State<AppState>,
) -> Json<AgentsResponse> {
    let new_agents = super::agent_discovery::discover();
    {
        let mut agents = state.agents.write().await;
        *agents = new_agents.clone();
    }
    let default_agent = state.default_agent.read().await.clone();

    let api_agents: Vec<AgentEntryApi> = new_agents
        .iter()
        .map(|a| {
            let mut api = AgentEntryApi::from(a);
            api.active = api.installed && a.id == default_agent;
            api.workdir = state.workdir_prefs.get(&a.id);
            api
        })
        .collect();

    log::info!("Agent discovery refreshed: {} agents", new_agents.len());
    Json(AgentsResponse {
        agents: api_agents,
        default_agent,
    })
}

// ─── Pairing (配对) ──────────────────────────────────────────────────────────

/// POST /api/pair —— 用 6 位配对码换取长期 token。
///
/// 请求：`{"code": "123456", "deviceName": "iPhone"}`
/// 响应：`{"success": true, "token": "<64 位 hex>", "deviceId": "...", "deviceName": "..."}`
///
/// 注意：这是**唯一**不需要鉴权头的业务接口（见 `auth_middleware`）。
async fn handle_pair(State(state): State<AppState>, Json(body): Json<PairBody>) -> Response {
    if body.code.trim().is_empty() {
        return json_response(
            400,
            serde_json::json!({
                "success": false,
                "error": "expected JSON body {\"code\": \"123456\"}"
            }),
        );
    }

    // 配对码一次性且 10 分钟过期：换不到就说明码错了或已失效，
    // 不区分这两种情况，避免给暴力枚举提供反馈。
    let Some(token) = state.pairing.exchange(&body.code) else {
        return json_response(
            401,
            serde_json::json!({
                "success": false,
                "error": "invalid or expired pairing code"
            }),
        );
    };

    json_response(
        200,
        serde_json::json!({
            "success": true,
            "token": token,
            "deviceId": state.identity.device_id,
            "deviceName": super::device_identity::get_device_name(),
        }),
    )
}

// ─── Approval (授权确认) ─────────────────────────────────────────────────────

/// GET /api/approvals/mode —— 读取当前授权模式。
async fn handle_get_approval_mode(State(state): State<AppState>) -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "success": true,
        "mode": state.approval.mode().as_str(),
    }))
}

/// POST /api/approvals/mode —— 切换授权模式。
async fn handle_set_approval_mode(
    State(state): State<AppState>,
    Json(body): Json<ApprovalModeBody>,
) -> Response {
    let Some(mode) = ApprovalMode::parse(&body.mode) else {
        return json_response(
            400,
            serde_json::json!({
                "success": false,
                "error": "expected JSON body {\"mode\": \"safe\"|\"askAll\"|\"auto\"}"
            }),
        );
    };
    state.approval.set_mode(mode);
    log::info!("Approval mode set to: {}", mode.as_str());
    json_response(
        200,
        serde_json::json!({ "success": true, "mode": mode.as_str() }),
    )
}

/// GET /api/approvals —— 列出全部待确认命令。
async fn handle_list_approvals(State(state): State<AppState>) -> Json<serde_json::Value> {
    let approvals = state.approval.pending_approvals();
    Json(serde_json::json!({ "success": true, "approvals": approvals }))
}

/// POST /api/approvals/{id} —— 用户对某条挂起命令做出决定。
///
/// 请求：`{"action": "approve" | "deny" | "always_approve"}`
/// `approve` / `always_approve` 会复用 `submit_command` 立即执行正文。
async fn handle_decide_approval(
    Path(id): Path<String>,
    State(state): State<AppState>,
    Json(body): Json<ApprovalDecisionBody>,
) -> Response {
    if id.is_empty() || id.starts_with("mode") {
        return json_response(
            404,
            serde_json::json!({ "success": false, "error": "unknown approval" }),
        );
    }

    let Some(resolution) = state.approval.decide(&id, &body.action) else {
        return json_response(
            404,
            serde_json::json!({ "success": false, "error": "unknown or expired approval" }),
        );
    };

    match resolution.action.as_str() {
        "deny" => json_response(
            200,
            serde_json::json!({ "success": true, "status": "denied" }),
        ),
        "approve" | "always_approve" => {
            let Some(text) = resolution.text else {
                return json_response(
                    409,
                    serde_json::json!({
                        "success": false,
                        "error": "approval has no command text"
                    }),
                );
            };
            // 复用与 message 相同的执行路径，保证回显与响应一致。
            // 授权与对话解耦（方案 §8.3）：批准后重新 resolve（落进当前 active 对话）。
            match submit_command(&state, &text, None, None, None).await {
                Ok(response) => Json(response).into_response(),
                Err(status) => json_response(
                    status.as_u16(),
                    serde_json::json!({
                        "success": false,
                        "error": "no active session — start a session first"
                    }),
                ),
            }
        }
        _ => json_response(
            400,
            serde_json::json!({ "success": false, "error": "unknown action" }),
        ),
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::agent_discovery::AgentEntry;
    use crate::services::terminal_state::TerminalManager;
    use std::io::{Read, Write};
    use std::net::TcpStream;
    use std::sync::atomic::{AtomicU16, Ordering};
    use std::time::Duration;

    static NEXT_PORT: AtomicU16 = AtomicU16::new(19500);

    /// 集成测试使用的固定 token。
    ///
    /// 真实路径下 token 是随机生成并落盘的，测试无法预先得知；
    /// 而裸 TCP 测试体必须自己拼鉴权头，因此这里注入一个可预期的 token。
    const TEST_TOKEN: &str =
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    fn next_port() -> u16 {
        // start_server 会依次尝试 port..port+3，步长 8 保证并行测试互不冲突
        NEXT_PORT.fetch_add(8, Ordering::SeqCst)
    }

    fn entry(id: &str, name: &str, installed: bool, executable: Option<&str>) -> AgentEntry {
        AgentEntry {
            id: id.to_string(),
            name: name.to_string(),
            installed,
            active: installed,
            executable: executable.map(|s| s.to_string()),
            version: if installed { Some("1.0.0".into()) } else { None },
        }
    }

    /// 每个测试用例独立的授权状态文件，避免污染真实 `~/.brewping/approval.json`。
    fn approval_test_path() -> std::path::PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!(
            "brewping-http-approval-{}.json",
            uuid::Uuid::new_v4().simple()
        ));
        path
    }

    /// 同上：模型偏好的测试文件也必须隔离，否则会写到用户真实的 `~/.brewping/models.json`。
    fn model_prefs_test_path() -> std::path::PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!(
            "brewping-http-models-{}.json",
            uuid::Uuid::new_v4().simple()
        ));
        path
    }

    /// 同上：工作目录偏好的测试文件也必须隔离。
    fn workdir_prefs_test_path() -> std::path::PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!(
            "brewping-http-workdirs-{}.json",
            uuid::Uuid::new_v4().simple()
        ));
        path
    }

    /// 对话仓库的测试目录隔离（禁止写真实 ~/.brewping/conversations）。
    fn conversations_test_dir() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "brewping-http-convs-{}",
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn test_state() -> AppState {
        let agents = vec![
            entry("opencode", "OpenCode", true, Some("opencode")),
            entry("claude-code", "Claude Code", false, None),
        ];
        AppState {
            identity: DeviceIdentity {
                device_id: "bp_win_00000000".to_string(),
                created_at: "2026-01-01T00:00:00+00:00".to_string(),
            },
            lan_ip: "127.0.0.1".to_string(),
            port: 0,
            agents: Arc::new(RwLock::new(agents)),
            default_agent: Arc::new(RwLock::new("opencode".to_string())),
            conversations: Arc::new(ConversationStore::with_dir(conversations_test_dir())),
            active_conversation_id: Arc::new(RwLock::new(None)),
            terminal: TerminalManager::new(),
            command_store: CommandStore::new(),
            pairing: Arc::new(PairingStore::with_fixed_token(TEST_TOKEN)),
            approval: Arc::new(ApprovalGate::with_path(approval_test_path())),
            model_prefs: Arc::new(ModelPrefs::with_path(model_prefs_test_path())),
            workdir_prefs: Arc::new(WorkdirPrefs::with_path(workdir_prefs_test_path())),
            app_events: None,
        }
    }

    struct TestServer {
        port: u16,
        state: AppState,
        _handle: tokio::task::JoinHandle<()>,
    }

    async fn spawn_server() -> TestServer {
        let state = test_state();
        let (port, handle) = start_server(state.clone(), next_port(), None)
            .await
            .expect("HTTP 服务应能成功绑定端口");
        TestServer {
            port,
            state,
            _handle: handle,
        }
    }

    /// 最小化 HTTP/1.1 客户端：直接使用裸 TCP，避免引入额外测试依赖。
    /// 默认携带合法鉴权头（绝大多数接口都需要）。
    fn request(port: u16, method: &str, path: &str, body: Option<&str>) -> (u16, String) {
        request_authorized(port, method, path, body, true)
    }

    /// 不携带鉴权头的请求，用于验证 401。
    fn request_anonymous(port: u16, method: &str, path: &str, body: Option<&str>) -> (u16, String) {
        request_authorized(port, method, path, body, false)
    }

    fn request_authorized(
        port: u16,
        method: &str,
        path: &str,
        body: Option<&str>,
        authorized: bool,
    ) -> (u16, String) {
        let payload = body.unwrap_or("");
        let mut stream = TcpStream::connect(("127.0.0.1", port)).expect("连接 HTTP 服务失败");
        stream
            .set_read_timeout(Some(Duration::from_secs(10)))
            .unwrap();

        let auth_headers = if authorized {
            let timestamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("系统时间早于 UNIX 纪元")
                .as_secs();
            format!(
                "Authorization: Bearer {TEST_TOKEN}\r\nX-BrewPing-Timestamp: {timestamp}\r\nX-BrewPing-Nonce: {}\r\n",
                uuid::Uuid::new_v4()
            )
        } else {
            String::new()
        };

        let raw_req = format!(
            "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nContent-Type: application/json\r\n{auth_headers}Content-Length: {}\r\nConnection: close\r\n\r\n{payload}",
            payload.as_bytes().len()
        );
        stream.write_all(raw_req.as_bytes()).unwrap();
        stream.flush().unwrap();

        let mut raw = Vec::new();
        stream.read_to_end(&mut raw).unwrap();
        let text = String::from_utf8_lossy(&raw).to_string();
        let status: u16 = text
            .lines()
            .next()
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|c| c.parse().ok())
            .unwrap_or_else(|| panic!("无法解析响应状态行: {:?}", text.lines().next()));
        let body = match text.find("\r\n\r\n") {
            Some(i) => text[i + 4..].to_string(),
            None => String::new(),
        };
        (status, body)
    }

    fn json(body: &str) -> serde_json::Value {
        serde_json::from_str(body).unwrap_or_else(|e| panic!("响应不是合法 JSON: {e} —— {body}"))
    }

    fn post(port: u16, path: &str, body: &str) -> (u16, serde_json::Value) {
        let (code, raw) = request(port, "POST", path, Some(body));
        (code, json(&raw))
    }

    fn get(port: u16, path: &str) -> (u16, serde_json::Value) {
        let (code, raw) = request(port, "GET", path, None);
        (code, json(&raw))
    }

    // ─── CommandStore 状态机 ─────────────────────────────────────────────────

    // TC-CS-01  正常状态迁移 queued → working → completed
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn command_store_happy_path() {
        let store = CommandStore::new();
        store.insert_pending("cmd_1", Some("conv_1")).await;
        assert_eq!(store.get("cmd_1").await.unwrap().status, "queued");

        store.set_working("cmd_1").await;
        assert_eq!(store.get("cmd_1").await.unwrap().status, "working");

        store.set_completed("cmd_1", "done".into(), Some(1.25)).await;
        let e = store.get("cmd_1").await.unwrap();
        assert_eq!(e.status, "completed");
        assert_eq!(e.response.as_deref(), Some("done"));
        assert_eq!(e.duration, Some(1.25));
        assert!(e.error.is_none());
    }

    // TC-CS-02  失败迁移携带 error / failureReason
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn command_store_failure_path() {
        let store = CommandStore::new();
        store.insert_pending("cmd_2", Some("conv_2")).await;
        store.set_working("cmd_2").await;
        store
            .set_failed("cmd_2", "boom".into(), Some("process_exited".into()), Some(0.5))
            .await;
        let e = store.get("cmd_2").await.unwrap();
        assert_eq!(e.status, "failed");
        assert_eq!(e.error.as_deref(), Some("boom"));
        assert_eq!(e.failure_reason.as_deref(), Some("process_exited"));
    }

    // TC-CS-03  边界：对不存在的 commandId 做状态迁移不得 panic、不得凭空创建记录
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn command_store_unknown_id_is_noop() {
        let store = CommandStore::new();
        store.set_working("ghost").await;
        store.set_completed("ghost", "x".into(), None).await;
        store.set_failed("ghost", "y".into(), None, None).await;
        assert!(store.get("ghost").await.is_none());
    }

    // TC-CS-04  边界：重复注册同一 commandId 会覆盖为 queued
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn command_store_reinsert_resets_state() {
        let store = CommandStore::new();
        store.insert_pending("cmd_3", Some("conv_3")).await;
        store.set_completed("cmd_3", "old".into(), Some(9.0)).await;
        store.insert_pending("cmd_3", Some("conv_3")).await;
        let e = store.get("cmd_3").await.unwrap();
        assert_eq!(e.status, "queued");
        assert!(e.response.is_none(), "重新入队应清空旧结果");
    }

    // ─── HTTP 契约（集成层） ─────────────────────────────────────────────────

    // TC-HT-01  GET /api/status 满足协议必填字段，且初始无会话
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn status_endpoint_contract() {
        let srv = spawn_server().await;
        let (code, v) = get(srv.port, "/api/status");
        assert_eq!(code, 200);
        assert_eq!(v["status"], "online");
        assert!(!v["host"].as_str().unwrap().is_empty());
        assert_eq!(v["defaultAgent"], "opencode");
        assert!(v["session"].is_null(), "初始状态不应有会话");
    }

    // TC-HT-02  GET /api/agents 返回布尔 executable 且 active 唯一
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn agents_endpoint_contract() {
        let srv = spawn_server().await;
        let (code, v) = get(srv.port, "/api/agents");
        assert_eq!(code, 200);
        let agents = v["agents"].as_array().unwrap();
        assert_eq!(agents.len(), 2);
        assert_eq!(v["defaultAgent"], "opencode");

        for a in agents {
            assert!(a["executable"].is_boolean(), "executable 必须是布尔值");
            // active 只在 installed 且等于 defaultAgent 时为 true
            let expect_active = a["installed"].as_bool().unwrap() && a["id"] == "opencode";
            assert_eq!(a["active"].as_bool().unwrap(), expect_active);
        }
        let active_count = agents.iter().filter(|a| a["active"] == true).count();
        assert_eq!(active_count, 1, "同一时刻只能有一个活动代理");
    }

    // TC-HT-03  边界：未启动会话时投递消息必须被拒绝（400）
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn message_before_session_is_rejected() {
        let srv = spawn_server().await;
        let (code, _) = request(
            srv.port,
            "POST",
            "/api/message",
            Some(r#"{"text":"hello"}"#),
        );
        assert_eq!(code, 400, "无会话时 POST /api/message 应返回 400");
    }

    // TC-HT-04  会话生命周期：start → running → stop → 无会话
    //           （多对话新语义：start = 创建新对话并激活，sessionId 为 conv_ 前缀）
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn session_start_status_stop_flow() {
        let srv = spawn_server().await;

        let (code, v) = post(srv.port, "/api/session/start", "");
        assert_eq!(code, 200);
        assert_eq!(v["success"], true);
        assert_eq!(v["status"], "running");
        let sid = v["sessionId"].as_str().unwrap().to_string();
        assert!(sid.starts_with("conv_"), "多对话后会话 ID 前缀应为 conv_");

        let (_, status) = get(srv.port, "/api/status");
        assert_eq!(status["session"]["id"], sid.as_str());
        assert_eq!(status["session"]["status"], "running");
        assert_eq!(status["session"]["agent"], "opencode");
        assert_eq!(status["session"]["agentName"], "OpenCode");

        let (code, v) = post(srv.port, "/api/session/stop", "");
        assert_eq!(code, 200);
        assert_eq!(v["status"], "stopped");
        assert_eq!(v["sessionId"], sid.as_str());

        let (_, status) = get(srv.port, "/api/status");
        assert!(status["session"].is_null(), "停止后不应有 active 对话");
        // 对话本身保留（stop ≠ 删除）
        assert!(srv.state.conversations.get(&sid).is_some());
    }

    // TC-HT-05  边界：重复 start 会创建新对话并激活（旧对话保留，方案 §7.3）
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn session_restart_replaces_previous() {
        let srv = spawn_server().await;
        let (_, first) = post(srv.port, "/api/session/start", "");
        let (_, second) = post(srv.port, "/api/session/start", "");
        assert_ne!(first["sessionId"], second["sessionId"]);
        let (_, status) = get(srv.port, "/api/status");
        assert_eq!(status["session"]["id"], second["sessionId"]);
        // 旧对话仍在仓库里（只是不再 active）
        let first_id = first["sessionId"].as_str().unwrap().to_string();
        assert!(srv.state.conversations.get(&first_id).is_some());
    }

    // TC-HT-06  边界：无会话时 stop 仍应成功返回
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn stop_without_session_is_safe() {
        let srv = spawn_server().await;
        let (code, v) = post(srv.port, "/api/session/stop", "");
        assert_eq!(code, 200);
        assert_eq!(v["success"], true);
        assert_eq!(v["status"], "stopped");
    }

    // TC-HT-07  切换默认代理不再终止会话（多对话新语义，方案 §6.2：
    //           已有对话各自绑定 agent_id，切换只是换默认）
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn switching_default_agent_keeps_active_conversation() {
        let srv = spawn_server().await;
        post(srv.port, "/api/session/start", "");

        let (code, v) = post(
            srv.port,
            "/api/agents/default",
            r#"{"agent":"claude-code"}"#,
        );
        assert_eq!(code, 200);
        assert_eq!(v["success"], true);
        assert_eq!(v["defaultAgent"], "claude-code");

        let (_, status) = get(srv.port, "/api/status");
        assert_eq!(status["defaultAgent"], "claude-code");
        // 关键差异：active 对话不受切换影响
        assert!(!status["session"].is_null(), "切换代理不得终止 active 对话");
        assert_eq!(status["session"]["agent"], "opencode", "对话仍绑定原 agent");
    }

    // TC-HT-08  端到端：会话内投递消息 → 轮询至 completed。
    //           多对话后 opencode 也走真实 headless 执行（假回显已删除），
    //           测试里把 opencode 指向一个回声 bat 充当 CLI。
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn message_roundtrip_completes() {
        let srv = spawn_server().await;
        // 回声 bat：忽略参数，输出固定标记（bat 会经 cmd.exe 启动，参数不可靠是既知坑）
        let bat = std::env::temp_dir().join(format!("brewping-ht08-echo-{}.cmd", uuid::Uuid::new_v4()));
        std::fs::write(&bat, b"@echo ECHOED-RESPONSE\r\n").unwrap();
        srv.state.agents.write().await[0] = crate::services::agent_discovery::AgentEntry {
            id: "opencode".to_string(),
            name: "OpenCode".to_string(),
            installed: true,
            active: true,
            executable: Some(bat.to_string_lossy().to_string()),
            version: Some("1.0.0".into()),
        };

        post(srv.port, "/api/session/start", "");

        let (code, v) = post(srv.port, "/api/message", r#"{"text":"ping"}"#);
        assert_eq!(code, 200);
        assert_eq!(v["success"], true);
        let cmd = v["commandId"].as_str().unwrap().to_string();
        assert!(cmd.starts_with("cmd_"), "命令 ID 前缀应为 cmd_");
        assert_eq!(v["status"], "queued");

        let mut final_status = String::new();
        let mut body = serde_json::Value::Null;
        for _ in 0..30 {
            let (code, v) = get(srv.port, &format!("/api/message/{cmd}"));
            assert_eq!(code, 200);
            final_status = v["status"].as_str().unwrap_or("").to_string();
            body = v;
            if final_status == "completed" || final_status == "failed" {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        assert_eq!(final_status, "completed", "命令应在超时前完成: {body}");
        assert!(
            body["response"].as_str().unwrap().contains("ECHOED-RESPONSE"),
            "响应应来自真实 CLI 输出: {body}"
        );
        // TC-CA-04：sessionId 为真值（对话归属），不再是 "unknown"
        assert!(
            body["sessionId"].as_str().unwrap_or("unknown").starts_with("conv_"),
            "轮询响应必须回填真实对话 ID: {body}"
        );
        let _ = std::fs::remove_file(&bat);
    }

    // TC-HT-09  边界：查询不存在的 commandId → failed + Command not found
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn unknown_command_reports_failure() {
        let srv = spawn_server().await;
        let (code, v) = get(srv.port, "/api/message/cmd_not_exist");
        assert_eq!(code, 200);
        assert_eq!(v["status"], "failed");
        assert_eq!(v["error"], "Command not found");
        assert_eq!(v["commandId"], "cmd_not_exist");
    }

    // TC-HT-10  POST /api/discovery/refresh 重新扫描并回写代理表
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn discovery_refresh_rewrites_agent_table() {
        let srv = spawn_server().await;
        let (code, v) = post(srv.port, "/api/discovery/refresh", "");
        assert_eq!(code, 200);
        let agents = v["agents"].as_array().unwrap();
        assert!(!agents.is_empty(), "真实环境扫描应至少返回目录内条目");
        assert_eq!(v["defaultAgent"], "opencode");
    }

    // TC-HT-11  边界：未知路由 → 404
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn unknown_route_returns_404() {
        let srv = spawn_server().await;
        let (code, _) = request(srv.port, "GET", "/api/does-not-exist", None);
        assert_eq!(code, 404);
    }

    // TC-HT-12  边界：请求体字段缺失 / JSON 非法 → 4xx 且不得 200
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn malformed_request_body_is_rejected() {
        let srv = spawn_server().await;

        // 缺少 agent 字段
        let (code, _) = request(srv.port, "POST", "/api/agents/default", Some("{}"));
        assert!((400..500).contains(&code), "缺字段应返回 4xx，实际 {code}");

        // 非法 JSON
        let (code, _) = request(srv.port, "POST", "/api/agents/default", Some("{"));
        assert!((400..500).contains(&code), "非法 JSON 应返回 4xx，实际 {code}");

        // 缺少 text 字段
        let (code, _) = request(srv.port, "POST", "/api/message", Some("{}"));
        assert!((400..500).contains(&code), "缺 text 应返回 4xx，实际 {code}");
    }

    // TC-HT-13  端口回退：首选端口被占用时应自动顺延
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn port_fallback_when_preferred_is_taken() {
        let port = next_port();
        // 先占用首选端口
        let blocker = tokio::net::TcpListener::bind(("0.0.0.0", port)).await.unwrap();
        let (bound, handle) = start_server(test_state(), port, None)
            .await
            .expect("应回退到其他端口");
        assert_ne!(bound, port, "首选端口被占用时应使用其它端口");
        assert!(((port + 1)..=(port + 3)).contains(&bound), "回退端口应在 {}-{} 之间，实际 {bound}", port + 1, port + 3);

        // 新端口应真实可用
        let (code, _) = request(bound, "GET", "/api/status", None);
        assert_eq!(code, 200);

        drop(blocker);
        handle.abort();
    }

    // TC-HT-14  并发投递：多个命令 ID 相互隔离
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn concurrent_commands_are_isolated() {
        let srv = spawn_server().await;
        post(srv.port, "/api/session/start", "");

        let mut ids = Vec::new();
        for i in 0..3 {
            let (code, v) = post(srv.port, "/api/message", &format!(r#"{{"text":"msg{i}"}}"#));
            assert_eq!(code, 200);
            ids.push(v["commandId"].as_str().unwrap().to_string());
        }
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), 3, "并发命令 ID 不应重复");
    }

    // ─── 鉴权（对齐 macOS PairingStore） ──────────────────────────────────────

    // TC-HT-15  受保护接口无 token → 401；公开接口无需 token
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn protected_endpoints_require_token() {
        let srv = spawn_server().await;

        // 公开：GET /api/status
        let (code, raw) = request_anonymous(srv.port, "GET", "/api/status", None);
        assert_eq!(code, 200, "健康检查必须保持公开");
        assert_eq!(json(&raw)["status"], "online");

        // 受保护：读接口
        let (code, raw) = request_anonymous(srv.port, "GET", "/api/agents", None);
        assert_eq!(code, 401);
        assert_eq!(json(&raw)["success"], false);

        // 受保护：写接口
        let (code, _) = request_anonymous(srv.port, "POST", "/api/session/start", None);
        assert_eq!(code, 401, "写操作无 token 必须拒绝");

        // 授权接口同样受保护
        let (code, _) = request_anonymous(srv.port, "GET", "/api/approvals", None);
        assert_eq!(code, 401);

        // 带上 token 后一切正常
        let (code, _) = get(srv.port, "/api/agents");
        assert_eq!(code, 200);
    }

    // TC-HT-16  配对端点：无鉴权可访问，配对码一次性
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn pair_endpoint_exchanges_code_for_token() {
        let srv = spawn_server().await;

        // 尚未生成配对码：任何码都换不到 token
        let (code, raw) = request_anonymous(
            srv.port,
            "POST",
            "/api/pair",
            Some(r#"{"code":"000000"}"#),
        );
        assert_eq!(code, 401);
        assert_eq!(json(&raw)["success"], false);

        // 生成配对码后正常兑换（注意：本接口不需要鉴权头）
        let pairing_code = srv.state.pairing.issue_pairing_code();
        let body = format!(r#"{{"code":"{pairing_code}","deviceName":"iPhone"}}"#);
        let (code, raw) = request_anonymous(srv.port, "POST", "/api/pair", Some(&body));
        assert_eq!(code, 200);
        let v = json(&raw);
        assert_eq!(v["success"], true);
        assert_eq!(v["token"], TEST_TOKEN);
        assert_eq!(v["deviceId"], "bp_win_00000000");
        assert!(
            !v["deviceName"].as_str().unwrap().is_empty(),
            "响应必须带设备名"
        );

        // 一次性：同一个码不能重复兑换
        let (code, _) = request_anonymous(srv.port, "POST", "/api/pair", Some(&body));
        assert_eq!(code, 401, "配对码必须一次性");
    }

    // ─── 授权模式 / 待确认队列（对齐 macOS ApprovalGate） ─────────────────────

    // TC-HT-17  授权模式默认 safe，可读写，非法值拒绝
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn approval_mode_read_write() {
        let srv = spawn_server().await;

        let (code, v) = get(srv.port, "/api/approvals/mode");
        assert_eq!(code, 200);
        assert_eq!(v["mode"], "safe", "默认档位必须是 safe");

        let (code, v) = post(srv.port, "/api/approvals/mode", r#"{"mode":"askAll"}"#);
        assert_eq!(code, 200);
        assert_eq!(v["success"], true);
        assert_eq!(v["mode"], "askAll");

        let (_, v) = get(srv.port, "/api/approvals/mode");
        assert_eq!(v["mode"], "askAll", "模式必须真正落库");

        let (code, v) = post(srv.port, "/api/approvals/mode", r#"{"mode":"yolo"}"#);
        assert_eq!(code, 400, "非法档位必须 400");
        assert_eq!(v["success"], false);
    }

    // TC-HT-18  危险命令挂起 → approve 后复用同一执行路径
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn dangerous_message_is_pended_then_executed_on_approve() {
        let srv = spawn_server().await;
        post(srv.port, "/api/session/start", "");

        let (code, v) = post(srv.port, "/api/message", r#"{"text":"rm -rf /"}"#);
        assert_eq!(code, 200);
        assert_eq!(v["success"], true);
        assert_eq!(v["status"], "pending_approval");
        assert_eq!(v["approval"]["text"], "rm -rf /");
        assert_eq!(v["approval"]["reasons"][0]["code"], "rm_root");
        assert!(v["approval"]["createdAt"].is_string());
        let id = v["approval"]["id"].as_str().unwrap().to_string();
        assert!(id.starts_with("apv_"), "审批 ID 前缀应为 apv_");

        // 挂起期间在列表中可见
        let (_, list) = get(srv.port, "/api/approvals");
        assert_eq!(list["approvals"].as_array().unwrap().len(), 1);

        // 批准后立即执行，响应结构与 /api/message 完全一致
        let (code, v) = post(
            srv.port,
            &format!("/api/approvals/{id}"),
            r#"{"action":"approve"}"#,
        );
        assert_eq!(code, 200);
        assert_eq!(v["success"], true);
        let cmd = v["commandId"].as_str().unwrap().to_string();
        assert!(cmd.starts_with("cmd_"), "命令 ID 前缀应为 cmd_");

        // 处理后 pending 被消费
        let (_, list) = get(srv.port, "/api/approvals");
        assert_eq!(list["approvals"].as_array().unwrap().len(), 0);
    }

    // TC-HT-19  deny 只回 status，不产生任何命令
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn deny_does_not_execute_command() {
        let srv = spawn_server().await;
        post(srv.port, "/api/session/start", "");

        let (_, v) = post(
            srv.port,
            "/api/message",
            r#"{"text":"git push --force origin main"}"#,
        );
        assert_eq!(v["status"], "pending_approval");
        assert_eq!(v["approval"]["reasons"][0]["code"], "force_push");
        let id = v["approval"]["id"].as_str().unwrap().to_string();

        let (code, v) = post(
            srv.port,
            &format!("/api/approvals/{id}"),
            r#"{"action":"deny"}"#,
        );
        assert_eq!(code, 200);
        assert_eq!(v["status"], "denied");
        assert!(v["commandId"].is_null(), "拒绝后不得返回 commandId");

        let (_, list) = get(srv.port, "/api/approvals");
        assert_eq!(list["approvals"].as_array().unwrap().len(), 0);
    }

    // TC-HT-20  always_approve 生效于后续命令；auto 模式全量放行
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn always_approve_and_auto_mode() {
        let srv = spawn_server().await;
        post(srv.port, "/api/session/start", "");

        // safe 下 sudo 挂起 → always_approve 把 sudo 写入白名单并立即执行
        let (_, v) = post(srv.port, "/api/message", r#"{"text":"sudo ls"}"#);
        assert_eq!(v["status"], "pending_approval");
        let id = v["approval"]["id"].as_str().unwrap().to_string();
        let (code, v) = post(
            srv.port,
            &format!("/api/approvals/{id}"),
            r#"{"action":"always_approve"}"#,
        );
        assert_eq!(code, 200);
        assert!(v["commandId"].is_string(), "always_approve 也应立即执行");

        // 同样命中的命令再来一次 → 直接放行
        let (code, v) = post(srv.port, "/api/message", r#"{"text":"sudo ls"}"#);
        assert_eq!(code, 200);
        assert_eq!(v["status"], "queued", "白名单内的 code 不应再挂起");

        // auto 模式下即使是最危险的命令也直接放行
        let (code, v) = post(srv.port, "/api/approvals/mode", r#"{"mode":"auto"}"#);
        assert_eq!(code, 200);
        let (code, v) = post(srv.port, "/api/message", r#"{"text":"rm -rf /"}"#);
        assert_eq!(code, 200);
        assert_eq!(v["status"], "queued", "auto 模式必须放行");
    }

    // TC-HT-21  边界：未知 approval id → 404
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn unknown_approval_id_returns_404() {
        let srv = spawn_server().await;
        let (code, v) = post(
            srv.port,
            "/api/approvals/apv_ghost",
            r#"{"action":"approve"}"#,
        );
        assert_eq!(code, 404);
        assert_eq!(v["success"], false);
    }

    // TC-HT-22  交互：授权模式与 /api/message 的联动在会话未启动时也不得 panic
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn approval_and_session_interaction() {
        let srv = spawn_server().await;

        // 无会话 + 危险命令：先过门卫（与 macOS 判定点一致），返回 pending
        let (code, v) = post(srv.port, "/api/message", r#"{"text":"rm -rf /"}"#);
        assert_eq!(code, 200);
        assert_eq!(v["status"], "pending_approval");

        // 批准时仍无会话 → 409/400 且不得 panic
        let id = v["approval"]["id"].as_str().unwrap().to_string();
        let (code, _) = post(
            srv.port,
            &format!("/api/approvals/{id}"),
            r#"{"action":"approve"}"#,
        );
        assert!((400..500).contains(&code), "无会话时批准应返回 4xx，实际 {code}");

        // 普通命令在无会话时仍按原契约返回 400
        let (code, _) = post(srv.port, "/api/message", r#"{"text":"hello"}"#);
        assert_eq!(code, 400);
    }

    // TC-HT-23  模型列表：响应结构与 iOS `ModelsResponse` 逐字段对齐
    // NOTE: 必须使用多线程运行时（理由同上）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn agent_models_response_matches_ios_contract() {
        let srv = spawn_server().await;
        let (code, v) = get(srv.port, "/api/agents/opencode/models");
        assert_eq!(code, 200);
        assert_eq!(v["agentId"], "opencode");
        assert!(v["providers"].is_array(), "providers 必须是数组");
        // 两个可空字段必须存在（可为 null），否则 iOS 解不出 preferredModelId
        assert!(v.get("activeModelId").is_some(), "缺少 activeModelId");
        assert!(v.get("preferredModelId").is_some(), "缺少 preferredModelId");
    }

    // TC-HT-24  目录外的 agent id：404 且带 error（不能返回空列表冒充"没有模型"）
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn unknown_agent_models_returns_404() {
        let srv = spawn_server().await;
        let (code, v) = get(srv.port, "/api/agents/no-such-agent/models");
        assert_eq!(code, 404);
        assert_eq!(v["success"], false);
        assert!(v["error"].is_string());
    }

    // TC-HT-25  切换默认模型：POST 后 GET 必须回读得到 preferredModelId（与设备无关，稳定可验）
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn set_default_model_is_persisted_and_read_back() {
        let srv = spawn_server().await;
        let (code, v) = post(
            srv.port,
            "/api/agents/models/default",
            r#"{"agentId":"opencode","modelId":"glm-5.2"}"#,
        );
        assert_eq!(code, 200);
        assert_eq!(v["success"], true);
        assert_eq!(v["modelId"], "glm-5.2");

        let (code, v) = get(srv.port, "/api/agents/opencode/models");
        assert_eq!(code, 200);
        assert_eq!(v["preferredModelId"], "glm-5.2", "偏好必须能被回读");

        // 其它 Agent 不受影响
        let (_, other) = get(srv.port, "/api/agents/codex/models");
        assert!(other["preferredModelId"].is_null(), "不应串到别的 Agent");
    }

    // TC-HT-26  未知路由必须返回 JSON 而不是空 body。
    // 这是"iPhone 提示无法加载模型列表：格式不正确"的直接病根 ——
    // 空 body 让客户端的 JSON 解析失败，把"没有这个接口"报成了"数据格式错误"。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn unknown_route_returns_json_not_empty_body() {
        let srv = spawn_server().await;
        let (code, raw) = request_anonymous(srv.port, "GET", "/api/definitely-not-here", None);
        assert_eq!(code, 404);
        let parsed: serde_json::Value =
            serde_json::from_str(&raw).expect("404 响应体必须是可解析的 JSON");
        assert_eq!(parsed["success"], false);
        assert!(parsed["error"].is_string());
    }

    // TC-HT-27  模型接口同样受鉴权保护（未配对时 401，而不是泄露本机配置）
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn agent_models_requires_auth() {
        let srv = spawn_server().await;
        let (code, _) = request_anonymous(srv.port, "GET", "/api/agents/opencode/models", None);
        assert_eq!(code, 401);
    }

    // ─── 「获取文件夹」HTTP 契约（方案 §10.1，TC-HT-28..39） ─────────────────

    // TC-HT-28 + TC-HT-29  roots 契约 + platform 取值锁定为 "windows"
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn folder_roots_contract() {
        let srv = spawn_server().await;
        let (code, v) = get(srv.port, "/api/folders/roots");
        assert_eq!(code, 200);
        assert_eq!(v["platform"], "windows", "platform 必须是 windows（不是 win32）");
        assert_eq!(v["pathSeparator"], "\\");
        assert!(v["homeDir"].is_string() && !v["homeDir"].as_str().unwrap().is_empty());
        assert!(v["drives"].is_array(), "drives 必须是数组");
        assert!(v["drives"].as_array().unwrap().len() >= 1, "至少应有 C:");
    }

    // TC-HT-30  /api/folders 缺省回退 home
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn browse_defaults_to_home() {
        let srv = spawn_server().await;
        let (code, v) = get(srv.port, "/api/folders");
        assert_eq!(code, 200);
        let roots = get(srv.port, "/api/folders/roots").1;
        assert_eq!(
            v["path"].as_str().unwrap().to_ascii_lowercase(),
            roots["homeDir"].as_str().unwrap().to_ascii_lowercase(),
            "缺省应浏览 home"
        );
        assert!(v["entries"].is_array());
        assert_eq!(v["truncated"], false);
    }

    // TC-HT-31  非法 limit / hidden 必须降级为缺省值，不得返回 400 纯文本（护住 TC-HT-26）
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn browse_tolerates_garbage_query() {
        let srv = spawn_server().await;
        let (code, raw) = request(srv.port, "GET", "/api/folders?limit=abc&hidden=yes", None);
        assert_eq!(code, 200);
        let parsed: serde_json::Value =
            serde_json::from_str(&raw).expect("非法 query 仍必须是可解析 JSON，不能是 400 纯文本");
        assert_eq!(parsed["truncated"], false);
    }

    // TC-HT-32  UNC 路径拒绝（在 realpath 之前，绝不触发 SMB 流量）
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn browse_rejects_unc() {
        let srv = spawn_server().await;
        let (code, raw) = request(srv.port, "GET", "/api/folders?path=%5C%5Cserver%5Cshare", None);
        assert_eq!(code, 400);
        let v = json(&raw);
        assert_eq!(v["error"], "unc-not-allowed");
    }

    // TC-HT-35  opencode 明确拒绝 workdir（stub 不 spawn，设了也不生效，不能沉默接受）
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn workdir_rejects_opencode() {
        let srv = spawn_server().await;
        let dir = std::env::temp_dir().to_string_lossy().replace('\\', "\\\\");
        let (code, v) = post(
            srv.port,
            "/api/agents/workdir",
            &format!(r#"{{"agentId":"opencode","path":"{dir}"}}"#),
        );
        assert_eq!(code, 400);
        assert!(
            v["error"].as_str().unwrap().contains("does not support workdir"),
            "错误信息必须明确说明不支持，实际: {}",
            v["error"]
        );
    }

    // TC-HT-34 + TC-HT-36  未知 agent → 404 JSON；合法 agent 设置成功且可回读
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn workdir_set_and_roundtrip() {
        let srv = spawn_server().await;

        let (code, v) = post(
            srv.port,
            "/api/agents/workdir",
            r#"{"agentId":"no-such-agent","path":"C:\\"}"#,
        );
        assert_eq!(code, 404);
        assert_eq!(v["success"], false);
        assert!(v["error"].is_string(), "未知 agent 必须返回 JSON 错误");

        let dir = std::env::temp_dir();
        let dir_json = dir.to_string_lossy().replace('\\', "\\\\");
        let (code, v) = post(
            srv.port,
            "/api/agents/workdir",
            &format!(r#"{{"agentId":"claude-code","path":"{dir_json}"}}"#),
        );
        assert_eq!(code, 200);
        assert_eq!(v["success"], true);
        let stored = v["workdir"].as_str().unwrap().to_string();
        assert!(!stored.starts_with("\\\\?\\"), "存盘路径必须已剥 \\\\?\\ 前缀");

        // 回读：/api/agents 里该 agent 的 workdir 应一致
        let (_, agents) = get(srv.port, "/api/agents");
        let entry = agents["agents"]
            .as_array()
            .unwrap()
            .iter()
            .find(|a| a["id"] == "claude-code")
            .expect("claude-code 应在列表中");
        assert_eq!(
            entry["workdir"].as_str().unwrap().to_ascii_lowercase(),
            stored.to_ascii_lowercase(),
            "workdir 必须能从 /api/agents 回读"
        );

        // 清除：path=null → 200 且 workdir 变 null
        let (code, v) = post(srv.port, "/api/agents/workdir", r#"{"agentId":"claude-code","path":null}"#);
        assert_eq!(code, 200);
        assert!(v["workdir"].is_null());

        // 幂等：重复清除也是成功
        let (code, _) = post(srv.port, "/api/agents/workdir", r#"{"agentId":"claude-code","path":null}"#);
        assert_eq!(code, 200);
    }

    // TC-HT-37  新端点受鉴权保护
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn folder_endpoints_require_auth() {
        let srv = spawn_server().await;
        for (method, path) in [
            ("GET", "/api/folders/roots"),
            ("GET", "/api/folders"),
        ] {
            let (code, raw) = request_anonymous(srv.port, method, path, None);
            assert_eq!(code, 401, "{} {} 匿名必须 401", method, path);
            let parsed: serde_json::Value =
                serde_json::from_str(&raw).expect("401 响应体必须是 JSON");
            assert_eq!(parsed["success"], false);
        }
        let (code, raw) = request_anonymous(
            srv.port,
            "POST",
            "/api/agents/workdir",
            Some(r#"{"agentId":"claude-code","path":"C:\\"}"#),
        );
        assert_eq!(code, 401);
        let _: serde_json::Value = serde_json::from_str(&raw).expect("401 响应体必须是 JSON");
    }

    // TC-HT-39  目录浏览不泄露文件内容：entries 只有目录项，没有 content / size 之类字段
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn browse_does_not_leak_file_content() {
        let srv = spawn_server().await;
        let root = std::env::temp_dir().join(format!("brewping-ht39-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(root.join("subdir")).unwrap();
        std::fs::write(root.join("secret.txt"), b"TOP SECRET CONTENT").unwrap();

        let (code, raw) = request(
            srv.port,
            "GET",
            &format!("/api/folders?path={}", urlencode(root.to_str().unwrap())),
            None,
        );
        assert_eq!(code, 200);
        assert!(!raw.contains("TOP SECRET"), "绝不能返回文件正文");
        let v: serde_json::Value = serde_json::from_str(&raw).unwrap();
        let names: Vec<&str> = v["entries"].as_array().unwrap().iter().map(|e| e["name"].as_str().unwrap()).collect();
        assert!(names.contains(&"subdir"), "目录应列出");
        assert!(!names.contains(&"secret.txt"), "文件必须被过滤");
        let _ = std::fs::remove_dir_all(root);
    }

    /// 把 Windows 路径编码成 query 值（测试辅助：反斜杠、冒号都要转义）。
    fn urlencode(path: &str) -> String {
        let mut out = String::new();
        for b in path.bytes() {
            match b {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                    out.push(b as char)
                }
                _ => out.push_str(&format!("%{:02X}", b)),
            }
        }
        out
    }

    // ─── cwd 注入（方案 §10.2） ──────────────────────────────────────────────

    // TC-WD-02  机制层：Command::current_dir 在 Windows 上确实切目录
    #[test]
    fn current_dir_switches_subprocess_cwd() {
        let dir = std::env::temp_dir().join(format!("brewping-cwd-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();

        let out = std::process::Command::new("cmd")
            .args(["/c", "cd"])
            .current_dir(&dir)
            .output()
            .expect("cmd 应能启动");

        let stdout = String::from_utf8_lossy(&out.stdout);
        assert_eq!(
            stdout.trim().to_ascii_lowercase(),
            dir.to_string_lossy().trim().to_ascii_lowercase(),
            "子进程 cwd 未切到指定目录"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    // TC-WD-04  接线层：workdir 指向已删除的目录 → failureReason == "invalid_workdir"
    //           （不是 process_exited）。同时证明偏好被读到、预检生效、错误分类正确。
    //           注意 workdir 白名单包含 temp 盘符（固定盘在 allowlist 内）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn message_with_missing_workdir_fails_as_invalid_workdir() {
        let srv = spawn_server().await;
        // 让 claude-code 可用并指向 cmd，便于走真实 spawn 路径
        srv.state.agents.write().await[1] = crate::services::agent_discovery::AgentEntry {
            id: "claude-code".to_string(),
            name: "Claude Code".to_string(),
            installed: true,
            active: true,
            executable: Some("cmd".to_string()),
            version: Some("1.0.0".into()),
        };

        // 设一个"当前存在"的 workdir，然后删掉它
        let dir = std::env::temp_dir().join(format!("brewping-wd-gone-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let dir_str = dir.to_string_lossy().to_string();
        srv.state
            .workdir_prefs
            .set("claude-code", Some(crate::services::folder_browser::validate_workdir(&dir_str).unwrap().as_str()));
        std::fs::remove_dir_all(&dir).unwrap();

        // 切默认 agent 并开会话（POST /api/agents/default 会停掉已有会话）
        post(srv.port, "/api/agents/default", r#"{"agent":"claude-code"}"#);
        let (code, _) = post(srv.port, "/api/session/start", "{}");
        assert_eq!(code, 200);

        let (code, v) = post(srv.port, "/api/message", r#"{"text":"hello"}"#);
        assert_eq!(code, 200);
        let cmd_id = v["commandId"].as_str().expect("应有 commandId").to_string();

        // 轮询直到终态
        let mut status = String::new();
        let mut failure_reason: Option<String> = None;
        for _ in 0..50 {
            let (_, v) = get(srv.port, &format!("/api/message/{}", cmd_id));
            status = v["status"].as_str().unwrap_or("").to_string();
            if status == "completed" || status == "failed" {
                failure_reason = v["failureReason"].as_str().map(|s| s.to_string());
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
        assert_eq!(status, "failed");
        assert_eq!(
            failure_reason.as_deref(),
            Some("invalid_workdir"),
            "目录没了必须报 invalid_workdir，实际 {:?}",
            failure_reason
        );
    }

    // TC-WD-02b  接线层（正向）：workdir 存在时，子进程 cwd 真的切过去了。
    //            用一个 `@echo %CD%` 批处理文件作可执行文件，stdout 即为子进程 cwd。
    //            （不直接用 `cmd /c cd`：text 是单个 arg，会被 Rust 引号成 "/c cd"，
    //             cmd.exe 对这种引号的解析规则不可靠。Rust std 对 .cmd 会经 cmd.exe 启动。）
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn message_with_valid_workdir_runs_in_it() {
        let srv = spawn_server().await;

        let dir = std::env::temp_dir().join(format!("brewping-wd-here-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let bat = std::env::temp_dir().join(format!("brewping-wd-printcwd-{}.cmd", uuid::Uuid::new_v4()));
        std::fs::write(&bat, b"@echo %CD%\r\n").unwrap();

        srv.state.agents.write().await[1] = crate::services::agent_discovery::AgentEntry {
            id: "claude-code".to_string(),
            name: "Claude Code".to_string(),
            installed: true,
            active: true,
            executable: Some(bat.to_string_lossy().to_string()),
            version: Some("1.0.0".into()),
        };
        // submit_command 的回显与 response 拼接都发生在 terminal entry 存在时
        // （`map.get_mut(&aid)`），不 init 的话 response 会是空串。
        srv.state
            .terminal
            .init_from_agents(&srv.state.agents.read().await.clone())
            .await;
        let dir_str = dir.to_string_lossy().to_string();
        srv.state
            .workdir_prefs
            .set("claude-code", Some(crate::services::folder_browser::validate_workdir(&dir_str).unwrap().as_str()));

        post(srv.port, "/api/agents/default", r#"{"agent":"claude-code"}"#);
        post(srv.port, "/api/session/start", "{}");

        let (code, v) = post(srv.port, "/api/message", r#"{"text":"ignored"}"#);
        assert_eq!(code, 200);
        let cmd_id = v["commandId"].as_str().expect("应有 commandId").to_string();

        let mut response: Option<String> = None;
        for _ in 0..50 {
            let (_, v) = get(srv.port, &format!("/api/message/{}", cmd_id));
            if v["status"] == "completed" {
                response = v["response"].as_str().map(|s| s.to_string());
                break;
            }
            assert_ne!(v["status"], "failed", "不应失败: {}", v["error"]);
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
        let response = response.expect("命令应在超时前完成");
        assert_eq!(
            response.trim().to_ascii_lowercase(),
            dir_str.trim().to_ascii_lowercase(),
            "子进程应跑在设定的 workdir 里"
        );
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_file(&bat);
    }

    // ─── 多对话 HTTP 契约（方案 §10，TC-CA-01..08 / TC-CL-01） ──────────────

    /// 把 opencode 指向回声 bat（真实 spawn 路径测试的公共辅助）。
    async fn install_echo_opencode(srv: &TestServer) -> std::path::PathBuf {
        let bat = std::env::temp_dir().join(format!("brewping-echo-{}.cmd", uuid::Uuid::new_v4()));
        std::fs::write(&bat, b"@echo ECHOED-RESPONSE\r\n").unwrap();
        srv.state.agents.write().await[0] = crate::services::agent_discovery::AgentEntry {
            id: "opencode".to_string(),
            name: "OpenCode".to_string(),
            installed: true,
            active: true,
            executable: Some(bat.to_string_lossy().to_string()),
            version: Some("1.0.0".into()),
        };
        bat
    }

    // TC-CA-01  旧客户端（无新字段）POST /api/message → 落入 active 对话
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn legacy_message_falls_into_active_conversation() {
        let srv = spawn_server().await;
        let bat = install_echo_opencode(&srv).await;
        post(srv.port, "/api/session/start", "");

        let (code, v) = post(srv.port, "/api/message", r#"{"text":"hello"}"#);
        assert_eq!(code, 200);
        let conv_id = v["sessionId"].as_str().unwrap().to_string();
        assert!(conv_id.starts_with("conv_"));

        // active 对话里应有 user 条目（标题自动生成）
        let conv = srv.state.conversations.get(&conv_id).unwrap();
        assert_eq!(conv.messages.last().unwrap().role, "user");
        assert_eq!(conv.messages.last().unwrap().text, "hello");
        assert_eq!(conv.title_source.as_deref(), Some("auto"));
        let _ = std::fs::remove_file(&bat);
    }

    // TC-CA-02  POST /api/message 带 conversationId → 落入指定对话（即使非 active）
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn message_with_conversation_id_routes_explicitly() {
        let srv = spawn_server().await;
        let bat = install_echo_opencode(&srv).await;
        post(srv.port, "/api/session/start", "");
        let (_, v) = post(srv.port, "/api/session/start", "");
        let other = v["sessionId"].as_str().unwrap().to_string(); // 新 active
        // 第一个对话不是 active
        let first = srv.state.conversations.list(true)[1].id.clone();

        let (code, v) = post(
            srv.port,
            "/api/message",
            &format!(r#"{{"text":"定向","conversationId":"{first}"}}"#),
        );
        assert_eq!(code, 200);
        assert_eq!(v["sessionId"].as_str().unwrap(), first.as_str());

        // 消息进了指定对话，而不是 active 对话
        let conv = srv.state.conversations.get(&first).unwrap();
        assert!(conv.messages.iter().any(|m| m.text == "定向"));
        let active_conv = srv.state.conversations.get(&other).unwrap();
        assert!(!active_conv.messages.iter().any(|m| m.text == "定向"));
        let _ = std::fs::remove_file(&bat);
    }

    // TC-CA-06  未知 conversationId → 404 JSON；归档对话 → 409
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn message_to_unknown_or_archived_conversation_rejected() {
        let srv = spawn_server().await;

        let (code, v) = post(
            srv.port,
            "/api/message",
            r#"{"text":"hi","conversationId":"conv_ghost"}"#,
        );
        assert_eq!(code, 404);
        assert_eq!(v["success"], false);

        // 归档对话拒收
        post(srv.port, "/api/session/start", "");
        let (_, list) = get(srv.port, "/api/conversations");
        let conv_id = list["conversations"][0]["id"].as_str().unwrap().to_string();
        let (code, _) = request(
            srv.port,
            "PATCH",
            &format!("/api/conversations/{conv_id}"),
            Some(r#"{"archived":true}"#),
        );
        assert_eq!(code, 200);
        let (code, v) = post(
            srv.port,
            "/api/message",
            &format!(r#"{{"text":"hi","conversationId":"{conv_id}"}}"#),
        );
        assert_eq!(code, 409);
        assert!(v["error"].as_str().unwrap().contains("archived"));
    }

    // TC-CA-08  两段式删除：未归档 DELETE → 409；归档后 DELETE → 200
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn delete_requires_archived_state() {
        let srv = spawn_server().await;
        post(srv.port, "/api/session/start", "");
        let (_, list) = get(srv.port, "/api/conversations");
        let conv_id = list["conversations"][0]["id"].as_str().unwrap().to_string();

        // 删 active 对话前先归档 → 归档同时清除 active（不自动跳转）
        let (code, _) = request(
            srv.port,
            "PATCH",
            &format!("/api/conversations/{conv_id}"),
            Some(r#"{"archived":true}"#),
        );
        assert_eq!(code, 200);
        let (_, status) = get(srv.port, "/api/status");
        assert!(status["session"].is_null(), "归档 active 对话后 active 应为空");

        // 未归档删除已被上面覆盖；归档态删除成功
        let (code, raw) = request(srv.port, "DELETE", &format!("/api/conversations/{conv_id}"), Some(""));
        assert_eq!(code, 200);
        let v = json(&raw);
        assert_eq!(v["success"], true);
        // 删除后列表（含归档）不再有该对话
        let (_, list) = get(srv.port, "/api/conversations?includeArchived=true");
        let ids: Vec<&str> = list["conversations"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["id"].as_str().unwrap())
            .collect();
        assert!(!ids.contains(&conv_id.as_str()));
    }

    // TC-CL-01  GET /api/conversations 排序：置顶优先 + 最新活动降序
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn conversation_list_pinned_first_sorting() {
        let srv = spawn_server().await;
        let (_, a) = post(srv.port, "/api/session/start", "");
        let (_, b) = post(srv.port, "/api/session/start", "");
        let a_id = a["sessionId"].as_str().unwrap().to_string();
        let b_id = b["sessionId"].as_str().unwrap().to_string();

        // 置顶较早创建的 a（updated_at 较小）
        let (code, _) = request(
            srv.port,
            "PATCH",
            &format!("/api/conversations/{a_id}"),
            Some(r#"{"pinned":true}"#),
        );
        assert_eq!(code, 200);

        let (_, list) = get(srv.port, "/api/conversations");
        let ids: Vec<String> = list["conversations"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["id"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(ids.first(), Some(&a_id), "置顶必须排最前");
        assert!(ids.contains(&b_id));
        // 摘要里不应有 messages 字段（元数据层/转录层分离）
        for c in list["conversations"].as_array().unwrap() {
            assert!(c.get("messages").is_none(), "列表不得携带转录");
            assert!(c.get("messageCount").is_some(), "列表必须带 messageCount");
        }
        let _ = b_id;
    }

    // ─── 流式增量（回归：回复必须"边接收边推"，而不是进程结束才整段出现）────

    /// 广播事件录制器（替代 tauri 的 emit，测试里直接收集事件）。
    type EventLog = Arc<std::sync::Mutex<Vec<(String, serde_json::Value)>>>;

    async fn spawn_server_with_events(log: EventLog) -> TestServer {
        let mut state = test_state();
        let sink = log.clone();
        state.app_events = Some(Arc::new(move |event, payload| {
            sink.lock()
                .expect("event log poisoned")
                .push((event.to_string(), payload));
        }));
        let (port, handle) = start_server(state.clone(), next_port(), None)
            .await
            .expect("HTTP 服务应能成功绑定端口");
        TestServer {
            port,
            state,
            _handle: handle,
        }
    }

    /// 分三批、每批间隔约 1s 输出的回声脚本（模拟 CLI 慢慢吐字）。
    async fn install_slow_echo_opencode(srv: &TestServer) -> std::path::PathBuf {
        let bat =
            std::env::temp_dir().join(format!("brewping-slow-{}.cmd", uuid::Uuid::new_v4()));
        std::fs::write(
            &bat,
            b"@echo off\r\necho PART-ONE\r\nping -n 2 127.0.0.1 >nul\r\necho PART-TWO\r\nping -n 2 127.0.0.1 >nul\r\necho PART-THREE\r\n",
        )
        .unwrap();
        srv.state.agents.write().await[0] = AgentEntry {
            id: "opencode".to_string(),
            name: "OpenCode".to_string(),
            installed: true,
            active: true,
            executable: Some(bat.to_string_lossy().to_string()),
            version: Some("1.0.0".into()),
        };
        bat
    }

    /// 等命令落终态（assistant 或 error 条目出现），返回最新快照。
    async fn wait_for_reply(
        srv: &TestServer,
        conv_id: &str,
    ) -> crate::services::conversation_store::Conversation {
        for _ in 0..200 {
            if let Some(c) = srv.state.conversations.get(conv_id) {
                if c.messages.iter().any(|m| m.role == "assistant" || m.role == "error") {
                    return c;
                }
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        panic!("命令结束后应落一条 assistant / error 转录");
    }

    // TC-CR-01  执行期间必须持续推送 conversation-delta，且文本单调增长
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn stdout_is_streamed_as_deltas_before_completion() {
        let log: EventLog = Arc::new(std::sync::Mutex::new(Vec::new()));
        let srv = spawn_server_with_events(log.clone()).await;
        let bat = install_slow_echo_opencode(&srv).await;
        post(srv.port, "/api/session/start", "");

        let (code, v) = post(srv.port, "/api/message", r#"{"text":"stream me"}"#);
        assert_eq!(code, 200);
        let conv_id = v["sessionId"].as_str().unwrap().to_string();
        let cmd_id = v["commandId"].as_str().unwrap().to_string();
        let conv = wait_for_reply(&srv, &conv_id).await;

        let events = log.lock().unwrap().clone();
        let deltas: Vec<(String, String, bool)> = events
            .iter()
            .filter(|(name, _)| name == "conversation-delta")
            .map(|(_, p)| {
                (
                    p["text"].as_str().unwrap_or_default().to_string(),
                    p["conversationId"].as_str().unwrap_or_default().to_string(),
                    p["done"].as_bool().unwrap_or(false),
                )
            })
            .collect();

        // 1) 增量必须写进"当前会话"，不能串台
        assert!(
            deltas.iter().all(|(_, cid, _)| cid == &conv_id),
            "增量的 conversationId 必须都是当前对话: {deltas:?}"
        );
        assert!(
            events
                .iter()
                .filter(|(n, _)| n == "conversation-delta")
                .all(|(_, p)| p["commandId"].as_str() == Some(cmd_id.as_str())),
            "增量必须绑定到本次命令"
        );

        // 2) 必须在进程退出前就推过多次（流式，而非一次性整段）
        assert!(
            deltas.len() >= 2,
            "慢速回声脚本应产生多个增量分片，实际 {deltas:?}"
        );
        assert!(
            deltas.first().unwrap().0.contains("PART-ONE"),
            "第一帧就该带上已收到的内容: {deltas:?}"
        );
        assert!(
            deltas.last().unwrap().0.contains("PART-THREE"),
            "末帧必须包含最后一批输出: {deltas:?}"
        );
        // 3) text 是累积全文 → 单调增长（丢帧也能自愈）
        for w in deltas.windows(2) {
            assert!(
                w[1].0.starts_with(&w[0].0) || w[1].0.len() >= w[0].0.len(),
                "增量文本必须单调增长: {:?} -> {:?}",
                w[0].0,
                w[1].0
            );
        }
        // 4) 末帧带 done，且之后还要补一次 conversations-changed（解除 busy）
        assert!(deltas.last().unwrap().2, "最后一个增量必须标记 done");
        let last_delta_idx = events
            .iter()
            .rposition(|(n, _)| n == "conversation-delta")
            .unwrap();
        assert!(
            events
                .iter()
                .skip(last_delta_idx + 1)
                .any(|(n, _)| n == "conversations-changed"),
            "done 之后必须补一次 conversations-changed，否则前端会卡在 busy"
        );
        // 5) 增量不落盘：转录里仍然只有一条 assistant 条目
        assert_eq!(
            conv.messages.iter().filter(|m| m.role == "assistant").count(),
            1,
            "流式增量不得污染转录"
        );
        assert!(
            conv.messages
                .iter()
                .any(|m| m.role == "assistant" && m.text.contains("PART-THREE"))
        );
        let _ = std::fs::remove_file(&bat);
    }

    // TC-CR-02  非零退出：stderr 走 error 条目，且收尾必须清掉调度指针
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn failing_command_streams_and_settles() {
        let log: EventLog = Arc::new(std::sync::Mutex::new(Vec::new()));
        let srv = spawn_server_with_events(log.clone()).await;
        let bat =
            std::env::temp_dir().join(format!("brewping-fail-{}.cmd", uuid::Uuid::new_v4()));
        std::fs::write(&bat, b"@echo off\r\necho boom 1>&2\r\nexit /b 3\r\n").unwrap();
        srv.state.agents.write().await[0] = AgentEntry {
            id: "opencode".to_string(),
            name: "OpenCode".to_string(),
            installed: true,
            active: true,
            executable: Some(bat.to_string_lossy().to_string()),
            version: Some("1.0.0".into()),
        };
        post(srv.port, "/api/session/start", "");
        let (code, v) = post(srv.port, "/api/message", r#"{"text":"will fail"}"#);
        assert_eq!(code, 200);
        let conv_id = v["sessionId"].as_str().unwrap().to_string();
        let conv = wait_for_reply(&srv, &conv_id).await;

        assert!(conv.messages.iter().any(|m| m.role == "error" && m.text.contains("boom")));
        assert_eq!(
            conv.latest_command_id, None,
            "收尾必须清掉调度指针，否则前端一直 busy"
        );
        let _ = std::fs::remove_file(&bat);
    }

    // TC-CA-05  新端点鉴权：GET 免 nonce、写操作需 nonce（与鉴权矩阵一致）
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn conversation_endpoints_require_auth() {
        let srv = spawn_server().await;
        let (code, raw) = request_anonymous(srv.port, "GET", "/api/conversations", None);
        assert_eq!(code, 401);
        let _: serde_json::Value = serde_json::from_str(&raw).expect("401 必须是 JSON");
        let (code, _) = request_anonymous(
            srv.port,
            "POST",
            "/api/conversations",
            Some(r#"{"agentId":"opencode"}"#),
        );
        assert_eq!(code, 401);
    }
}
