use serde::Serialize;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

use super::agent_discovery::AgentEntry;

/// A single line in the terminal output.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OutputLine {
    pub id: usize,
    pub text: String,
    #[serde(rename = "type")]
    pub line_type: OutputType,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum OutputType {
    Normal,
    System,
    Error,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum AgentStatus {
    Idle,
    Running,
    Error,
    Stopped,
}

/// Per-agent terminal state (matches macOS AgentTerminalState).
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentTerminalState {
    pub agent_id: String,
    pub agent_name: String,
    pub output_lines: Vec<OutputLine>,
    pub status: AgentStatus,
    #[serde(skip)]
    next_id: usize,
}

impl AgentTerminalState {
    pub fn new(agent_id: String, agent_name: String) -> Self {
        Self {
            agent_id,
            agent_name,
            output_lines: Vec::new(),
            status: AgentStatus::Idle,
            next_id: 0,
        }
    }

    pub fn append_line(&mut self, text: &str, line_type: OutputType) {
        let id = self.next_id;
        self.next_id += 1;
        self.output_lines.push(OutputLine {
            id,
            text: text.to_string(),
            line_type,
        });
    }

    pub fn set_status(&mut self, status: AgentStatus) {
        self.status = status;
    }

    pub fn clear_output(&mut self) {
        self.output_lines.clear();
        self.next_id = 0;
    }
}

/// Manages terminal state for all agents (shared between Tauri commands and HTTP server).
#[derive(Clone)]
pub struct TerminalManager {
    pub agents: Arc<RwLock<HashMap<String, AgentTerminalState>>>,
    pub active_agent_id: Arc<RwLock<String>>,
}

impl TerminalManager {
    pub fn new() -> Self {
        Self {
            agents: Arc::new(RwLock::new(HashMap::new())),
            active_agent_id: Arc::new(RwLock::new("opencode".to_string())),
        }
    }

    /// Initialize terminal states from discovered agents.
    pub async fn init_from_agents(&self, agents: &[AgentEntry]) {
        let mut map = self.agents.write().await;
        for agent in agents {
            if !map.contains_key(&agent.id) {
                map.insert(
                    agent.id.clone(),
                    AgentTerminalState::new(agent.id.clone(), agent.name.clone()),
                );
            }
        }
    }
}
