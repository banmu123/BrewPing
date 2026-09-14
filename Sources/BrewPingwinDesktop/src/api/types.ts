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
  /// 偏好是否仍指向某个已发现的 provider（换厂商后旧绑定悬空时为 false）。
  preferredStillValid?: boolean;
  /// 配置指纹（后端所读配置文件的 mtime:size）。
  ///
  /// composer 把它并进"要不要重拉模型"的依赖里 —— 用户在设置里加了厂商后，
  /// agent 没变但配置变了，靠这个值触发刷新，否则列表会停在旧值。
  configVersion?: string;
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

// ─── 模型配置（设置页；对齐 model_provider_store.rs 的 serde 契约，camelCase）──

/// 上游 API 协议族（决定转发代理的默认鉴权方式）。
export type ApiFormat = "anthropic" | "openai_chat" | "openai_responses";

/// 鉴权方式（auto = 按协议族默认；bearer / x-api-key 显式覆盖）。
export type AuthStyle = "auto" | "bearer" | "x-api-key";

/// 一条模型供应商配置（转发代理的目标上游）。
export interface ModelProviderConfig {
  /// 稳定 ID；空串 = 新建（后端生成）。
  id: string;
  /// 归属 Agent（"" = 通用：所有 Agent 可见可用；创建时锁定，编辑不可改）。
  agentId: string;
  name: string;
  /// 上游接口地址；isFullUrl=false 时为 base（转发时拼接路径）。
  baseUrl: string;
  /// 出参 = 掩码（如 "sk-••••••••abcd"），明文 Key 绝不回传前端；
  /// 入参 = 用户输入或掩码回填（后端见空串/掩码则保留旧 Key）。
  apiKey: string;
  /// 是否已配置真实 Key（仅出参有意义；提交时被后端忽略）。
  hasKey: boolean;
  apiFormat: ApiFormat;
  authStyle: AuthStyle;
  /// baseUrl 已是完整端点，转发不再拼接路径。
  isFullUrl: boolean;
  /// 默认模型（展示用，透传模式不改写请求体）。
  model: string | null;
  notes: string | null;
  createdAtMs: number;
  sortIndex: number;
}

/// 厂商性质分类（驱动下拉分组与排序；custom 恒排最后）。
export type CatalogCategory =
  | "official"
  | "cn_official"
  | "aggregator"
  | "third_party"
  | "custom";

/// 单个 agent 的端点形态 —— 同一厂商在不同 agent 下 baseURL 与协议不同
/// （对齐 cc-switch 按 app_type 分预设：/anthropic 只属于 Claude Code，
/// Codex 用 OpenAI Responses 端点，OpenCode/pi 用 OpenAI 兼容 Chat 端点）。
export interface CatalogEndpoint {
  /// agent 标识。
  agent: "claude-code" | "codex" | "opencode" | "pi";
  /// 该 agent 应使用的 base_url。
  baseUrl: string;
  /// Codex 专属：wire_api（其余为空串）。
  wireApi: string;
  /// OpenCode 专属：npm SDK 包名（其余为空串）。
  npm: string;
  /// pi 专属：api 协议值（其余为空串）。
  piApi: string;
}

/// 内置厂商目录项（纯静态预填模板，不含任何密钥）。
export interface CatalogEntry {
  id: string;
  name: string;
  /// 展示别名 / 中文名（UI 优先用它，为空回落 name）。
  displayName: string;
  /// 转发代理语义的 base_url（= Anthropic 端点，与 apiFormat 配套）；
  /// 各 CLI 表单应经 endpoints 按 agent 解析。
  baseUrl: string;
  apiFormat: ApiFormat;
  authStyle: AuthStyle;
  /// 各 agent 专属端点（custom 为空数组；旧后端可能缺省）。
  endpoints?: CatalogEndpoint[];
  models: string[];
  /// 列模型端点（OpenAI 格式；空串 = 不支持自动获取）。
  /// 转发走 Anthropic 端点（无 GET /models），列模型走 OpenAI 端点，二者地址不同。
  modelsUrl: string;
  consoleUrl: string;
  /// 官网（非推广链接）。
  websiteUrl: string;
  category: CatalogCategory;
}

/// `get_model_providers` 等命令的返回（配置 + 代理运行态）。
export interface ModelProvidersInfo {
  providers: ModelProviderConfig[];
  currentId: string | null;
  /// Agent 专属当前（key = agent id）。某 Agent 的生效厂商解析顺序：
  /// currentByAgent[agentId] → currentId（通用）→ null。
  currentByAgent: Record<string, string>;
  proxyEnabled: boolean;
  proxyPort: number;
  proxyRunning: boolean;
  /// 故障转移开关（开 = 上游失败自动按列表顺序换下一家）。
  failoverEnabled: boolean;
  /// 最近一次代理启动失败的原因（运行中为 null）。
  proxyError: string | null;
}

/// 单个 CLI 的检测/接入状态（动态列表项；后端按 ALL_KINDS 顺序下发）。
export interface CliTakeoverItem {
  /// CLI 标识（"claude_code" | "codex" | "opencode" | "pi" …，随支持面扩展）。
  id: string;
  /// 展示名（如 "Claude Code"）。
  name: string;
  /// 本机是否安装（后端 which 检测可执行文件）。
  installed: boolean;
  /// 是否支持配置接入（不支持时按钮置灰）。
  supported: boolean;
  /// true = 该 CLI 的配置当前指向本地转发代理。
  active: boolean;
  /// 配置文件绝对路径（展示用）。
  configFile: string;
  /// 配置文件是否存在。
  exists: boolean;
}

/// `get_cli_takeover` / `set_cli_takeover` 的返回。
export interface CliTakeoverInfo {
  /// 全部已知 CLI（数量随支持面扩展，顺序由后端固定）。
  items: CliTakeoverItem[];
  proxyPort: number;
}

// ─── OpenCode 厂商（写入 opencode.json）─────────────────────────────────────
// 对标 cc-switch：用户在界面添加厂商 → 后端直接写本机 opencode 配置文件。
// 数据归属 = opencode.json 唯一真相（厂商列表直接读该文件，无二次存储）。

/// 一个模型条目（opencode `provider.<id>.models.<modelId>`）。
export interface OpenCodeModelEntry {
  /// 模型 id（即 models 对象的 key）。
  id: string;
  /// 展示名（空则 opencode 回落 id）。
  name: string;
}

/// 一个 opencode 厂商的完整配置。
/// 🔴 字段名是 opencode 磁盘格式，`baseURL` / `apiKey` 的大小写不可改。
export interface OpenCodeProviderEntry {
  /// provider key（`provider` 对象的 key），形如 `my-deepseek`。
  id: string;
  /// 展示名（opencode `provider.<id>.name`）。
  name: string;
  /// npm 接口包（空则后端回落 `@ai-sdk/openai-compatible`）。
  npm: string;
  /// API 基址（opencode `options.baseURL`）。
  baseURL: string;
  /// API Key（opencode `options.apiKey`）。
  apiKey: string;
  /// 附加请求头。
  headers?: Record<string, unknown>;
  /// 模型清单。
  models: OpenCodeModelEntry[];
}

/// npm 接口包选项。
export interface NpmPackageOption {
  value: string;
  label: string;
}

/// `get_opencode_providers` 等的返回。
export interface OpenCodeProvidersInfo {
  /// 配置文件绝对路径（展示用）。
  configFile: string;
  /// 配置文件当前是否存在。
  exists: boolean;
  /// 已配置的厂商（按 id 排序）。
  providers: OpenCodeProviderEntry[];
  /// 可选 npm 接口包清单（值 + 标签）。
  npmPackages: NpmPackageOption[];
}

// ─── Claude Code 厂商（写入 ~/.claude/settings.json）────────────────────────
// 对标 cc-switch：整体覆盖 settings.json，厂商信息落在 env 段。
// Claude Code 的 settings.json 只有一份，所以这里是「当前这一份」而非列表。

/// 一个模型档位（Claude Code 的 sonnet / opus / haiku 三档映射）。
export interface ClaudeTierEntry {
  /// 档位名（`sonnet` / `opus` / `haiku`）。
  tier: string;
  /// 映射到的真实模型 id。
  model: string;
  /// 展示名（可空）。
  name: string;
}

/// Claude Code 的一份厂商配置（settings.json 的 env 段）。
export interface ClaudeProviderEntry {
  /// 展示名（仅 UI 用；settings.json 里没有厂商名字段）。
  name: string;
  /// API 基址（`env.ANTHROPIC_BASE_URL`）。
  baseURL: string;
  /// API Key（`env.ANTHROPIC_AUTH_TOKEN`）。
  apiKey: string;
  /// 三档模型映射（可空 = 不写这三组键）。
  tiers: ClaudeTierEntry[];
  /// 除 env 之外被保留的顶层键（只读，让用户知道哪些配置被一起带上了）。
  otherKeys: string[];
}

/// `get_claude_provider` 等的返回。
export interface ClaudeProvidersInfo {
  /// 配置文件绝对路径（展示用）。
  configFile: string;
  /// 配置文件当前是否存在。
  exists: boolean;
  /// 是否已配置厂商（baseURL 非空）。
  configured: boolean;
  /// 当前配置。
  provider: ClaudeProviderEntry;
}

// ─── Codex 厂商（写入 ~/.codex/config.toml）────────────────────────────────
// 对标 cc-switch：写 [model_providers.<key>]，Key 走 experimental_bearer_token，
// **不碰 auth.json**（用户 ChatGPT 登录缓存）。

/// 一个 Codex 厂商配置。
export interface CodexProviderEntry {
  /// provider key（`[model_providers.<key>]` 的表名）。
  id: string;
  /// 展示名（`name`，必填非空 —— Codex 拒载无名表）。
  name: string;
  /// API 基址（`base_url`）。
  baseURL: string;
  /// 协议（`wire_api`）：`chat` / `responses`。
  wireApi: string;
  /// API Key（写 `experimental_bearer_token`）。
  apiKey: string;
  /// 默认模型（顶层 `model`，可空）。
  model: string;
  /// 是否为当前生效的 provider。
  active: boolean;
}

/// `wire_api` 选项。
export interface WireApiOption {
  value: string;
  label: string;
}

/// `get_codex_providers` 等的返回。
export interface CodexProvidersInfo {
  /// 配置文件绝对路径（展示用）。
  configFile: string;
  /// 配置文件当前是否存在。
  exists: boolean;
  /// 当前生效的 provider key。
  activeId: string;
  /// 已配置的厂商（按 key 排序）。
  providers: CodexProviderEntry[];
  /// 可选 wire_api 清单。
  wireApis: WireApiOption[];
}

// ─── pi 厂商（写入 ~/.pi/agent/models.json）────────────────────────────────
// 对标 cc-switch：增量模式，只动 providers.<key>；Key 不可改名。
// **不碰 auth.json**（pi 自己的 /login 凭据）。

/// 一个模型条目（pi `providers.<key>.models[]` 的元素）。
export interface PiModelEntry {
  /// 模型 id。
  id: string;
  /// 展示名（可空 = 回落 id）。
  name: string;
}

/// 一个 pi 厂商配置。
export interface PiProviderEntry {
  /// provider key（`providers` 对象的 key）。**不可改名**。
  id: string;
  /// 展示名（可空）。
  name: string;
  /// API 基址（`baseUrl`，注意不是 `baseURL`）。
  baseURL: string;
  /// API Key（`apiKey`）。
  apiKey: string;
  /// 协议（`api`）：`anthropic-messages` / `openai-completions` / `openai-responses`。
  api: string;
  /// 模型清单。
  models: PiModelEntry[];
  /// 是否为当前默认 provider。
  isDefault: boolean;
}

/// `api` 选项。
export interface PiApiOption {
  value: string;
  label: string;
}

/// `get_pi_providers` 等的返回。
export interface PiProvidersInfo {
  /// models.json 绝对路径（展示用）。
  configFile: string;
  /// models.json 当前是否存在。
  exists: boolean;
  /// settings.json 绝对路径（默认项写这里）。
  settingsFile: string;
  /// 当前默认 provider。
  defaultProvider: string;
  /// 当前默认模型。
  defaultModel: string;
  /// 已配置的厂商（按 key 排序）。
  providers: PiProviderEntry[];
  /// 可选 api 清单。
  apis: PiApiOption[];
}
