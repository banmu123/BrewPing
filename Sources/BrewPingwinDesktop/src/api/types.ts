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
  /// 当前激活的对话 ID（多对话；草稿态/无对话为 null）。
  activeConversationId: string | null;
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
  /// 用户偏好对应的 providerId（同名模型跨 provider 时用于精确勾选；
  /// 旧记录 / 未带 provider 时为 null）。
  preferredProviderId?: string | null;
}

// ─── Folder browse（composer 目录条；对齐 folder_browser.rs 的 serde 契约）──

/// 浏览根列表（主目录 + 盘符；drives 仅 Windows 有）。
export interface BrowseRootsInfo {
  platform: string;
  pathSeparator: string;
  homeDir: string;
  drives: string[];
}

/// 目录里的一项（只列目录可入层级；文件条目由后端一并返回但 UI 不展示）。
export interface BrowseEntryInfo {
  name: string;
  absolutePath: string;
  isSymlink: boolean;
  hidden: boolean;
}

/// 浏览结果（分页字段保留但目录条场景不会触达截断）。
export interface BrowseResultInfo {
  path: string;
  parentPath: string | null;
  entries: BrowseEntryInfo[];
  truncated: boolean;
}

// ─── Conversations（多对话管理，对齐 conversation_store.rs 的 serde 契约）────

/// 一条对话消息（转录的最小单元）。
export interface TranscriptEntry {
  id: string;
  role: "user" | "assistant" | "error" | "system";
  text: string;
  source: string | null;
  commandId: string | null;
  createdAtMs: number;
}

/// 列表页摘要（元数据层：不含 messages，方案 §4.1 两层分离）。
export interface ConversationSummary {
  id: string;
  agentId: string;
  title: string | null;
  titleSource: string | null;
  createdAtMs: number;
  updatedAtMs: number;
  archived: boolean;
  isPinned: boolean;
  /// 对话级模型覆盖（null = 回落该 Agent 的全局偏好）。
  modelOverride: string | null;
  /// 与 `modelOverride` 配对的 providerId（同名模型可来自多个厂商）。
  modelProviderOverride: string | null;
  workdirOverride: string | null;
  /// 对话级授权档位（null = 回落全局默认）。授权按对话独立。
  approvalMode: ApprovalMode | null;
  /// 调度指针：非空 = 有命令在飞（isStreaming 依据，方案 §2-A4）。
  latestCommandId: string | null;
  messageCount: number;
}

/// 完整对话（转录层：打开对话才加载）。
export interface Conversation extends ConversationSummary {
  messages: TranscriptEntry[];
}

/// 流式增量事件（`conversation-delta`）：命令执行过程中后端边读边推。
/// `text` 是**累积全文**（幂等：丢一帧会被下一帧自愈），`done` 标记流已结束。
export interface ConversationDelta {
  conversationId: string;
  commandId: string;
  text: string;
  done: boolean;
}

// ─── 环境与 CLI 安装（设置页；对齐 env_setup.rs 的 serde 契约，camelCase）──────

/// 通用工具状态（npm / python）。
export interface EnvToolStatus {
  installed: boolean;
  version: string | null;
  path: string | null;
}

/// Node.js 状态（带兼容判定）。
export interface EnvNodeStatus extends EnvToolStatus {
  major: number | null;
  /// major >= 22（Claude Code npm 路线的门槛）
  compatible: boolean;
  /// "nvm" | "system"，仅作展示提示。
  source: string | null;
}

/// NVM for Windows 状态。
export interface EnvNvmStatus extends EnvToolStatus {
  /// NVM_HOME（各 node 版本装在 `<root>\v*`）。
  root: string | null;
}

/// 一种官方安装方式。`blocked` 非空 = 当前环境不满足前置条件：
/// "node"（未装 Node）/ "node-version"（低于 minNodeMajor）/ "python"（未装 Python）。
export interface InstallMethodInfo {
  id: string;
  needsNode: boolean;
  minNodeMajor: number;
  needsPython: boolean;
  blocked: string | null;
  /// 原样展示的官方命令。
  display: string;
  recommended: boolean;
}

/// 一个 Agent CLI 的检测状态 + 安装方式。
export interface AgentCliStatus {
  id: string;
  name: string;
  installed: boolean;
  version: string | null;
  path: string | null;
  methods: InstallMethodInfo[];
}

/// `check_environment` 的返回。
export interface EnvironmentStatus {
  node: EnvNodeStatus;
  npm: EnvToolStatus;
  nvm: EnvNvmStatus;
  python: EnvToolStatus;
  agents: AgentCliStatus[];
}

/// 可安装的 Node 版本（version 可直接作为 nvm install 参数；
/// 离线兜底为别名 "latest" / "lts"）。
export interface NodeVersionOption {
  version: string;
  major: number | null;
  lts: boolean;
  ltsName: string | null;
  recommended: boolean;
}

/// `env-setup-log` 事件载荷：一行安装日志。
export interface EnvSetupLog {
  task: string;
  line: string;
}

/// `env-setup-done` 事件载荷：一个安装任务结束。
export interface EnvSetupDone {
  task: string;
  ok: boolean;
  error: string | null;
}
