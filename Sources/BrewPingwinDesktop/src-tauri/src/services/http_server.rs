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
