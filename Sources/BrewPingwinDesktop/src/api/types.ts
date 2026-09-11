/// Desktop status payload from Tauri backend.
export interface DesktopStatus {
  host: string;
  defaultAgent: string;
  session: SessionInfo | null;
  agents: AgentEntry[];
  port: number;
  lanIp: string;
  mdnsRunning: boolean;
  platform: string;
  version: string;
  deviceId: string;
  activeAgentId: string;
  /// 三段式运行时状态（对齐 macOS DesktopCore.RuntimeState）。
  runtimeState: RuntimeState;
}

/// 与 macOS `DesktopCore.RuntimeState` 的 rawValue 一一对应。
export type RuntimeState = "idle" | "starting" | "online" | "offline";

export interface AgentEntry {
  id: string;
  name: string;
  installed: boolean;
  active: boolean;
  executable: string | null;
  version: string | null;
}

export interface SessionInfo {
  id: string;
  agent: string;
  agentName: string;
  status: string;
}

/// Terminal output line (matches macOS OutputLine).
export interface OutputLine {
  id: number;
  text: string;
  type: "normal" | "system" | "error";
}

/// Agent terminal status (matches macOS AgentStatus).
export type AgentStatus = "idle" | "running" | "error" | "stopped";

/// Per-agent terminal state (matches macOS AgentTerminalState).
export interface AgentTerminalState {
  agentId: string;
  agentName: string;
  outputLines: OutputLine[];
  status: AgentStatus;
}

// ─── Pairing (对齐 macOS PairingStore / MenuBarView) ─────────────────────────

/// 配对信息：配对码 + `brewping://pair?...` 深链（用于渲染二维码）。
export interface PairingInfo {
  /// 当前仍有效的配对码；未揭示 / 已过期 / 已被消费时为 null。
  code: string | null;
  /// 配对码过期时刻（ISO8601）。
  expiresAt: string | null;
  /// iPhone 扫码后可直接配对的深链。
  url: string | null;
  deviceId: string;
  deviceName: string;
  host: string;
  port: number;
}

// ─── Approval (对齐 macOS ApprovalGate) ──────────────────────────────────────

/// 与 macOS `ApprovalMode` / iOS `Mode` rawValue 一一对应。
export type ApprovalMode = "safe" | "askAll" | "auto";

/// 一次危险命中。
export interface ApprovalReason {
  /// 稳定的机器可读标识（与 macOS DangerPattern 的 code 相同）。
  code: string;
  /// 命中的原始片段提示。
  detail: string;
}

/// 一条等待用户确认的命令。
export interface PendingApproval {
  id: string;
  text: string;
  reasons: ApprovalReason[];
  createdAt: string;
}

// ─── Models (对齐 http_server::handle_agent_models 的 JSON 契约) ─────────────

/// 一个可选模型。
export interface ProviderModel {
  id: string;
  name: string;
  available: boolean;
  isActive: boolean;
  isDefault: boolean;
}

/// 一个 Provider 及其模型。
export interface ProviderInfo {
  id: string;
  name: string;
  models: ProviderModel[];
  baseURL?: string;
}

/// `get_agent_models` 的返回。
export interface AgentModelsInfo {
  agentId: string;
  providers: ProviderInfo[];
  activeModelId: string | null;
  preferredModelId: string | null;
}
