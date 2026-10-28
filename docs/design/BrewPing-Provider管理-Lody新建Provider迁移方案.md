# BrewPing Provider 管理 —— 迁移 Lody「新建 Provider」实现方案

> 取证仓库：`D:\study\lody\Lody\Lody`（只读）。所有行号与结论均取自源码，非推测。
> 目标项目：BrewPing Windows 端（Tauri 2 + axum 0.8），兼顾 iOS 端消费兼容。
> 关联文档：`BrewPing-获取文件夹-Windows落地方案.md`、`BrewPing-Windows端多对话管理实现方案.md`（同目录）。

---

## 0. 一页速览

Lody 的「新建 Provider」= **设置 → Agents → 机器详情 → "Add provider" 按钮**打开的 `AgentConfigDialog`（对话框标题就叫 "New provider"，`agent-config-dialog.tsx:1839`）。它让用户为某台机器添加一个「编码 Agent 供应商配置」：选类型 → 填凭证（或粘贴预设 token）→ 真实探测 → 落盘。

它不是"新写一个 AI 客户端"，而是**配置即数据**：一个 Provider 就是一行 `AgentConfigMeta` 记录（运行时类型 + 环境变量 + 可选命令行），Agent 二进制本身已存在（builtin/registry）或由用户命令指定（custom）。会话启动时由 daemon 按 config 解析 launch 并 spawn，通过 ACP 协议通信。

对 BrewPing 的迁移，收益最大、成本最低的切片是 **Presets（env 注入模板）+ ProviderConfig 持久化 + spawn 时 env 注入**；Lody 的 CRDT/多机同步层、registry 二进制下载、providerSetup 后台装配对单机 BrewPing 均不适用。

---

## 1. Lody 侧实现原理（逐文件取证）

### 1.1 入口与 UI 结构

| 环节 | 文件 | 要点 |
|---|---|---|
| 入口按钮 | `packages/components/src/components/settings/machine-detail-pane.tsx:104-128` | `+` 图标按钮，文案键 `settings.agent.provider.addProvider`；空态时是显式 "Add provider" 按钮 |
| 事件源 | `settings/machine-agent-settings.tsx:881-884` | `openCreateDialog(machine)`：记住目标机器、置 `dialogMode={kind:'create'}`；同一组件 5 处入口（桌面/移动/列表）复用 |
| 提交接线 | `machine-agent-settings.tsx:891-942` | create → 组装 `AgentConfigMeta`（补 `machineId`）→ `createConfig` 或 `createSetup`；edit → `updateConfig` |
| 对话框本体 | `settings/agent-config-dialog.tsx`（约 2600 行） | 双栏布局：左栏类型选择（搜索 + 四组），右栏表单；窄屏降级为两步（picker → form，`:982`） |
| 第二入口 | `components/onboarding/screens/providers-screen.tsx` | 首次启动引导里选 Provider，经 `buildPresetCreateForm(presetId)`（`:680-692`）直接落到预设 token 表单 |

### 1.2 四类 Provider 选项（左栏分组，`:544-549`）

| kind | 含义 | 启动方式 | 凭证形式 |
|---|---|---|---|
| `builtin` | Kimi / Grok / Claude / Codex / DeepSeek Harness（`:453-504`） | Lody 管理的托管运行时（可被 `runtimeOverrides` 覆盖可执行路径） | 各自 CLI 登录态，或 DeepSeek 的 env |
| `preset` | 「DeepSeek over Claude Code」「GLM over Claude Code」等 5 个（`:423-429`） | **复用底层 runtime**（多为 builtin claude），仅注入 env | 粘贴一个 API token |
| `custom` | 任意 ACP 兼容命令（`:532-542`） | 用户输入的命令行，提交时 `parseCustomAcpCommandLine` 解析 | 由命令自己决定 |
| `registry` | ACP Provider 注册表（`shared/src/acp/registry-generated.ts:1015`，`REGISTRY_ACP_AGENTS`） | binary 分发，需先下载安装 | 标准认证流程 |

**Presets 是整个功能里最值得迁移的部分**。`PresetDefinition`（`:141-175`）的字段：`brandId`（驱动图标）、`cliType/agentType`（底层运行时）、`tokenEnvKey`（token 存哪个环境变量）、`fixedEnv`（固定注入的 env）、`credentialModes`（多凭证模式，按 token 前缀自动检测——`updatePresetToken` 见 `:1620-1639`，`sk-` → Pay-as-you-go、`tp-` → Token Plan，自动切换表单）。

以 DeepSeek over Claude Code 为例（`:177-205`）：底层运行时是 `builtin/claude`，用户只填一个 `ANTHROPIC_AUTH_TOKEN`，系统自动注入 `ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic` + 模型映射 + 一组 Claude Code 行为开关。提交时 `buildPresetEnv`（`:808-827`）合并：`formData.env ∪ preset.fixedEnv ∪ mode.fixedEnv ∪ {tokenEnvKey: token}`。

### 1.3 数据模型与持久化（核心设计）

**AgentConfigMeta**（`shared/src/schema.ts:120-161`）——Provider 的一等公民表示：

```ts
type AgentConfigMeta = {
  id: AgentConfigId;          // uuid，创建对话框打开时即预生成（draftConfigIdRef, :907-911）
  machineId: MachineId;       // 按机器隔离：各机器有自己的 binaries/auth/env/限流上下文
  name: string;
  cliType: 'builtin' | 'registry' | 'custom';
  agentType: AgentType;       // custom 时是 per-config 唯一 slug（custom-<uuid>）
  customAcp?: CustomAcpLaunchSpec;   // custom 的启动命令（解析后的 argv）
  runtimeOverrides?: BuiltinRuntimeOverrides;  // 高级：覆盖 builtin 可执行路径
  env: Record<string, string>;       // ★ 凭证的唯一存放处
  prompt?: string;
  titleGeneration?: TitleGenerationConfig;
  brandId?: AgentBrandId;     // preset 创建的品牌；图标渲染用，运行时不变
};
```

**存储：machine flock 文档的行族**（不是独立文件、不是云端表）：

- 每台机器一份 flock 文档，docId `<workspaceId>:mf:<machineId>`。
- 行键族（`shared/src/machine-flock.ts:245-253`）：
  - `['agentConfig', configId]` → 配置本体（权威存储）
  - `['providerSetup', configId]` → 后台装配任务（见 1.6）
  - `['providerSetupCancellation', configId]` → 收敛取消标记
  - `['builtinAgentOptOut', agentType]` → 「用户已删除该 builtin」记录
  - `['acpCapability', configId]` → 能力缓存
- 写入走 `runtime.writer.flockRowPut`（`atoms/agents.ts:44-68`），写后从本地 mirror 回读并**叠加刚写的行**形成 optimistic cache——写路径经 writer seam（本地模式下 CLI 是唯一作者，行异步回同步），读端 jotai atom 立即可见。
- **两代存储合并**：旧版配置存在 loro-repo 的 `agentConfig-<id>` 文档 meta 里；读取端 `getMergedAgentConfigMap`（`atoms/agents.ts:271-289`）按 id 合并两代，flock 为权威；CLI 侧 `readMergedAgentConfigById`（`apps/cli/src/lib/agent-config-machine-flock.ts:61-85`）同语义。**BrewPing 单机迁移可只取"flock 行"这一代概念，简化为一个 JSON 文件。**

**删除的陷阱——optOut 记录**（`atoms/agents.ts:70-90` + 注释原文）：删除是硬删、无痕，而 CLI 启动时会把 managed builtin 自动注册回来（见 1.7），它只能分辨"在不在列表"，无法分辨"从未创建"与"刚被用户删除"。所以删除 managed builtin 前**先写 optOut 行再删配置行**（顺序颠倒会退化成"删了但忘了"）；重新添加同类型 builtin 时撤回 optOut（`findBuiltinAgentOptOutToRetract`，`:62-66`）。取消 providerSetup 已发布为 config 的场景同理（`:140-148`）。

### 1.4 能力探测（创建门禁 + 缓存）

对话框的核心状态机是"**就绪门禁**"：不同类型有不同的就绪判定（`agent-config-dialog.tsx:1206-1226`）。

- **builtin 创建必须真实探测**。注释原文（`:938-941`）："Creation of a built-in provider is gated on a live probe for the exact target machine + auth-affecting form revision. Cached capabilities make the form renderable, but they do not prove that credentials still exist." 点「创建」→ 触发 `probeTick+1` → effect 发起 RPC `machine/acp-capabilities-refresh`（`shared/src/message.ts:312-354`）→ 成功才放行落盘。
- **custom 必须手动 Test 精确命令**：就绪条件是 `testedCustomKey === customAcpKey`（`:1211`），`customAcpKey` 是解析后 argv 的规范化字符串——**改了命令（哪怕只是空格差异以外的内容）就绪即失效**；只有空格级编辑不重探（`:1092-1094`）。编辑已有 custom 且缓存 `sourceVersion` 与保存命令一致时可预置已测状态，改名不用重测（`resolveInitialTestedCustomKey`，`:874-887`）。
- **探测响应三分支**（`:1360-1376`）：`authRequired` → 弹认证面板（builtin 编辑态或 custom/registry 的协议认证）；`!success` → 探测错误；成功 → 置 `manuallyTested` / `verifiedBuiltinContext`。
- **能力缓存**（`shared/src/ai.ts:347-396`）：`AcpCapabilityCacheEntry`（modes/models/configOptions/modelReasoningEfforts/availableCommands/fork…），`cacheVersion` 当前 8（不匹配即视为过期），`provenance: 'runtime'` 才是权威；`getAcpCapabilityCacheKey(configId) = configId`——**缓存按 configId 隔离**，同一 Provider 的多个配置互不污染。CLI 侧契约：refresh 永远是真实 runtime probe；**中止的探测不得更新缓存**；探测到的 runtime 版本参与缓存键（`apps/cli/src/agent/AGENTS.md:102-107`）。

### 1.5 运行时二进制管理（builtin 托管 / registry 下载）

- 状态机：`not-applicable | unsupported-platform | incompatible-host | not-installed | installed` + 进行中态 `checking/downloading/verifying/extracting/publishing`（`agent-config-dialog.tsx:604-613`）。
- RPC：`machine/acp-binary-status`（检查，Kimi 顺带回 Node current/required 版本，不满足报 `incompatible-host`）、`machine/acp-binary-install`（下载+解包，拒绝即失败）、`machine/acp-binary-progress`（进度事件，经 `useMachineAcpBinaryProgress` 订阅实时刷新）（`message.ts:500-562`）。
- **状态必须绑定 agentType**（`:951-957` 注释原文）：裸 status 状态在从非 binary Provider 切到另一个 binary-only Provider 时，会在 per-agent 检查跑完前"瞬间读作就绪"，从而**绕过显式下载确认直接触发探测（含隐式 ensureBinary 下载）**。派生时强制 `agentType` 不匹配 → `'unknown'`。
- 托管 builtin（Kimi/Claude/Codex）走 `usesDefaultManagedRuntime`（无 override 时），版本 pin 来自 `codex-runtime-manifest.json` / `claude-runtime-manifest.json`，拒绝依赖/清单版本不匹配，绝不热替换运行中的 ACP 进程（`apps/cli/src/agent/AGENTS.md:60-67`）。

### 1.6 providerSetup：后台装配（durable intent）

创建托管 builtin 且目标机器支持 `providerSetup` 协议（`machineSupportsProviderSetupProtocol(machine)`，`:1135-1138`）时，提交改为**先落一个任务行、不等探测完成**：

```ts
// shared/src/machine-flock.ts:194-204 —— 注释原文要点：
// 最终 AgentConfig 嵌在任务里，探测成功前对会话创建不可见；
// 授权 URL/码/token 绝不能写进这一行。
type ProviderSetupTask = {
  v: 1; id; machineId; config: AgentConfigMeta;
  status;               // queued → running → published/failed(带 failureCode)
  attempt; createdAt; updatedAt; failureCode?;
};
```

- CLI 端 `apps/cli/src/lib/provider-setup-manager.ts` 消费任务行，后台完成下载+探测后**才把 config 发布为 `agentConfig` 行**。
- 取消是**收敛取消标记**（`ProviderSetupCancellation`，`machine-flock.ts:212-217`）：标记行是取消的接受边界；目标机器即使并发发布了 config，也能凭标记在同步后因果删除（`atoms/agents.ts:106-157`）。
- 单机 BrewPing **不需要这一层**（同机装配本来就是即时的），但"探测成功前配置对外不可见"的语义值得保留。

### 1.7 CLI 消费侧：配置如何变成会话

- **启动自动注册**（`apps/cli/src/lib/lody.ts:210-251`）：等 meta 初始同步完成（未完成则监听 `onMetaRoomSynced` / `waitForInitialMetaSync`，且去重保证只跑一次，`:156-195`）→ 读 optOut 集合 → 对每个 builtin 类型 `hasAgentConfig` 幂等检查 → 缺失才 `createAgentConfig`；失败走指数退避重试（`2 ** min(attempt,5)`，`:288-290`）。
- **launch 冻结红线**（`apps/cli/src/agent/AGENTS.md:96-98`）："Machine RPC may name only a persisted Provider `configId`; the daemon freezes machine/CLI/agent/launch/env/runtime fields before spawning, capability refresh included"——**RPC 只能引用已持久化的 configId，daemon 在 spawn 前冻结全部 launch 字段，后续回复不能替换启动目标**。
- 会话启动：`acp-runner.ts` spawn + initialize + `newSession`，经 `acp-session-start-gate.ts` 并发门（默认 2）。env（含凭证）从 `AgentConfigMeta.env` 注入子进程；认证数据绝不进日志/聊天/flock/config。
- preset 的标题生成兜底：preset 跳过能力探测路径，`titleGeneration` 若不补默认值会在首次对话撞"title generation not configured"门禁——所以提交时用 `buildPresetTitleGeneration`（`:836-849`，注释原文）直接填 builtin 静态默认值，**赶在 CLI 能力回填之前就能用**。

### 1.8 安全红线（代码注释明文）

1. 凭证只存 `AgentConfigMeta.env`（随 CRDT 本地同步），**授权 URL/码/token 绝不进日志、聊天、flock 其他行、进度**（`provider-setup-manager` 契约 + `AGENTS.md:84-85`）。
2. 认证交互中表单字段有类型/大小/数量边界，受共享字节预算约束（`AGENTS.md:94-95`）。
3. 编辑态品牌保留：`resolvedBrandId = activePreset?.brandId ?? mode.config.brandId`（`:1029-1030`）——无关编辑不得剥掉已持久化品牌。

---

## 2. BrewPing 现状（取证）

| 事实 | 位置 | 影响 |
|---|---|---|
| Agent 是**静态目录**，4 项（opencode/claude-code/codex/aider），`discover()` 逐个定位可执行文件 + 取版本 | `agent_discovery.rs:56-86` | 没有"添加 Provider"的概念；用户无法接入新供应商 |
| 模型/Provider 偏好是 per-agent 的 `defaultModels/defaultProviders` 两个 map，只记 id，spawn 时拼命令行参数 | `model_prefs.rs:16-33`（文档注释明言"只读那些文件，不改 Agent 配置"） | 与 Lody 的"配置即数据"相反：BrewPing 现在是"发现即事实" |
| spawn 两处 `Command::new` 均无 `.current_dir()`（已在目录浏览方案中标记，workdir 已落地） | `http_server.rs:687` / `lib.rs:464`（落地后行号可能有漂移） | env 注入与 current_dir 是**同一批改动点** |
| 持久化骨架成熟：`with_path` 测试隔离、`#[serde(default)]`、损坏容忍、锁外写盘 | `workdir_prefs.rs` / `model_prefs.rs` | 新 ProviderConfig 存储直接照抄 |
| iOS 端消费 `/api/agents`（`AgentEntryApi`），新字段需 Optional | `agent_discovery.rs:26-53` | 扩展 API 必须向后兼容 |
| opencode 是 stub，从不 spawn 进程 | `http_server.rs:620` / `lib.rs:382`（多对话方案已标记） | env 注入仅对真正 spawn 的 agent 生效 |

---

## 3. 迁移方案（BrewPing Windows 端）

### 3.1 目标形态

在现有"发现式 Agent"之上增加**ProviderConfig 层**：用户可以「新建 Provider」——从预设选一个（如 GLM over Claude Code）、粘 token，之后该 Provider 以独立条目出现在 Agent 列表里，spawn 时注入对应 env。保持与 Lody 一致的语义：**Provider = 数据（配置行），Agent 二进制 = 运行时**。

### 3.2 数据模型（对齐 Lody `AgentConfigMeta`，裁剪到单机）

新增 `src-tauri/src/services/provider_store.rs`，落盘 `~/.brewping/providers.json`（照 `model_prefs.rs` 模式）：

```rust
#[derive(Serialize, Deserialize, Clone)]
pub struct ProviderConfig {
    pub id: String,            // uuid v4
    pub name: String,          // 默认取 preset.label，用户可改
    pub cli_type: String,      // "builtin"（BrewPing 只有这一档；custom 可选做）
    pub agent_type: String,    // 底层运行时："claude-code" | "codex" | "aider"（对齐 CATALOG id）
    pub env: HashMap<String, String>,   // ★ 凭证 + 固定注入，唯一存放处
    pub brand_id: Option<String>,       // 图标/品牌：deepseek/glm/minimax/mimo
    pub created_at: u64,
}
// Stored { providers: Vec<ProviderConfig>, ignored: Vec<String> }  ← ignored 即 optOut
```

裁剪说明：`machineId`（单机）、`customAcp`（暂不做 custom 命令）、`runtimeOverrides`（BrewPing 不托管运行时）、`titleGeneration`（无标题生成）、两代存储合并（单代）全部去掉；**`ignored`（optOut）必须保留**——BrewPing 的 discovery 是每次启动重跑的，语义上等价于 Lody 的"启动自动注册"，没有 ignored 记录，用户"隐藏"的 agent 下次启动又会回来（对应 `lody.ts:224-239` 的注释原文逻辑）。

### 3.3 Presets 表（直接照搬，收益最大）

新增 `src-tauri/src/services/provider_presets.rs`，把 Lody 的 5 个预设翻译成 Rust 常量表（值取自 `agent-config-dialog.tsx:177-429`，可直接使用）：

```rust
pub struct ProviderPreset {
    pub id: &'static str,          // "glm-over-claude-code"
    pub brand_id: &'static str,
    pub label: &'static str,       // "GLM over Claude Code"
    pub description: &'static str,
    pub agent_type: &'static str,  // "claude-code" → spawn `claude`
    pub token_env_key: &'static str,           // "ANTHROPIC_AUTH_TOKEN"
    pub token_placeholder: &'static str,
    pub fixed_env: &'static [(&'static str, &'static str)],
    pub credential_modes: &'static [CredentialMode],  // GLM/MiMo 有多端点
}
pub struct CredentialMode {
    pub id: &'static str,          // "bigmodel" | "zai"
    pub label: &'static str,
    pub token_prefix: &'static str, // 可选：按前缀自动检测模式（Lody :1620-1639）
    pub fixed_env: &'static [(&'static str, &'static str)],
}
```

示例——GLM 预设（Lody `:359-421`）：共享 env `{ ANTHROPIC_DEFAULT_HAIKU_MODEL: "glm-4.7", ANTHROPIC_DEFAULT_SONNET_MODEL: "glm-5.2[1m]", ANTHROPIC_DEFAULT_OPUS_MODEL: "glm-5.2[1m]", CLAUDE_CODE_AUTO_COMPACT_WINDOW: "1000000", CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1", API_TIMEOUT_MS: "3000000" }`，bigmodel 模式加 `ANTHROPIC_BASE_URL: "https://open.bigmodel.cn/api/anthropic"`，zai 模式加 `https://api.z.ai/api/anthropic`。

提交时合并规则对齐 `buildPresetEnv`（Lody `:808-827`）：`用户额外 env ∪ preset.fixed_env ∪ mode.fixed_env ∪ {token_env_key: token}`。

### 3.4 HTTP API（新增 4 端点，全部落在 `auth_middleware` 保护内；读用 GET 自动免 nonce）

| 方法 | 路径 | 语义 |
|---|---|---|
| `GET` | `/api/providers` | 列出全部 ProviderConfig + 内置预设目录（供 UI 渲染类型列表） |
| `POST` | `/api/providers` | 新建：`{presetId, token, name?}` 或裸 `{name, agentType, env}`；服务端做 env 合并 + 校验（token 非空、baseUrl 是合法 http/https——对齐 Lody `disableReason` 门禁 `:1676-1749`） |
| `DELETE` | `/api/providers/{id}` | 删除；若删除的是"发现型 agent 的唯一配置"则记录进 `ignored` |
| `POST` | `/api/providers/{id}/test` | 能力探测：对该 provider 的 agentType 跑一次 `discover_one`（定位+版本），成功返回 `{ok, version}`，失败返回 `{ok:false, error}`。**不做真实 LLM 调用**（Lody 的 live probe 对 BrewPing 过重；版本存在 + env 非空已是单机合理门禁） |

`/api/agents` 响应扩展：每个条目新增 `provider_id: Option<String>`、`env_injected: bool`（Optional 解码，iOS 兼容）。

### 3.5 spawn 注入（与 workdir 同点，必须一起改）

两处 `Command::new`（`http_server.rs` 的手机端路径 + `lib.rs` 的桌面输入框路径）：

```rust
let mut cmd = Command::new(&agent.executable);
cmd.args(&args)
   .current_dir(workdir)                    // 目录浏览方案已加
   .envs(&provider.env);                    // ← 本次新增
```

会话/命令需携带 `provider_id`（或沿用多对话方案的 `conversation.provider_id`）：解析顺序对齐 Lody 的 launch 解析——显式指定 → 会话归属对话的绑定 → 默认 provider。**daemon 侧不缓存 spawn 参数**：每次 spawn 从 ProviderStore 现读（单机无并发风险，锁内取快照）。

### 3.6 UI（Windows 前端 + iOS）

**Windows（`src/`）**：
- 设置/侧栏新增「Provider」入口 + 「新建 Provider」对话框。布局照 Lody 双栏（左类型/右表单）或简化为单步向导（预设卡片区 → token 表单）；预设卡片显示品牌、描述、token 获取帮助链接（Lody `helpUrl` 字段）。
- credentialModes 用 Radio/Select 呈现；支持按 token 前缀自动切换（`sk-` / `tp-`）。
- 「测试」按钮 → `POST /test` → 成功显示版本号，失败显示 error；**测试通过才允许保存**（对齐 Lody 创建门禁，简化版）。

**iOS**：
- 新增 `ProviderStore.swift` + 设置页入口（列表 + 新建表单），走 `BrewPingHTTP.request`（新字段 Codable 全 Optional）。
- Demo 模式（`DemoBackend.swift`）同步加 4 端点的假实现，预设目录用真数据（无网络请求），保证 Demo Mode 不 404。
- Agent 列表里 Provider 条目带品牌图标（SF Symbol + 品牌色即可，不需要 Lody 的 AgentIcon 资产体系）。

### 3.7 不迁移清单（如实说明）

| Lody 能力 | 不迁移理由 |
|---|---|
| machine flock / CRDT 同步 | BrewPing 单机单用户；JSON 文件即权威 |
| registry ACP Provider + 二进制下载/校验/断点续传 | BrewPing 不托管运行时，agent 由用户预装 |
| providerSetup 后台装配 + 收敛取消 | 同机装配即时，无跨机延迟问题 |
| ACP 协议认证（浏览器 OAuth、表单 elicitation） | BrewPing 直接 spawn CLI，凭证走 env；LLM 供应商预设全是 env 型 |
| AcpCapabilityCacheEntry 版本化缓存 | 探测简化为 discover_one，每次现查，无缓存失效问题 |
| custom ACP 命令行 | 可选二期；如做，命令解析（引号）与"改命令必须重测"两条规则照搬 |
| 托管运行时版本 pin / manifest | 不适用 |

### 3.8 实施顺序

| 阶段 | 内容 | 验收 |
|---|---|---|
| P1 | `provider_store.rs` + `provider_presets.rs`（模型/预设/持久化/单测，照 `workdir_prefs` 测试模式） | `TC-PS-01..06` |
| P2 | 4 个 HTTP 端点 + spawn env 注入（两处同批改） | `TC-PA-01..08` |
| P3 | Windows 前端对话框 + Agent 列表融合 | `TC-PU-01..06` |
| P4 | iOS ProviderStore + 设置页 + Demo 同步 | `TC-PI-01..05` |

### 3.9 验收用例（关键项）

1. **TC-PA-03** GLM 预设新建 → 读 `providers.json` 断言 env 含 6 个共享键 + `ANTHROPIC_BASE_URL=bigmodel` + token；UI 切 zai 模式重建 → baseUrl 变 z.ai（对齐 Lody `credentialModes`）。
2. **TC-PA-05** 无 token 提交 → 400 JSON 错误体（遵守 `TC-HT-26` 契约），文案含 preset 名。
3. **TC-PA-07** 用 Provider 发命令 → `cmd /c set`（Windows）断言子进程环境含 `ANTHROPIC_BASE_URL`（机制单测思路同 cwd 探针）。
4. **TC-PA-08** 删除发现型 agent 的 Provider → `ignored` 含其 id → 重启服务 → `/api/agents` 不再出现 → UI 里点"取消忽略" → 重启后恢复（optOut 语义）。
5. **TC-PU-02** 粘 `sk-` 前缀 token（MiMo 预设）→ 凭证模式自动切到 Pay-as-you-go，baseUrl 字段消失。
6. **TC-PI-03** 旧版 iOS（无 Provider 代码）对新服务端 `/api/agents` 解码不失败（新字段 Optional）。
7. **TC-SEC-01** `/api/providers` 响应、日志、命令转录（多对话方案的 conversation JSON）中**不得出现 token 明文**——日志打印 env 时必须脱敏 `token_env_key`。

### 3.10 迁移时必须带走的四条 Lody 规则

1. **凭证只在 ProviderConfig.env 一处**；日志/转录/进度一律脱敏（Lody `AGENTS.md:84-85` 红线）。
2. **删除要有 optOut 记录**，顺序"先记后删"，重加同类型撤回（Lody `atoms/agents.ts:70-90`）。
3. **改了影响凭证的表单字段，就绪状态作废、必须重测**（Lody `invalidateBuiltinVerification`，`:1518-1526`；custom 的 `testedCustomKey === customAcpKey` 精确匹配）。
4. **二进制/探测状态绑定到具体 agentType**，切换类型时归 `'unknown'` 而非沿用上一态（Lody `:951-957` 防串台注释）。

---

## 附录 A：关键文件索引（Lody 取证）

| 文件 | 角色 |
|---|---|
| `packages/components/src/components/settings/agent-config-dialog.tsx` | 对话框本体（预设表、四类选项、就绪门禁、探测流程） |
| `packages/components/src/components/settings/machine-agent-settings.tsx` | 入口与提交接线（create/edit → atom） |
| `packages/components/src/components/settings/machine-detail-pane.tsx` | "Add provider" 按钮 |
| `packages/components/src/components/onboarding/screens/providers-screen.tsx` | 首启引导的第二入口 |
| `packages/components/src/atoms/agents.ts` | 写入/删除/optOut/setup 全部 flock 行操作 + 派生 atom |
| `packages/shared/src/schema.ts:120-161` | `AgentConfigMeta` |
| `packages/shared/src/machine-flock.ts:186-253` | ProviderSetupTask / Cancellation / BuiltinAgentOptOut / 行键族 |
| `packages/shared/src/message.ts:300-562` | 4 个 Machine RPC 契约 |
| `packages/shared/src/ai.ts:340-396` | AcpCapabilityCacheEntry + cacheVersion |
| `packages/shared/src/acp/registry-generated.ts` | REGISTRY_ACP_AGENTS |
| `apps/cli/src/lib/agent-config-machine-flock.ts` | CLI 侧读取/合并/两代存储 |
| `apps/cli/src/lib/lody.ts:150-290` | 启动自动注册（meta sync 等待 + optOut + 幂等 + 退避重试） |
| `apps/cli/src/lib/provider-setup-manager.ts` | 后台装配消费端 |
| `apps/cli/src/agent/AGENTS.md` | launch 冻结、认证、能力缓存等红线原文 |

## 附录 B：BrewPing 改动文件

| 文件 | 改动 |
|---|---|
| `src-tauri/src/services/provider_store.rs` | 新增（模型 + 持久化 + ignored） |
| `src-tauri/src/services/provider_presets.rs` | 新增（预设表，值照搬 Lody） |
| `src-tauri/src/services/mod.rs` | 注册模块 |
| `src-tauri/src/services/http_server.rs` | 4 端点 + spawn `.envs()` |
| `src-tauri/src/lib.rs` | spawn `.envs()` + Tauri command 桥 |
| `src/api/types.ts` / `src/api/tauri.ts` | Provider 类型 + 封装 |
| `src/components/settings/`（或新目录） | 新建 Provider 对话框 |
| `ios/BrewPing/ProviderStore.swift` 等 | 新增（P4） |
