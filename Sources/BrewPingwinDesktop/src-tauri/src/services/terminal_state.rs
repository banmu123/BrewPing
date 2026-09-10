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

#[cfg(test)]
mod tests {
    use super::*;

    fn agent(id: &str, name: &str) -> AgentEntry {
        AgentEntry {
            id: id.into(),
            name: name.into(),
            installed: true,
            active: true,
            executable: Some(id.into()),
            version: None,
        }
    }

    // TC-TS-01  行号自增且连续，从 0 开始
    #[test]
    fn append_line_increments_monotonic_ids() {
        let mut s = AgentTerminalState::new("opencode".into(), "OpenCode".into());
        assert!(s.output_lines.is_empty());
        s.append_line("first", OutputType::Normal);
        s.append_line("second", OutputType::System);
        s.append_line("third", OutputType::Error);
        assert_eq!(s.output_lines.len(), 3);
        assert_eq!(s.output_lines[0].id, 0);
        assert_eq!(s.output_lines[1].id, 1);
        assert_eq!(s.output_lines[2].id, 2);
        assert_eq!(s.output_lines[2].text, "third");
    }

    // TC-TS-02  边界：清空输出后行号必须从 0 重新开始，且不残留
    #[test]
    fn clear_output_resets_lines_and_id_counter() {
        let mut s = AgentTerminalState::new("opencode".into(), "OpenCode".into());
        s.append_line("a", OutputType::Normal);
        s.append_line("b", OutputType::Normal);
        s.clear_output();
        assert!(s.output_lines.is_empty());
        s.append_line("after-clear", OutputType::Normal);
        assert_eq!(s.output_lines.len(), 1);
        assert_eq!(s.output_lines[0].id, 0, "清空后行号应从 0 重新计数");
    }

    // TC-TS-03  边界：空字符串也应产生一条记录（当前实现不做过滤）
    #[test]
    fn append_empty_line_is_allowed() {
        let mut s = AgentTerminalState::new("x".into(), "X".into());
        s.append_line("", OutputType::Normal);
        assert_eq!(s.output_lines.len(), 1);
        assert_eq!(s.output_lines[0].text, "");
    }

    // TC-TS-04  状态迁移
    #[test]
    fn set_status_updates_status() {
        let mut s = AgentTerminalState::new("x".into(), "X".into());
        assert!(matches!(s.status, AgentStatus::Idle));
        s.set_status(AgentStatus::Running);
        assert!(matches!(s.status, AgentStatus::Running));
        s.set_status(AgentStatus::Error);
        assert!(matches!(s.status, AgentStatus::Error));
    }

    // TC-TS-05  TerminalManager 默认活动代理
    #[tokio::test]
    async fn terminal_manager_defaults_to_opencode() {
        let tm = TerminalManager::new();
        assert_eq!(*tm.active_agent_id.read().await, "opencode");
        assert!(tm.agents.read().await.is_empty());
    }

    // TC-TS-06  幂等：重复初始化不覆盖已有状态与输出
    #[tokio::test]
    async fn init_from_agents_is_idempotent() {
        let tm = TerminalManager::new();
        let list = vec![agent("opencode", "OpenCode"), agent("codex", "Codex CLI")];
        tm.init_from_agents(&list).await;
        {
            let mut map = tm.agents.write().await;
            map.get_mut("opencode").unwrap().append_line("keep me", OutputType::Normal);
            map.get_mut("opencode").unwrap().set_status(AgentStatus::Running);
        }
        tm.init_from_agents(&list).await;
        let map = tm.agents.read().await;
        assert_eq!(map.len(), 2);
        assert_eq!(map["opencode"].output_lines.len(), 1, "重复初始化不得清空输出");
        assert!(matches!(map["opencode"].status, AgentStatus::Running));
    }

    // TC-TS-07  序列化契约：camelCase 键名 + 小写枚举，且内部字段不泄漏
    #[test]
    fn serializes_with_frontend_contract() {
        let mut s = AgentTerminalState::new("opencode".into(), "OpenCode".into());
        s.append_line("hello", OutputType::Normal);
        s.append_line("sys", OutputType::System);
        s.set_status(AgentStatus::Running);

        let v = serde_json::to_value(&s).unwrap();
        assert_eq!(v["agentId"], "opencode");
        assert_eq!(v["agentName"], "OpenCode");
        assert_eq!(v["status"], "running");
        assert_eq!(v["outputLines"][0]["type"], "normal");
        assert_eq!(v["outputLines"][0]["text"], "hello");
        assert_eq!(v["outputLines"][0]["id"], 0);
        assert_eq!(v["outputLines"][1]["type"], "system");
        assert!(v.get("next_id").is_none(), "内部 next_id 不应序列化到前端");
        assert!(v.get("output_lines").is_none(), "不应输出 snake_case 键名");
    }
}
