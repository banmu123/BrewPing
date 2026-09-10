use axum::{
    extract::Path,
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::sync::RwLock;

use super::agent_discovery::{AgentEntry, AgentEntryApi};
use super::device_identity::DeviceIdentity;
use super::terminal_state::{AgentStatus, OutputType, TerminalManager};

/// Shared application state for the HTTP server.
#[derive(Clone)]
pub struct AppState {
    pub identity: DeviceIdentity,
    pub lan_ip: String,
    pub port: u16,
    pub agents: Arc<RwLock<Vec<AgentEntry>>>,
    pub default_agent: Arc<RwLock<String>>,
    pub session: Arc<RwLock<Option<SessionInfo>>>,
    pub terminal: TerminalManager,
    pub command_store: CommandStore,
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
}

impl CommandStore {
    pub fn new() -> Self {
        Self {
            commands: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    async fn insert_pending(&self, command_id: &str) {
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
            },
        );
    }

    async fn set_working(&self, command_id: &str) {
        let mut map = self.commands.write().await;
        if let Some(entry) = map.get_mut(command_id) {
            entry.status = "working".to_string();
        }
    }

    async fn set_completed(&self, command_id: &str, response: String, duration: Option<f64>) {
        let mut map = self.commands.write().await;
        if let Some(entry) = map.get_mut(command_id) {
            entry.status = "completed".to_string();
            entry.response = Some(response);
            entry.duration = duration;
        }
    }

    async fn set_failed(
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
struct SuccessResponse {
    success: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "defaultAgent")]
    default_agent: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "sessionId")]
    session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "commandId")]
    command_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

/// Build the axum router with all API routes.
pub fn build_router(state: AppState) -> Router {
    Router::new()
        .route("/api/status", get(handle_status))
        .route("/api/agents", get(handle_agents))
        .route("/api/agents/default", post(handle_set_default_agent))
        .route("/api/message", post(handle_send_message))
        .route("/api/message/{id}", get(handle_get_message))
        .route("/api/session/start", post(handle_start_session))
        .route("/api/session/stop", post(handle_stop_session))
        .route("/api/discovery/refresh", post(handle_discovery_refresh))
        .with_state(state)
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
    let session = state.session.read().await.clone();
    Json(StatusResponse {
        status: "online",
        host: super::device_identity::get_device_name(),
        default_agent,
        session,
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
            api
        })
        .collect();

    Json(AgentsResponse {
        agents: api_agents,
        default_agent,
    })
}

async fn handle_set_default_agent(
    axum::extract::State(state): axum::extract::State<AppState>,
    Json(body): Json<SetAgentBody>,
) -> Json<SuccessResponse> {
    // Stop existing session when switching agent
    {
        let mut session = state.session.write().await;
        if session.is_some() {
            log::info!("Stopping session due to agent switch");
            *session = None;
        }
    }

    let mut default = state.default_agent.write().await;
    *default = body.agent.clone();
    log::info!("Default agent set to: {}", body.agent);
    Json(SuccessResponse {
        success: true,
        default_agent: Some(body.agent),
        session_id: None,
        status: Some("stopped".to_string()),
        command_id: None,
        error: None,
    })
}

async fn handle_start_session(
    axum::extract::State(state): axum::extract::State<AppState>,
) -> Json<SuccessResponse> {
    let session_id = format!("sess_{}", &uuid::Uuid::new_v4().to_string()[..8]);
    let default_agent = state.default_agent.read().await.clone();
    let agents = state.agents.read().await;
    let agent_name = agents
        .iter()
        .find(|a| a.id == default_agent)
        .map(|a| a.name.clone())
        .unwrap_or_else(|| default_agent.clone());
    drop(agents);

    let mut session = state.session.write().await;
    *session = Some(SessionInfo {
        id: session_id.clone(),
        agent: default_agent,
        agent_name,
        status: "running".to_string(),
    });

    log::info!("Session started: {}", session_id);
    Json(SuccessResponse {
        success: true,
        default_agent: None,
        session_id: Some(session_id),
        status: Some("running".to_string()),
        command_id: None,
        error: None,
    })
}

async fn handle_stop_session(
    axum::extract::State(state): axum::extract::State<AppState>,
) -> Json<SuccessResponse> {
    let mut session = state.session.write().await;
    let sid = session.as_ref().map(|s| s.id.clone());
    *session = None;

    log::info!("Session stopped: {:?}", sid);
    Json(SuccessResponse {
        success: true,
        default_agent: None,
        session_id: sid,
        status: Some("stopped".to_string()),
        command_id: None,
        error: None,
    })
}

/// POST /api/message — submit a command and execute it via TerminalManager.
async fn handle_send_message(
    axum::extract::State(state): axum::extract::State<AppState>,
    Json(body): Json<MessageBody>,
) -> Result<Json<SuccessResponse>, StatusCode> {
    let session = state.session.read().await;
    if session.is_none() {
        return Err(StatusCode::BAD_REQUEST);
    }
    let sid = session.as_ref().unwrap().id.clone();
    let agent_id = session.as_ref().unwrap().agent.clone();
    drop(session);

    let command_id = format!("cmd_{}", &uuid::Uuid::new_v4().to_string()[..8]);
    log::info!(
        "Message received: '{}' -> {} (command: {}, agent: {})",
        body.text,
        sid,
        command_id,
        agent_id
    );

    // Register command as pending
    state.command_store.insert_pending(&command_id).await;

    // Show user input in terminal
    {
        let mut map = state.terminal.agents.write().await;
        if let Some(term) = map.get_mut(&agent_id) {
            term.append_line(&format!("> {}", body.text), OutputType::System);
        }
    }

    // Spawn async execution
    let terminal = state.terminal.clone();
    let command_store = state.command_store.clone();
    let agents = state.agents.read().await.clone();
    let text = body.text.clone();
    let cmd_id = command_id.clone();
    let aid = agent_id.clone();

    tokio::spawn(async move {
        command_store.set_working(&cmd_id).await;

        let start = std::time::Instant::now();

        if aid == "opencode" {
            // Session agent: simulate processing
            let agent_name = agents
                .iter()
                .find(|a| a.id == aid)
                .map(|a| a.name.clone())
                .unwrap_or_else(|| "OpenCode".to_string());

            {
                let mut map = terminal.agents.write().await;
                if let Some(term) = map.get_mut(&aid) {
                    term.append_line(
                        &format!("Message sent to {}", agent_name),
                        OutputType::System,
                    );
                }
            }
            command_store
                .set_completed(&cmd_id, format!("Command received by {}", agent_name), None)
                .await;
        } else {
            // CLI agent: spawn process
            let agent_entry = agents.iter().find(|a| a.id == aid).cloned();
            let Some(agent) = agent_entry else {
                let err = format!("Agent '{}' not available", aid);
                {
                    let mut map = terminal.agents.write().await;
                    if let Some(term) = map.get_mut(&aid) {
                        term.append_line(&format!("Error: {}", err), OutputType::Error);
                        term.set_status(AgentStatus::Idle);
                    }
                }
                command_store.set_failed(&cmd_id, err, None, None).await;
                return;
            };

            let Some(ref executable) = agent.executable else {
                let err = format!("Executable not found for {}", aid);
                {
                    let mut map = terminal.agents.write().await;
                    if let Some(term) = map.get_mut(&aid) {
                        term.append_line(&format!("Error: {}", err), OutputType::Error);
                        term.set_status(AgentStatus::Error);
                    }
                }
                command_store
                    .set_failed(&cmd_id, err, Some("process_exited".to_string()), None)
                    .await;
                return;
            };

            // Set running
            {
                let mut map = terminal.agents.write().await;
                if let Some(term) = map.get_mut(&aid) {
                    term.set_status(AgentStatus::Running);
                }
            }

            let exec_clone = executable.clone();
            let text_clone = text.clone();
            let aid_clone = aid.clone();
            let terminal_clone = terminal.clone();
            let cmd_clone = cmd_id.clone();
            let store_clone = command_store.clone();

            let result = tokio::task::spawn_blocking(move || {
                let mut cmd = std::process::Command::new(&exec_clone);
                cmd.arg(&text_clone)
                    .stdout(std::process::Stdio::piped())
                    .stderr(std::process::Stdio::piped());

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

                cmd.output()
            })
            .await;

            let elapsed = start.elapsed().as_secs_f64();

            match result {
                Ok(Ok(output)) => {
                    let stdout = String::from_utf8_lossy(&output.stdout);
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    let mut response_text = String::new();

                    {
                        let mut map = terminal_clone.agents.write().await;
                        if let Some(term) = map.get_mut(&aid_clone) {
                            if output.status.success() {
                                for line in stdout.split('\n') {
                                    if !line.is_empty() {
                                        term.append_line(line, OutputType::Normal);
                                        response_text.push_str(line);
                                        response_text.push('\n');
                                    }
                                }
                                if stdout.trim().is_empty() {
                                    term.append_line("(no output)", OutputType::System);
                                    response_text = "(no output)".to_string();
                                }
                            } else {
                                let err_line = format!(
                                    "Exit code: {}",
                                    output.status.code().unwrap_or(-1)
                                );
                                term.append_line(&err_line, OutputType::Error);
                                if !stderr.trim().is_empty() {
                                    term.append_line(stderr.trim(), OutputType::Error);
                                }
                                store_clone
                                    .set_failed(
                                        &cmd_clone,
                                        format!("{}\n{}", err_line, stderr.trim()),
                                        Some("process_exited".to_string()),
                                        Some(elapsed),
                                    )
                                    .await;
                                term.set_status(AgentStatus::Idle);
                                return;
                            }
                            term.set_status(AgentStatus::Idle);
                        }
                    }

                    store_clone
                        .set_completed(&cmd_clone, response_text.trim().to_string(), Some(elapsed))
                        .await;
                }
                Ok(Err(e)) => {
                    let err = format!("Failed to start process: {}", e);
                    {
                        let mut map = terminal_clone.agents.write().await;
                        if let Some(term) = map.get_mut(&aid_clone) {
                            term.append_line(&format!("Error: {}", err), OutputType::Error);
                            term.set_status(AgentStatus::Error);
                        }
                    }
                    store_clone
                        .set_failed(
                            &cmd_clone,
                            err,
                            Some("process_exited".to_string()),
                            Some(elapsed),
                        )
                        .await;
                }
                Err(e) => {
                    let err = format!("Task join error: {}", e);
                    {
                        let mut map = terminal_clone.agents.write().await;
                        if let Some(term) = map.get_mut(&aid_clone) {
                            term.append_line(&format!("Error: {}", err), OutputType::Error);
                            term.set_status(AgentStatus::Error);
                        }
                    }
                    store_clone
                        .set_failed(&cmd_clone, err, None, Some(elapsed))
                        .await;
                }
            }
        }
    });

    Ok(Json(SuccessResponse {
        success: true,
        default_agent: None,
        session_id: Some(sid),
        status: Some("queued".to_string()),
        command_id: Some(command_id),
        error: None,
    }))
}

#[derive(Serialize)]
struct CommandStatusResponse {
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
            session_id: "unknown".to_string(),
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
            api
        })
        .collect();

    log::info!("Agent discovery refreshed: {} agents", new_agents.len());
    Json(AgentsResponse {
        agents: api_agents,
        default_agent,
    })
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
            session: Arc::new(RwLock::new(None)),
            terminal: TerminalManager::new(),
            command_store: CommandStore::new(),
        }
    }

    struct TestServer {
        port: u16,
        _handle: tokio::task::JoinHandle<()>,
    }

    async fn spawn_server() -> TestServer {
        let (port, handle) = start_server(test_state(), next_port(), None)
            .await
            .expect("HTTP 服务应能成功绑定端口");
        TestServer {
            port,
            _handle: handle,
        }
    }

    /// 最小化 HTTP/1.1 客户端：直接使用裸 TCP，避免引入额外测试依赖。
    fn request(port: u16, method: &str, path: &str, body: Option<&str>) -> (u16, String) {
        let payload = body.unwrap_or("");
        let mut stream = TcpStream::connect(("127.0.0.1", port)).expect("连接 HTTP 服务失败");
        stream
            .set_read_timeout(Some(Duration::from_secs(10)))
            .unwrap();
        let raw_req = format!(
            "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{payload}",
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
        store.insert_pending("cmd_1").await;
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
        store.insert_pending("cmd_2").await;
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
        store.insert_pending("cmd_3").await;
        store.set_completed("cmd_3", "old".into(), Some(9.0)).await;
        store.insert_pending("cmd_3").await;
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
        assert!(sid.starts_with("sess_"), "会话 ID 前缀应为 sess_");

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
        assert!(status["session"].is_null(), "停止后不应再有会话");
    }

    // TC-HT-05  边界：重复 start 会话应替换为新会话，不残留旧会话
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

    // TC-HT-07  切换默认代理会终止既有会话（业务规则）
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn switching_default_agent_stops_session() {
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
        assert!(status["session"].is_null(), "切换代理后会话应被终止");
    }

    // TC-HT-08  端到端：会话内投递消息 → 轮询至 completed
    // NOTE: 必须使用多线程运行时 —— 测试体使用同步 TcpStream 收发，
    // 单线程运行时会被阻塞导致服务端任务无法被调度（表现为读取超时）。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn message_roundtrip_completes() {
        let srv = spawn_server().await;
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
            body["response"].as_str().unwrap().contains("OpenCode"),
            "响应内容应包含代理名称: {body}"
        );
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
}
