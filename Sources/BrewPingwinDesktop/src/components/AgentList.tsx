import type { AgentEntry } from "../api/types";

interface Props {
  agents: AgentEntry[];
  defaultAgent: string;
  onSetDefault: (agentId: string) => void;
}

export function AgentList({ agents, defaultAgent, onSetDefault }: Props) {
  return (
    <div className="card">
      <div className="card-header">
        <h2>代理列表</h2>
        <span className="count">{agents.filter((a) => a.installed).length} 已安装</span>
      </div>
      <div className="card-body">
        {agents.length === 0 ? (
          <div className="empty">未发现代理</div>
        ) : (
          agents.map((agent) => (
            <div key={agent.id} className="agent-row">
              <div className="agent-info">
                <span
                  className={`status-dot ${agent.installed ? "online" : "offline"}`}
                />
                <span className="agent-name">{agent.name}</span>
                {agent.version && (
                  <span className="agent-version">v{agent.version}</span>
                )}
                {agent.id === defaultAgent && (
                  <span className="badge default">默认</span>
                )}
              </div>
              <div className="agent-actions">
                {agent.installed ? (
                  agent.id === defaultAgent ? (
                    <span className="text-green text-sm">✓ 默认</span>
                  ) : (
                    <button
                      className="btn btn-sm"
                      onClick={() => onSetDefault(agent.id)}
                    >
                      设为默认
                    </button>
                  )
                ) : (
                  <span className="text-gray text-sm">未安装</span>
                )}
              </div>
            </div>
          ))
        )}
      </div>
    </div>
  );
}
