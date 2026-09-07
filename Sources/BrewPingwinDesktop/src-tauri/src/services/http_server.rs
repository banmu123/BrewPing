use axum::{
    extract::Path,
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::sync::RwLock;

use super::agent_discovery::AgentEntry;
use super::device_identity::DeviceIdentity;

/// Shared application state for the HTTP server.
#[derive(Clone)]
pub struct AppState {
    pub identity: DeviceIdentity,
    pub lan_ip: String,
    pub port: u16,
    pub agents: Arc<RwLock<Vec<AgentEntry>>>,
    pub default_agent: Arc<RwLock<String>>,
    pub session: Arc<RwLock<Option<SessionInfo>>>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SessionInfo {
    pub id: String,
    pub agent: String,
    #[serde(rename = "agentName")]
    pub agent_name: String,
    pub status: String,
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
    agents: Vec<AgentEntry>,
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
        // Always bind to all interfaces so the API is accessible from localhost and LAN
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
    Json(AgentsResponse {
        agents,
        default_agent,
    })
}

async fn handle_set_default_agent(
    axum::extract::State(state): axum::extract::State<AppState>,
    Json(body): Json<SetAgentBody>,
) -> Json<SuccessResponse> {
    let mut default = state.default_agent.write().await;
    *default = body.agent.clone();
    log::info!("Default agent set to: {}", body.agent);
    Json(SuccessResponse {
        success: true,
        default_agent: Some(body.agent),
        session_id: None,
        status: None,
        command_id: None,
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
    })
}

async fn handle_send_message(
    axum::extract::State(state): axum::extract::State<AppState>,
    Json(body): Json<MessageBody>,
) -> Result<Json<SuccessResponse>, StatusCode> {
    let session = state.session.read().await;
    if session.is_none() {
        return Err(StatusCode::BAD_REQUEST);
    }
    let sid = session.as_ref().unwrap().id.clone();
    drop(session);

    let command_id = format!("cmd_{}", &uuid::Uuid::new_v4().to_string()[..8]);
    log::info!(
        "Message received: '{}' -> {} (command: {})",
        body.text,
        sid,
        command_id
    );

    // TODO: Route to actual agent process
    // For now, return the command ID immediately (protocol-compatible)

    Ok(Json(SuccessResponse {
        success: true,
        default_agent: None,
        session_id: Some(sid),
        status: Some("queued".to_string()),
        command_id: Some(command_id),
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

async fn handle_get_message(
    Path(id): Path<String>,
    axum::extract::State(_state): axum::extract::State<AppState>,
) -> Json<CommandStatusResponse> {
    // TODO: Look up actual command status from CommandStore
    Json(CommandStatusResponse {
        command_id: id,
        session_id: "unknown".to_string(),
        status: "queued".to_string(),
        response: None,
        raw_output: None,
        error: None,
        failure_reason: None,
        model_id: None,
        duration: None,
    })
}

async fn handle_discovery_refresh(
    axum::extract::State(state): axum::extract::State<AppState>,
) -> Json<AgentsResponse> {
    // Force re-discovery
    let new_agents = super::agent_discovery::discover();
    let mut agents = state.agents.write().await;
    *agents = new_agents.clone();
    let default_agent = state.default_agent.read().await.clone();

    log::info!("Agent discovery refreshed: {} agents", new_agents.len());
    Json(AgentsResponse {
        agents: new_agents,
        default_agent,
    })
}
