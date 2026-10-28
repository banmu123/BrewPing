# BrewPing Windows 端「多对话管理」实现方案

> 依据：`Sources/BrewPingwinDesktop` 现有代码取证（2026-09-11）+ Lody 仓库（`D:/study/lody/Lody/Lody`）多会话管理实现梳理，约定遵循 `.workbuddy/memory/MEMORY.md`。
> 口径与《BrewPing-获取文件夹-Windows落地方案》《BrewPing-iOS端结构与模块划分》保持一致。
> **目标**：在 Windows 桌面端实现多对话（多会话）的创建、切换、保存与删除，**实现方式与 Lody 的多会话管理保持同一设计思路**，且不破坏现有 iOS 客户端与桌面 UI 的任何已实现功能。

---

## 0 一页速览

| 维度 | 现状 | 目标 | Lody 对应设计（§1 详述） |
|---|---|---|---|
| 会话模型 | 全局单例 `state.session: Option<SessionInfo>`，一次一个；**切换 Agent 即杀会话**（TC-HT-07） | 多对话并存，`active_conversation_id` 指向当前对话；切换 Agent 不再杀会话 | 会话即文档，`SessionMeta` 全量并存于 meta cache，无全局单例 |
| 命令归属 | `CommandStore` 只按 `cmd_id` 存，与会话无关联（轮询响应 `sessionId` 恒为 `"unknown"`） | 每条命令挂 `conversation_id`，轮询响应回填真实 sessionId | 每条 history entry 归属 session doc；调度靠 `latestUserMsgId` 指针 |
| 对话内容 | `ChatView` 从终端行**推导**消息，不持久化 | 对话转录成为权威数据源，落盘 `~/.brewping/conversations/` | 转录在 session doc 的 history，元数据在 doc meta，两层分离 |
| 持久化 | 无（重启全丢） | 逐对话文件 + 索引文件，复用 `WorkdirPrefs` 的容错模式 | meta cache 即列表数据源；逐会话文档按需打开 |
| 渲染 | `chat-view.tsx` + `markdown-renderer.tsx` + `shiki-theme.ts`（Lody 渲染栈已迁移 ✅） | 原样复用，数据源从终端行换成 transcript | 同一套 Streamdown/Shiki 渲染栈 |
| 创建语义 | `handle_start_session` 直接覆盖旧值 | **草稿模式**：新建不落盘，首条消息发送时才物化对话 | `createSession` 只写 meta 不 spawn；landing 用预保留 draft id |
| 状态所有权 | 无约束（任何路径都能改） | 只有命令执行者能写 `completed/failed` | `running → idle` 只许 CLI 驱动，Web 写入被忽略 |

**四个核心操作的一句话设计**（对齐 Lody 语义）：
- **创建** = 草稿（仅前端持有 id）；首条消息到达时原子写入 `ConversationMeta`（索引行）+ 首条转录条目——对应 Lody `startSession` 把 meta 与首条 user turn 作为一个接受单元；
- **切换** = 改 `active_conversation_id`（原子），前端换数据源重渲染；不触碰 defaultAgent——对应 Lody 打开会话只是路由切换，会话数据本身不动；
- **保存** = 每次消息追加立即落盘，`updated_at_ms` **只增不减**——对应 Lody `buildSessionActivityPatch` 的单调性守卫；
- **删除** = 删转录文件 + 索引行；删 active 时同步清 active 会话状态（不自动跳转）——对应 Lody 关闭最后一个 tab 回 landing。

---

## 1 Lody 多对话管理核心实现梳理（借鉴源）

> 本节全部结论取自 Lody 源码逐文件阅读，标注了文件与行号，供实现者回查。

### 1.1 总体架构：会话即文档，元数据与转录两层分离

Lody 的每个会话是一个独立的 Loro 文档（roomId = `session-<id>`），状态分两层：

| 层 | 载体 | 内容 | 列表页是否读取 |
|---|---|---|---|
| **元数据层** | 文档 meta（`SessionMeta`，`packages/shared/src/schema.ts:800-943`） | id、machineId、title/titleSource、status、isArchived、isPinned、lastMessageAt/lastReadAt、parentSessionId、调度指针等 ~40 字段 | ✅ **列表只读这一层** |
| **转录层** | 会话文档 body 的 `history` 条目数组 | 逐条 turn（id、role、items、inputConfig、status） | ❌ 打开会话才加载 |

**关键决策：列表页从不打开会话文档**。`sessionMetaCacheAtom`（`packages/components/src/atoms/doc-meta.ts:207`）缓存全部会话 meta，三个列表 atom（`sessionListAtom:271` / `archivedSessionListAtom:294` / `allActiveSessionsAtom:316`）都是对这个 cache 的纯过滤派生：

```ts
// sessionListAtom：活跃会话 = 未归档 且 非子会话
(session) => !session.isArchived && !session.parentSessionId
```

派生 atom 全部做了**结构相等稳定化**：内容没变就返回上一次的数组引用（`doc-meta.ts:278-289` 有完整注释），防止任何无关 meta 更新触发整个列表重渲染。

**映射到 BrewPing**：索引 `index.json`（ConversationSummary 列表）= 元数据层；`conv_<id>.json`（含 messages）= 转录层。列表 API 只读索引，打开对话才读转录文件。前端 `conversation-list.tsx` 同样要做结构相等稳定化（对话列表按 updated_at 排序，任何一条消息追加都会变——不 stabilization 会导致整个侧栏每次回复都重渲染）。

### 1.2 调度指针：谁还欠一次执行，靠指针而不是靠猜

`SessionMeta` 里有一组「调度指针」字段（`schema.ts:866-888`），这是 Lody 多会话下最精妙的设计：

| 字段 | 所有者 | 语义 |
|---|---|---|
| `latestUserMsgId` | 生产者（App 侧） | 最新一条已发布的用户 turn |
| `lastHandledUserMsgId` | 机器（CLI 侧） | 机器已完整处理的最后一条 |
| `processingUserMsgId` | 机器 | 正在处理的一条 |
| `lastMissingHistoryUserMsgId` | 机器 | 永久负回执：payload 没同步到的激活 |
| `settledActivationUserMsgId` | 机器 | 退休回执：turn 已终态、只有指针过期 |

所有「这个会话还有没有欠着的 turn？」的消费者（dispatch、GC、状态页）**必须**走唯一收敛函数 `getPendingUserTurnActivationId`（`schema.ts:957-978`），否则和 watcher 各算各的会互相挂死。注释原文：*"Every consumer that asks 'does this session still owe a turn?' must go through here, or they disagree with the watcher and hang."*

配套原则（`use-session-actions.ts:496-505`）：**RPC 快路径只是加速，持久指针写入才是恢复真相**（"The RPC only accelerates dispatch — the durable `latestUserMsgId` pointer write remains recovery truth"）。

**映射到 BrewPing**：单机单用户不需要五个指针，但**「对话当前欠着哪条命令」这一个指针值得要**：`Conversation.latest_command_id`。用途：① `ChatView` 的 `isStreaming` = 该对话 `latest_command_id` 在 CommandStore 里处于 queued/working；② 命令完成时执行者写回 `last_handled_command_id`（等价语义），指针差即「有在跑的事」。重启后 CommandStore 清空 → 指针悬空 → 启动清理时给转录补一条 `system` 条目「上次执行被中断」，对应 Lody「指针是恢复真相」的思想。

### 1.3 状态机所有权：谁能写什么状态，是有边界的

`updateSessionStatus`（`use-session-actions.ts:792-818`）里有一条硬守卫：

```ts
if (prevStatus?.type === 'running' && status.type === 'idle') {
  // Web should not drive running -> idle; only CLI owns that transition.
  return;
}
```

状态取值（`schema.ts:100-108`）：`idle` / `running`（心跳驱动）/ `requestPermission` / `initializing`。另一条相关注释在 CLI 侧（`apps/cli/src/session/session-manager.ts:2272`）：*"Errors are turn-level, not session-level. Set session to idle."* ——错误不改变会话生命周期，只落在具体 turn 上。

**映射到 BrewPing**：两条铁律。① `ConversationStore` 里命令状态 `completed/failed` **只能由 `command_runner`（执行者上下文）写入**，HTTP 层和 UI 事件路径一律无权改；② 错误是转录条目（`role:"error"`）而不是对话状态——对话不因一次失败进入「失败态」，与现有 CommandStore 语义天然一致。

### 1.4 生命周期操作：创建 / 启动 / 归档 / 恢复 / 删除

全部实现在 `packages/components/src/hooks/use-session-actions.ts`（1500 行，是 Lody 会话生命周期的唯一收口）：

**创建（createSession:622-651）**：只写 meta + 预热文档流，**不 spawn 任何进程**。进程在第一次 dispatch 时才由 CLI 侧拉起。配额检查 `assertSessionCreateAllowed` **失败开放**（fail open）：本地状态不完整就放行（`:629-631` 注释："Incomplete local state fails open so session creation never depends on ... availability"）。

**启动（startSession:653-710）** = 创建 + 首条 user turn 的**原子接受单元**。注释原文（`:662-666`）：*"The accept unit includes the first user message, so the meta it publishes already carries that activity. Written here, not by a follow-up touch: a close between acceptance and the first turn must never make the session look empty (**empty tabs are deleted, not archived**)."*

**草稿会话**（`use-chat-landing-draft-session.ts`）：新对话界面只持有**预保留的 draft id**（module-level atom，附件可以先挂在 id 上），首条消息发送时才物化为真会话。这就是「空会话」从根上不存在的机制。

**归档（archiveSession:1239-1309）**：
- 级联到子会话（`getArchiveStateTargets` = 根 + 直接子会话）；
- 逐个关终端（`terminal.closeSession`）、写 `isArchived: true` + status 重置为 idle；
- 向机器队列投归档命令行（machine flock row，**best-effort**，失败只记日志不阻塞 `:280-291`）。

**恢复（restoreSession:1311-1351）**：恢复前**校验执行前提还在**——本地项目会话若项目已被移除，抛专门的 `ArchivedLocalProjectRestoreUnavailableError`（`:218-223`，错误文案就是用户动作指引："Re-add this local project to restore its conversations."）。

**删除（deleteArchivedSession:1436-1465）**：目标 = 根 + 直接子会话，**逆序（先子后根）**执行；每个目标先向机器投删除命令（清理 worktree），再删文档 + 释放会话 store。归档/删除是**两段式**：必须先归档才能删除，活跃会话没有直接删除路径。

**置顶（setSessionPinned:1467-1480）**：单个布尔字段 `isPinned`，一次 meta patch，无任何级联。

**重命名（updateSessionTitle:1059-1077）**：写 `title` + `titleSource: 'user'`——**来源字段**保证手动命名不被自动生成覆盖。

**已读/未读（markSessionRead/Unread:1104-1141）**：未读是持久比较式 `lastMessageAt > lastReadAt`；标记未读 = `lastReadAt = lastMessageAt - 1`（`:1136-1138`），只动回执不动活动时间戳（"do not touch the activity timestamp, which would reorder the sidebar"）。

**活动时间戳单调性**（`buildSessionActivityPatch:451-469`）：`lastMessageAt`/`lastReadAt` **只在提议值更大时写入**——乱序到达的事件不能把列表排序拉回去。

### 1.5 列表排序：置顶优先，然后最新活动

`session-opened-by-tree.ts:94-99`：

```ts
const PINNED_ROOT_RANK_OFFSET = 1e15;
export function pinnedFirstRootRank(latestMessageAtMs, isPinned) {
  return isPinned ? PINNED_ROOT_RANK_OFFSET + latestMessageAtMs : latestMessageAtMs;
}
```

一个数值偏移量同时表达两个排序维度（置顶 > 未置顶，各自内部按 `lastMessageAt` 降序），注释明确 "Above every real epoch-ms timestamp"。侧栏分组内每组合 `MAX_VISIBLE_SESSIONS = 5` 条预览（`session-list.tsx:234`），超出折叠。

### 1.6 多 tab 与关闭语义

- 同一会话下的子对话以 tab 呈现（`parentSessionId` + `childSessionPlacement: 'side-panel'` 区分 tab / 侧栏面板两种挂载，`schema.ts:896-903`；子会话 atom family 按创建时间升序，`doc-meta.ts:352-359`）；
- **关闭目标函数**（`session-tab-close-target.ts:8-33`）把「关的是哪个」收敛成三种：关侧栏 tab / 关当前会话 tab / 回 landing（最后一个会话 tab 关闭时）；每个分支独立可测；
- 归档后的子会话不消失，进「归档 popover」（`archivedChildSessionsAtomFamily`）。

**映射到 BrewPing**：BrewPing 无子对话，取其精神——**关闭/删除最后一个对话回到 landing 态（无 active），且这个「回哪去」要写成独立纯函数**，不要散在事件处理器里。

### 1.7 对 BrewPing 明确不适用的部分（如实声明）

| Lody 设计 | 不采纳原因 |
|---|---|
| 子会话 / tab 级联归档删除 | 单机单用户无嵌套对话，级联只会增加状态空间 |
| 五指针调度（§1.2） | 无跨设备竞态，单指针够用 |
| 配额检查 / 转移所有者 / 团队可见性过滤 | 无多用户、无计费 |
| CRDT 文档 + Streams RPC | 单机 JSON 文件即可（MEMORY.md 既有决策） |
| title 自动生成走 ACP 会话 | agent 输出即整段文本，直接截前 32 字符 |

---

## 2 设计对齐总表：Lody 概念 → BrewPing 落地

| # | Lody 概念 | BrewPing 落地 | 取舍 |
|---|---|---|---|
| A1 | 元数据/转录两层，列表只读 meta | `index.json`（summary）/ `conv_<id>.json`（transcript） | ✅ 全量采纳 |
| A2 | `startSession` = meta + 首条 turn 原子 | 草稿模式：首条消息发送时创建对话并写首条条目（一个函数内完成） | ✅ 采纳 |
| A3 | draft id 预保留，空会话不存在 | 桌面「新对话」只置前端 draft 态，不调 API | ✅ 采纳 |
| A4 | 调度指针 = 恢复真相 | `Conversation.latest_command_id` + 重启中断补条 | ✅ 采纳（单指针版） |
| A5 | `running→idle` 只有 CLI 能写 | `completed/failed` 只有 command_runner 能写 | ✅ 采纳 |
| A6 | 错误是 turn 级 | `role:"error"` 转录条目，对话无失败态 | ✅ 采纳 |
| A7 | 归档/删除两段式 | `archived: true` 是删除前置态 | ✅ 采纳 |
| A8 | 恢复前校验执行前提 | 恢复时校验 `workdir_override` 目录仍存在 | ✅ 采纳 |
| A9 | title/titleSource，manual 不被覆盖 | `title_source: "auto"\|"manual"` | ✅ 采纳 |
| A10 | pinned first（1e15 偏移）+ 最新活动 | `is_pinned` 字段 + 同一排序公式 | ✅ 采纳 |
| A11 | 活动时间戳只增不减 | `updated_at_ms` 单调写入 | ✅ 采纳 |
| A12 | 列表派生 atom 结构相等稳定化 | `conversation-list` useMemo + 逐条比较 | ✅ 采纳 |
| A13 | 关最后 tab 回 landing 的纯函数 | 删 active → `active = None`（landing 态） | ✅ 已在原方案 |
| A14 | 未读 = `lastMessageAt > lastReadAt` | 二期 iOS 列表徽标时再加 | ⏸ 缓 |
| A15 | 子会话/五指针/配额/CRDT | — | ❌ 不适用（§1.7） |

---

## 3 现状取证（BrewPing 多对话的差距在哪）

### 3.1 已有的对话能力（可直接复用的部分）

| 模块 | 位置 | 现状 | 复用判定 |
|---|---|---|---|
| `CommandStore` | `http_server.rs:56-129` | `HashMap<cmd_id, CommandEntry>`，状态机 `queued→working→completed/failed`，4 条单测（TC-CS-01..04） | ✅ 扩展：`CommandEntry` 加 `conversation_id` |
| `SessionInfo` | `http_server.rs:45-52` | `{id, agent, agentName, status}` 四字段 | ✅ 原样保留，成为对话元数据的子集 |
| `TerminalManager` | `terminal_state.rs` | **per-agent** 终端回显，camelCase 序列化有测试锁定（TC-TS-07） | ✅ 原样保留为「原始输出 dock」，**不**改成 per-conversation |
| `ChatView` | `src/components/chat/chat-view.tsx` | 终端行→消息推导 + Markdown 流式渲染 + composer（Enter/IME 正确） | ✅ 复用渲染层，**换数据源**（§6.4） |
| `MarkdownRenderer` / `Shiki` | `src/components/chat/*` | Lody 渲染栈迁移成果 | ✅ 零改动 |
| 持久化骨架 | `workdir_prefs.rs` | `with_path(temp)` 隔离、`#[serde(default)]`、损坏容忍、锁外写盘（TC-WP-01..04） | ✅ **对话存储照抄这个模式** |
| 鉴权 | `auth_middleware` | 全表保护，GET 免 nonce | ✅ 新路由自动受保护 |
| 桌面侧栏骨架 | `App.tsx`（2026-09-11 深夜已落地） | 新对话按钮 + 历史对话列表（**前端内存快照**，新对话时归档 `buildMessages` 结果）+ 设置视图；真实 headless 执行（claude `-p` / codex `exec` / aider `--message`）已接入 `send_command` | ✅ 骨架保留，**数据源换成后端 conversation store**（P4 换源点：App.tsx 的 history state 与 ChatView 的 `buildMessages` 输入） |
| 「正在思考」占位 | `ChatView`（status==running 且末条非 assistant） | isBusy 禁发 | ✅ 换源后由 `latest_command_id` 指针驱动（§2-A4），语义不变 |

### 3.2 单会话模型的四个硬约束（必须逐个拆除）

1. **`AppState.session` 是单例**（`http_server.rs:32`）：`handle_start_session` 直接覆盖旧值（TC-HT-05）。
2. **切换 Agent 杀会话**（`handle_set_default_agent:463-470` + TC-HT-07）：`*session = None`。
3. **命令与会话无关联**：`submit_command` 从全局 session 取 `sid/agent_id`；`handle_get_message` 的 `session_id` 硬编码 `"unknown"`（`http_server.rs:888`）。
4. **无持久化**：`CommandStore`、`TerminalManager`、会话状态全部进程内存。

### 3.3 一个必须先纠正的认知

**现有 `ChatView` 的「对话」不是真对话**：消息是从 per-agent 终端行反推的（`buildMessages`），同一 agent 的所有历史命令混在一条流里。多对话的第一步就是把**权威数据源从终端行换成对话转录**，终端 dock 退回「原始输出」角色。（对应 Lody：转录在会话文档里是权威，终端只是机器侧旁路输出。）

---

## 4 数据模型与持久化

### 4.1 新增 `services/conversation_store.rs`

```rust
/// 一条对话消息（转录的最小单元，对应 Lody 的 history entry）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TranscriptEntry {
    pub id: String,              // "msg_" + uuid[0..8]
    pub role: String,            // "user" | "assistant" | "error" | "system"
    pub text: String,
    /// 命令来源渠道（"desktop" | "ios" | "watch"）。
    #[serde(default)]
    pub source: Option<String>,
    pub command_id: Option<String>,   // 关联 CommandStore
    pub created_at_ms: u64,
}

/// 对话完整内容（逐对话一个文件，对应 Lody 的会话文档 body）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Conversation {
    pub id: String,              // "conv_" + uuid[0..8]
    pub agent_id: String,
    #[serde(default)]
    pub title: Option<String>,
    /// 对齐 Lody titleSource："auto"（首条消息截取）| "manual"（用户命名，永不覆盖）。
    #[serde(default)]
    pub title_source: Option<String>,
    pub created_at_ms: u64,
    pub updated_at_ms: u64,      // 单调：只在更大时写（对齐 buildSessionActivityPatch）
    #[serde(default)]
    pub archived: bool,
    #[serde(default)]
    pub is_pinned: bool,         // 对齐 Lody isPinned
    /// 对话级覆盖项：不设则回落到全局 model_prefs / workdir_prefs
    #[serde(default)]
    pub model_override: Option<String>,
    #[serde(default)]
    pub workdir_override: Option<String>,
    /// 调度指针：最近一条已提交的命令（恢复真相，见 §2-A4）
    #[serde(default)]
    pub latest_command_id: Option<String>,
    pub messages: Vec<TranscriptEntry>,
}

/// 索引（列表页只读这个，对应 Lody 的 SessionMeta 缓存层）。
#[derive(Debug, Default, Serialize, Deserialize)]
struct IndexStored {
    #[serde(rename = "conversations", default)]
    conversations: Vec<ConversationSummary>,  // 除 messages 外的元数据 + message_count
}
```

**落盘布局**：

```
~/.brewping/
  conversations/
    index.json              ← ConversationSummary 列表（列表页唯一数据源）
    conv_<id>.json          ← 完整转录（含 messages）
```

**必须遵守的四条既有铁律**（来自 MEMORY.md / workdir_prefs 先例）：
1. `Stored` 结构体**必须 `#[serde(default)]`**——老用户升级时旧文件缺键不得清空数据；
2. 测试必须 `with_path(temp_dir)` 隔离，禁止写真实 `~/.brewping/`；
3. 文件损坏/缺失 → 退化为空表，**不 panic**（TC-WP-03 同款）；
4. 「锁内改快照、锁外写盘」——`Mutex` guard 不跨 I/O 持有（照抄 `WorkdirPrefs::set:51-65`）。

### 4.2 `AppState` 改造

```rust
pub struct AppState {
    // ❌ 删除： pub session: Arc<RwLock<Option<SessionInfo>>>,
    // ✅ 替换为（三个字段一起上，缺一会竞态）：
    pub conversations: Arc<ConversationStore>,
    pub active_conversation_id: Arc<RwLock<Option<String>>>,
    // 以下全部不动
    pub terminal: TerminalManager,       // 仍是 per-agent 原始输出
    pub command_store: CommandStore,     // CommandEntry 加 conversation_id
    ...
}
```

`CommandEntry` 加 `conversation_id: Option<String>`；`handle_get_message` 用它回填 `session_id`（彻底删掉 `"unknown"` 占位）。

---

## 5 模块结构与代码组织

### 5.1 Rust 侧（src-tauri）

```
src-tauri/src/
  services/
    conversation_store.rs   ← 新增：数据模型 + 存取 + 追加/重命名/归档/删除 + 全部单测（TC-CV-01..）
    conversation_api.rs     ← 新增：axum handlers（对齐 folder_api.rs 的拆分方式）
    command_runner.rs       ← 新增：两处 spawn 的去重抽取 + 命令状态唯一写入点（§2-A5）
    http_server.rs          ← 修改：AppState 字段替换、submit_command 改路由、status 响应组装
    mod.rs                  ← 登记 pub mod
  lib.rs                    ← 修改：DesktopCore 初始化、send_command 改路由、新增 Tauri 命令
```

新增路由（6 条，全部自动落入 `auth_middleware` 保护）：

| 方法 | 路径 | 语义 | 鉴权 |
|---|---|---|---|
| `GET` | `/api/conversations` | 列表（pinned 优先 + updated_at 降序，§1.5 公式；`?includeArchived=true`） | Bearer（GET 免 nonce） |
| `POST` | `/api/conversations` | **物化**：`{agentId?, title?, firstMessage}`（§6.1） | Bearer + nonce |
| `GET` | `/api/conversations/{id}` | 完整转录 | Bearer |
| `PATCH` | `/api/conversations/{id}` | `{title?, archived?, pinned?}` | Bearer + nonce |
| `DELETE` | `/api/conversations/{id}` | 删除（仅归档态可删，§2-A7） | Bearer + nonce |
| `POST` | `/api/conversations/{id}/activate` | 切换为当前对话 | Bearer + nonce |

`POST /api/message` 与 `/api/session/start|stop` **契约不变**（§8 详述兼容策略）。

### 5.2 前端（React）

```
src/
  components/chat/
    chat-view.tsx           ← 修改：props 从 terminal 换成 conversation + terminal 双源（§6.4）
    conversation-list.tsx   ← 改造：现有侧栏历史列表（内存快照）接后端 conversation store
                              （置顶区/常规区/归档区分组，结构相等稳定化）
  api/
    types.ts                ← 新增 Conversation / TranscriptEntry 类型
    tauri.ts                ← 新增对话命令封装
  App.tsx                   ← 修改：内存快照状态替换为 store 读取 + 事件监听
```

**Tauri 命令**（`lib.rs` 新增，与 `decide_approval` 同模式）：
`list_conversations` / `create_conversation` / `get_conversation` / `rename_conversation` / `archive_conversation` / `delete_conversation` / `activate_conversation` / `toggle_pin_conversation`。

**事件**：沿用 `app.emit` 模式，新增 `conversations-changed` 与 `active-conversation-changed`。

---

## 6 核心逻辑与数据流

### 6.1 创建：草稿模式（对齐 §1.4 的 draft + 原子启动）

```
桌面 UI「新对话」→ 前端本地 draft 态（不调任何 API，无文件产生）   ← 对齐 Lody draft id 预保留
     │ composer 发送首条消息
     ▼
create_conversation({agent_id?, first_message})          ← 一个函数内原子完成：
  ① id = "conv_" + uuid[0..8]，agent_id = 参数 ?? default_agent
  ② 写 conv_<id>.json（messages = [user 首条]）            ← 对齐 startSession「接受单元含首条消息」
  ③ index.json 追加 summary，title_source = "auto"
  ④ latest_command_id = None；若当前无 active → activate
  → emit conversations-changed + active-conversation-changed

手机端直接 POST /api/conversations（带 firstMessage）同样一步物化。
```

**空对话从根上不存在**（Lody："empty tabs are deleted, not archived"）。兜底：启动清理时发现零消息的 conv 文件 → 直接删除不报错。

> 与现状的衔接：当前前端侧栏的「新对话」是内存快照方案（新对话时把 `buildMessages` 结果归档进前端 state，重启即丢）。本方案落地后该机制整体退役：内存快照 → 后端 conversation store，换源点集中在 App.tsx 的 history state 与 ChatView 的 `buildMessages` 输入（项目记忆 23:45 条目已预留此替换计划）。

**创建不 spawn 任何进程**（对齐 Lody createSession）：现有「会话」只是标记，真正的进程生命周期在 `submit_command` 的每次 spawn 里，对话只是命令的归属容器。不要过度设计成常驻 PTY。

### 6.2 切换

```
activate_conversation(id):
  ① 校验存在且未归档（归档的须先恢复——对齐 Lody 归档会话不可直接激活）
  ② active_conversation_id.write() = Some(id)     ← 单点原子切换
  ③ 不改 default_agent、不杀任何东西
  → emit active-conversation-changed
```

**与现状最大的行为差异**：`handle_set_default_agent` 的 `*session = None`（TC-HT-07）**必须删除**——切 Agent 只是换默认，已有对话各自绑定 agent_id。TC-HT-07 随行为改写：断言「切换后既有对话不受影响、新消息路由到各自对话」。

`submit_command` 路由改造（三层回落）：

```rust
async fn resolve_command_target(state: &AppState, body: &MessageBody)
    -> Result<(String, String), StatusCode> {
    // 1) body.conversationId 显式指定 → 该对话的 agent_id
    // 2) body.agentId 显式指定 → 路由到当前 active 对话
    // 3) 都没有 → active_conversation_id；无 active → 400（原 "no active session" 文案）
}
```

`MessageBody` 加两个 `#[serde(default)]` Optional 字段：`conversationId`、`agentId`。旧客户端不带 = 走回落链 = 行为不变。

### 6.3 保存：写路径单一出口 + 状态写入权边界

所有消息写入收口到一个函数（**两处 spawn 点共用**，MEMORY.md 铁律）：

```rust
pub async fn append_to_conversation(state: &AppState, conv_id: &str, entry: TranscriptEntry) {
    // 1) conversation_store.append() —— 内存更新 + 落盘 conv_<id>.json
    //    + index.json 的 updated_at_ms（单调守卫：仅当新值更大才写，§2-A11）/ message_count
    // 2) terminal 回显（现有 append_line 不动，终端仍按 agent 维度）
    // 3) emit conversations-changed + terminal-updated
}
```

| 写入点 | 现有位置 | 改动 |
|---|---|---|
| 用户消息 | `submit_command` 里 `append_line("> text")` | 前加 `append_to_conversation(role:"user")` + 写 `latest_command_id` |
| 助手输出 | `spawn_blocking` 结果处理 | 完成后一次性 `append_to_conversation(role:"assistant", command_id)`；command_runner 写回指针（`completed` 时清 `latest_command_id` 悬空） |
| 错误 | 同上 error 分支 | `role:"error"`（**对话不进失败态**，§2-A6） |

**状态写入权边界（对齐 §1.3）**：`completed/failed` 与指针写回**只能发生在 `command_runner.rs` 内**；HTTP 层、Tauri 命令层、事件监听一律无权改命令状态——这是 Lody "only CLI owns that transition" 的 BrewPing 等价物。

**桌面端 `lib.rs::send_command` 与 HTTP 端 `submit_command` 必须同批接入**：最稳妥做法是抽 `command_runner.rs::run_agent_command(...)` 两处共用（本方案附带完成去重）。

**前端数据源切换**（`chat-view.tsx`）：

```
现在：buildMessages(terminal.outputLines)         ← 推导
改为：conversation.messages                      ← 权威转录
      terminal 仍传给终端 dock（原始输出角色不变）
      isStreaming = conversation.latest_command_id 在 CommandStore 中处于 queued/working
```

Markdown/composer/贴底/IME 全部原样保留。`buildMessages` 降级为老数据兜底，不删。

### 6.4 删除与归档（两段式，对齐 §1.4）

```
archive_conversation(id):
  ① 该对话存在 queued/working 命令 → 409 拒绝（等命令终态再归档）
  ② archived = true；若是 active → active = None（landing 态）
  → emit conversations-changed

restore_conversation(id):
  ① 校验 workdir_override（若设）目录仍存在，否则 409 + 提示先改工作目录
     （对齐 ArchivedLocalProjectRestoreUnavailableError：错误文案 = 用户动作指引）
  ② archived = false
  → emit conversations-changed

delete_conversation(id):
  ① 仅归档态可删（两段式）；未归档 → 409
  ② 删 conv_<id>.json + index.json 移除 summary
  ③ 该对话的 CommandEntry 不清理（轮询中的客户端拿到终态即可）
  → emit conversations-changed
```

**删 active 不自动跳下一个**：显式选择掩盖「正在往哪个对话发消息」的心智（对应 Lody 关最后 tab 回 landing 的确定性）。

### 6.5 列表排序与前端稳定化（对齐 §1.5 / A12）

```
排序键 = if is_pinned { 1e15 + updated_at_ms } else { updated_at_ms }，降序
（Lody pinnedFirstRootRank 原公式，一个数值表达两个维度）
```

`conversation-list.tsx`：列表派生用 `useMemo` + 逐条结构比较，内容不变返回旧引用，避免每次消息追加整列表重渲染。

### 6.6 全景数据流（切换后发一条消息）

```
iPhone POST /api/message {"text":"..."}            桌面 UI send_command(text)
        └──────────────┬──────────────────────────────┘
                       ▼
        resolve_command_target()  → (conv_x, agent_y)
                       ▼
        ApprovalGate.check(text)  （全局档位，与对话无关——「授权是通道属性」既有决策）
          ├─ Pending → pending_approval（挂起不带对话维度，approve 后重新 resolve）
          └─ Allow → submit
                       ▼
        CommandStore.insert_pending(cmd_id, conversation_id: conv_x)
        append_to_conversation(user) + latest_command_id = cmd_id
                       ▼
        command_runner: Command::new(exec).arg(text)
                        [--model ← conversation.model_override ?? model_prefs]
                        [.current_dir ← conversation.workdir_override ?? workdir_prefs]
                        [PATH 补充，两处同构]
                       ▼
        command_runner（唯一写入点）: set_completed/failed(cmd_id)
                                    + append_to_conversation(assistant/error)
                       ▼
   iPhone: GET /api/message/{cmd} → status + response + sessionId(真值)
   桌面:   conversations-changed 事件 → ChatView 增量渲染（Markdown/Shiki）
```

---

## 7 依赖关系与可复用之处

### 7.1 依赖图（新增部分）

```
conversation_store.rs ← 无内部依赖（纯数据 + 文件 I/O）
command_runner.rs     ← conversation_store + http_server::AppState
conversation_api.rs   ← conversation_store + http_server::AppState
http_server.rs        ← conversation_store / conversation_api / command_runner
lib.rs                ← 同上 + Tauri commands
chat-view.tsx         ← api/types.ts(Conversation) + tauri.ts
conversation-list.tsx ← ui/button + ui/badge + tauri.ts
```

外部依赖**零新增**：serde/uuid/dirs/tokio 已在 `Cargo.toml`；前端零新包。

### 7.2 可复用清单

| 复用项 | 来自 | 怎么复用 |
|---|---|---|
| 持久化骨架 | `workdir_prefs.rs` | `with_path` / `#[serde(default)]` / 损坏容忍 / 锁外写盘，整套照抄 |
| HTTP 测试底座 | `http_server.rs` tests | `test_state()` / 裸 TCP `request()` / `spawn_server()` 直接复用 |
| 状态机与测试编号 | `CommandStore` | `CommandEntry` 扩展后 TC-CS-01..04 大部分原样可跑 |
| 渲染层 | `chat-view/markdown-renderer/shiki-theme` | 零改动（Lody 迁移成果） |
| 事件模式 | `app.emit("terminal-updated")` | 新事件照抄 listen/unlisten 三件套 |
| 错误体契约 | TC-HT-26 | 新端点全部走 `json_response()` |

### 7.3 对 iOS / macOS 端的影响（兼容策略）

**核心承诺：`/api/status` 的 `session` 字段与 `POST /api/message` 请求/响应结构不变**，iOS 端零改动：

- `/api/status.session` = active 对话渲染出的 `SessionInfo`（无 active → `null`）；
- 旧客户端 `POST /api/message` 不带新字段 → 落到 active 对话 → 行为与今天的单会话等价；
- `GET /api/message/{id}` 补真 `sessionId` 是**加法**（iOS 的该字段本就是 Optional）。

**需要显式声明的语义变更**：
1. 切换 defaultAgent 不再终止会话（TC-HT-07 测试随行为更新）；
2. 重复 `POST /api/session/start`：等价于「创建新对话并激活」（旧对话保留，只是不再 active）。

**Demo 后端**：`DemoBackend.swift` 的 switch 需同步 6 个新端点（2 条假对话的简化实现）。**本期可暂缓**——新端点只有桌面 UI 与二期 iOS 调用；二期 iOS 接入时必须补。

---

## 8 实现要点与难点

1. **⚠️ 两处 `Command::new` 同批改**（`http_server.rs` / `lib.rs`）。借机抽 `command_runner.rs` 去重，同时它成为命令状态的唯一写入点（§2-A5）。控制范围：只抽执行与转录写入，不动鉴权与事件名。
2. **⚠️ 锁纪律**：`active_conversation_id` 是 `tokio::RwLock`，`resolve_command_target` 里 read 后立即 clone 并 drop，禁止跨 `.await` 持有（照抄 `submit_command:584-590` 的既有姿势）。`ConversationStore` 内部用 `std::sync::Mutex`（同步上下文友好），文件 I/O 在锁外。
3. **⚠️ 审批与对话解耦**：`ApprovalGate` 保持全局。挂起的 approval 不记对话；批准后走 `submit_command` 重新 resolve——挂起期间切了对话，命令落进新 active 对话。**有意行为**，文档和 UI 都不要暗示「审批绑定对话」。
4. **转录与终端行的时间轴差异**：终端是逐行原始流；转录的 assistant 是命令完成后一次写入的整段 stdout。前端以转录为准、终端 dock 是旁路，不要试图逐行同步（对齐 Lody：会话文档是权威，终端是机器侧旁路）。
5. **并发写同一对话文件**：`Mutex` 内串行化即可（追加 O(1) + 小文件全量重写）；不引入 async 文件锁。
6. **标题只自动生成一次**：首条 user 消息落库时 `title == None` 则截前 32 字符并置 `title_source: "auto"`；用户 `PATCH` 改名置 `"manual"`，此后永不覆盖（对齐 Lody titleSource 语义，`#[serde(default)]` 兼容旧索引）。
7. **`updated_at_ms` 单调写入**：`append`/`patch` 时仅当新时间戳更大才更新（对齐 `buildSessionActivityPatch`），乱序事件不回拉排序。
8. **重启中断恢复**：启动加载索引后，对 `latest_command_id` 非空但 CommandStore 已无此命令的对话，追加一条 `system` 条目「上次执行被中断」并清指针——指针是恢复真相（§1.2），不做更复杂的恢复。
9. **测试更新是方案的一部分**：TC-HT-04/05/07 随语义改写并注释「多对话后的新语义」；新增 TC-CV-01..（store）、TC-CA-01..（HTTP 契约）、TC-CL-01..（列表排序/稳定化）。
10. **不要做的东西**：❌ per-conversation 审批档位；❌ 子对话/fork 级联（§1.7）；❌ 常驻 PTY/ConPTY；❌ 转录 CRDT/同步；❌ 删除时自动清理 CommandStore；❌ 未读徽标（二期）。

---

## 9 实施顺序（四阶段，每阶段可独立验收）

| 阶段 | 内容 | 验收 |
|---|---|---|
| P1 | `conversation_store.rs` 数据模型（含 title_source/is_pinned/latest_command_id）+ 持久化 + 单测；`CommandEntry` 加字段 | `cargo test` TC-CV 全绿；TC-CS 原有全绿 |
| P2 | `command_runner.rs` 抽取（状态唯一写入点）+ 双入口接入转录写入；`resolve_command_target` 三层回落 | 既有 TC-HT 全绿（04/05/07 按新语义改写）；iOS 真机回归无感 |
| P3 | 6 条 HTTP 端点 + sessionId 回填 + status.session 组装 | TC-CA 契约测试；curl 验证列表/创建/切换/归档/删除/置顶 |
| P4 | 前端：侧栏历史列表从内存快照换成 conversation store（排序公式 + 稳定化）+ ChatView 换源 + Tauri 命令 | 桌面 UI 两条对话独立收发；重启转录恢复；草稿取消零残留；归档/恢复/删除/置顶 |

---

## 10 验收用例（关键 20 条）

| 编号 | 用例 | 期望 |
|---|---|---|
| TC-CV-01 | create → append ×3 → 重启加载 | 转录与顺序完整恢复 |
| TC-CV-02 | index.json 损坏 | 退化为空列表，conv 文件不丢 |
| TC-CV-03 | 删除 active 对话 | active 置空，不自动跳转，`/api/status.session` = null |
| TC-CV-04 | 归档对话 activate | 拒绝；恢复后可激活 |
| TC-CV-05 | 首条消息自动命名 + 手动重命名后不覆盖 | `title_source` 分别为 auto/manual，manual 永不被覆盖 |
| TC-CV-06 | 草稿取消（前端新建后不发消息） | 无任何文件产生；重启无空对话残留 |
| TC-CV-07 | 存在 working 命令时归档 | 409 拒绝；终态后可归档 |
| TC-CV-08 | 恢复时 workdir_override 已删除 | 409 + 指引文案；改工作目录后可恢复 |
| TC-CV-09 | 乱序 append（旧时间戳后到） | `updated_at_ms` 不回退，排序稳定 |
| TC-CV-10 | 重启时 latest_command_id 悬空 | 转录补 `system` 中断条目，指针清空 |
| TC-CA-01 | 旧客户端（无新字段）POST /api/message | 落入 active 对话，响应逐字段兼容 |
| TC-CA-02 | POST /api/message 带 conversationId | 落入指定对话，即使非 active |
| TC-CA-03 | 无 active 对话发消息 | 400 + 原 `"no active session"` 文案 |
| TC-CA-04 | GET /api/message/{id} | `sessionId` 为真值，不再 "unknown" |
| TC-CA-05 | GET 免 nonce、POST/PATCH/DELETE 需 nonce | 与鉴权矩阵一致 |
| TC-CA-06 | 未知 conversationId | 404 JSON（TC-HT-26 契约） |
| TC-CA-07 | 切换 defaultAgent 后旧对话发消息 | 仍路由到原 agent（新语义） |
| TC-CA-08 | DELETE 未归档对话 | 409；先归档后删除成功 |
| TC-CL-01 | 列表排序：置顶 + 最新活动 | pinnedFirst 公式输出，置顶区恒在前 |
| E2E-01 | 桌面创建 A、B 对话各发一条 + iPhone 同时发 | 三路转录独立、顺序正确；互不串台 |

---

## 11 文件索引

**Lody 参考实现（只读）**
- `packages/components/src/hooks/use-session-actions.ts` — 生命周期唯一收口（创建/启动/归档/恢复/删除/置顶/重命名/已读）
- `packages/shared/src/schema.ts:800-978` — `SessionMeta` 全量字段 + 调度指针收敛函数
- `packages/components/src/atoms/doc-meta.ts` — 列表派生 atom 与结构相等稳定化
- `packages/components/src/lib/session-opened-by-tree.ts:94-99` — pinnedFirst 排序公式
- `packages/components/src/hooks/use-chat-landing-draft-session.ts` — 草稿会话
- `packages/components/src/components/sessions/session-tab-close-target.ts` — 关闭目标纯函数
- `apps/cli/src/session/session-manager.ts` — 机器侧会话生命周期（spawn/cleanup/archive；`:2269-2275` 错误 turn 级注释）

**BrewPing 改动**
- `src-tauri/src/services/http_server.rs` — AppState 字段替换、resolve 路由、status 组装、TC-HT-04/05/07 改写
- `src-tauri/src/lib.rs` — DesktopCore 初始化、send_command 接入、8 个新 Tauri 命令
- `src-tauri/src/services/mod.rs` — 登记
- `src/components/chat/chat-view.tsx` — 数据源换 transcript（保留终端行兜底）
- `src/api/types.ts` / `src/api/tauri.ts` — 类型与命令封装
- `src/App.tsx` — 对话状态、事件、列表入口

**BrewPing 新增**
- `src-tauri/src/services/conversation_store.rs`（模型 + 持久化 + 单测）
- `src-tauri/src/services/conversation_api.rs`（6 端点 handlers）
- `src-tauri/src/services/command_runner.rs`（spawn 去重 + 命令状态唯一写入点）
- `src/components/chat/conversation-list.tsx`（由现有侧栏内存列表改造而来）

**明确不动**
- `terminal_state.rs`（per-agent 原始输出角色不变）、`pairing_store.rs`、`approval_gate.rs`、`model_prefs.rs`、`workdir_prefs.rs`、`folder_*`、`markdown-renderer/shiki-theme`、`mdns_broadcast.rs`、iOS 端全部、已落地的 headless 执行参数约定与设置视图。
