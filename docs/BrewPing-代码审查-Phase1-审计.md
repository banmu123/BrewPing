# BrewPing 代码审查报告 —— Phase 1 审计

> 范围：死代码 / 无效逻辑 / 资源生命周期 / 轻量性能。
> **本阶段未修改任何代码**（按你的要求 Phase 1 只审计）。所有结论均附文件:行 + 引用依据。
> 审计时间：2026-09-16　基线：`90394ca`

---

## 0. 方法与边界（先说清楚，避免误信）

审计手段：**符号级引用分析**代替"看文件名猜"。

- 对 124 个 Swift 文件做正则抽取（类型 / 函数 / 顶层常量）→ 全仓词边界引用计数 → 减去声明处自身 → 得"零引用"候选（92 个）。
- Rust / Kotlin / TS 用 `git grep` 逐符号核对，并交叉验证子代理结论。

### 这套方法的三个盲区（务必知道）

1. **带缩进的 `var/let` 属性抓不到**。`AgentManager.isDefaultSessionCapable` 就是这么漏掉的，靠人工 grep 补回。所以下面清单**不是全集**。
2. **动态调用一律显示"零引用"，必须人工排除**。这 92 个候选里绝大多数属此类：XCTest 测试方法、`@main` App、SwiftUI `View.body`、`NSViewRepresentable`、`Layout.placeSubviews`、`URLProtocol` 覆写、`NetServiceDelegate`、`WKNavigationDelegate`、CameraX、Compose。**这些不是死代码，一条都不能删。**
3. **不同 target 的同名类型不是重复**。`ConversationStore`（`Sources/App` vs `ios/BrewPing`）、`ContentView`（iOS vs Watch）、`LatteTheme`（iOS vs Watch）分属不同编译单元，改不动也不该合并。

### 一句话结论

**Swift 侧没有死文件**（124 个文件里没有一个整文件不可达），维护状况良好；问题集中在**零散"已写好但从未接线"的小 API**。
**Rust 侧有一个系统性隐患**：`lib.rs:1` 全局关闭了编译器死代码检查，所以 `cargo check` 的"零警告"不成立，死代码会持续无声累积。

---

## 1. Confirmed Dead Code（可确证删除）

判断标准：**全仓（含测试与非 Swift 语言）零引用**，且能排除动态调用。

### 1.1 Swift —— 整文件死亡

| 文件 | 符号 | 引用情况 | 判断依据 | 风险 | 建议 |
|---|---|---|---|---|---|
| `Sources/Protocol/Model.swift`（全文 42 行） | `BrewPingProtocol.ModelProvider`、`BrewPingProtocol.AgentModel` | **0** | `\bAgentModel\b` 全仓仅 Model.swift:19（自身）；`\bModelProvider\b` 仅 :5/:22/:31（后两处都在 AgentModel 内）。已被 `Sources/Protocol/ProviderModel.swift` 的 `BrewPingProtocol.Model` **取代**（后者被 `AgentConfigDiscovery` 实际使用） | 低 | **删整文件** |

### 1.2 Swift —— 被新实现取代的旧实现

| 文件:行 | 符号 | 引用情况 | 判断依据 | 风险 | 建议 |
|---|---|---|---|---|---|
| `Sources/App/CLIConfigSupport.swift:138` | `CLIConfigIO.fingerprint(at:)` | **0** | 已被 `AgentConfigDiscovery.configVersion`（:35）取代；其自身注释即写"与 AgentConfigDiscovery.configVersion 同格式"。附带线索：该行 `{` 与函数体挤在同一行，是编辑事故痕迹 | 低 | 删 |

### 1.3 Swift —— 从未接线的公共 API

| 文件:行 | 符号 | 引用情况 | 判断依据 | 风险 | 建议 |
|---|---|---|---|---|---|
| `Sources/Agents/AgentManager.swift:108` | `refreshAgents()` | **0 生产调用点** | 唯一的同名命中是 `DesktopEvent.refreshAgents`（DesktopEvents.swift:20），其处理器（DesktopAppState.swift:243）调的是 `refreshStatus()+refreshTerminal()`，**不调本方法** | 低-中 | 删；或接线（见下方 ⚠️） |
| `Sources/Agents/AgentManager.swift:122` | `isDefaultSessionCapable` | **0** | 仅 :123 自身；人工 grep 补（缩进 `var` 是检测盲区） | 低 | 删 |
| `Sources/App/DesktopEvents.swift:54` | `desktopEventMatches(_:_:)` | **0** | 全仓唯一命中即此行 | 低 | 删 |
| `Sources/App/MiniTOML.swift:144` | `isEmptyTable(_:)` | **0** | 含 `CLIConfigTests` 在内零引用 | 低 | 删 |
| `Sources/PTY/PTYText.swift:20` | `escapedForDisplay(_:maxChars:)` | **0** | 全仓唯一命中即此行 | 低 | 删 |
| `Sources/BrewPingDesktop/SetupWizardView.swift:933` | `private func nodeDetail(version:path:source:)` | **0** | `private` 且同文件内也无调用 | 低 | 删 |
| `ios/BrewPing/FolderBrowserStore.swift:309` | `supportsWorkdir(agentID:)` | **0** | 全仓唯一命中即此行 | 低 | 删 |
| `ios/BrewPing/ContentView.swift:21` | `LifecycleResponse`（`Decodable`） | **0** | 无任何解码点：JSONDecoder 需要 `T.self`，没有引用就无法被解码 | 低 | 删 |

> ⚠️ **`AgentManager.refreshAgents()` 有语义后果**：它是"重新扫描已安装 Agent"的唯一入口。删掉它 = 确认"桌面端启动后不再重扫"是既定行为；若你期望插上 U 盘式的新 CLI 能被发现，正确动作是**接线**而不是删除。**这条需要你拍板。**

### 1.4 Swift —— iOS 疑似"旧入口残留"（需确认，勿直接删）

| 文件:行 | 符号 | 引用情况 | 判断依据 | 风险 | 建议 |
|---|---|---|---|---|---|
| `ios/BrewPing/LanguageManager.swift:114` | `applyExternal(_ raw:)` | **0** | 全仓唯一命中即此行 | 中 | ⚠️ **先确认**Watch→iPhone 语言同步是否另有入口。若有 → 删；若无 → 这是**功能缺口**，删了就永久丢失该能力 |

### 1.5 Rust

| 文件:行 | 符号 | 引用情况 | 判断依据 | 风险 | 建议 |
|---|---|---|---|---|---|
| `services/danger_pattern.rs:144` | `pub fn rule_count()` | **0** | 含 `#[cfg(test)]` 在内零引用（`cargo check` 不报是因为 §1.7 的全局 allow） | 低 | 删 |
| `services/mdns_broadcast.rs:91` | `pub fn is_broadcasting(&self)` | **0** | 零引用 | 低 | 删 |
| `services/mdns_broadcast.rs:98-102` | `pub struct MdnsStatus` | **0** | 零引用且无构造点，与 `is_broadcasting` 互为印证（原本设计应把 broadcaster 存进 `DesktopCore`，最终没存） | 低 | 删 |

### 1.6 Android

| 文件:行 | 符号 | 引用情况 | 判断依据 | 风险 | 建议 |
|---|---|---|---|---|---|
| `ui/HomeViewModel.kt:109` | `statusPollJob` | **恒为 null** | 只在 :569/:622 被 `cancel()`，**从未赋值**；真正的轮询在 `repository/DesktopRepository.kt:89/134` | 低 | 删（连带两处 no-op cancel） |
| `ui/HomeViewModel.kt:57` | `val messageText`（公开 StateFlow） | **0 收集者** | 只在 :285/:354/:615 写、无人读；UI 用的是 `HomeScreen.kt` 自己的同名局部变量 | 低 | 删 |
| `ui/HomeViewModel.kt` | `sendMessage`(≈:350) 及整条 `_messageText` 链路 | **0 调用点** | 首页"直接发消息"链路未接线 | 低-中 | 删整链（连带 :284/:350 等） |
| `CommandReceiver.kt:10` | `class CommandReceiver` | **生产 0 调用** | 在 `MainActivity.kt:37` 注入、`HomeViewModel.kt:33/639` 持有，**方法从未被调用**；唯一使用者是 `test/CommandReceiverTest.kt` | 中 | ⚠️ 删的话要**连同测试一起删**（否则测试变孤儿，基线会红）。建议先确认是否打算接线 |
| `ui/theme/Color.kt:49-60` | `BrewPingBackground` 等 12 个颜色常量 | **0** | 文件注释自称"逐步迁移后删除" | 低 | 删 |
| `repository/DesktopRepository.kt:94` 等 | `start()`、`setDefaultAgent/startSession/stopSession/refreshDiscovery`(:188/199/226/378) | 唯一调用者是被上表判死的 HomeViewModel 方法 | 中 | 保留下层 `DesktopApiClient` + 其单测，删 Repository 层这几个转发 |

### 1.7 🚨 最高价值动作（不是删代码，而是恢复检查能力）

| 文件:行 | 内容 | 依据 | 风险 | 建议 |
|---|---|---|---|---|
| `Sources/BrewPingwinDesktop/src-tauri/src/lib.rs:1` | `#![allow(dead_code, unused_variables)]` | **crate 级**全局关闭死代码与未用变量检查 → `cargo check` 的"零警告"不成立，§1.5 那三条就是被它藏住的 | 低 | **移除或收窄到具体项**。这一项做完，Rust 侧的真实清单会自动浮现，比手工 grep 可靠得多 |

### 1.8 TypeScript / React

| 文件:行 | 符号 | 引用情况 | 依据 | 风险 | 建议 |
|---|---|---|---|---|---|
| `src/components/StatusCard.tsx`、`AgentList.tsx`、`NetworkInfo.tsx` | 整个文件 | **0 import** | Vite 脚手架残留（还用着模板的 `className="card"`，`NetworkInfo.tsx` 硬编码中文"网络信息"） | 低 | 删 3 个文件 |
| `src/components/chat/chat-view.tsx:43` | `buildMessages` | **0** | 零引用 | 低 | 删 |
| `src/components/chat/chat-view.tsx:65` | `deriveTitle` | **0** | 零引用 | 低 | 删 |
| `src/components/chat/chat-view.tsx:89/:93/:97` | `COMPOSER_PILL_CLASS`、`COMPOSER_SELECT_CLASS` | **0** | 零引用 | 低 | 删 |
| `src/api/tauri.ts:48/55/62/101/117/192` | `setDefaultAgent`、`getLanIp`、`getPort`、`setApprovalMode`、`getActiveAgentId`、`setAgentWorkdir` | **0** | 六个封装零调用（Rust 侧命令**存在且已注册**，属"后端有、前端没入口"） | 低 | 删封装；若是有意留给未来 UI，则保留并加注释 |

**正向核对（无问题）**：`tauri.ts` 全部 62 个 `invoke()` 命令名都能在 `lib.rs` 找到对应 `#[tauri::command]` → **无悬空调用**。Rust 侧 63 个命令定义 ↔ 63 个注册，**完全一致**。

---

## 2. Probably Dead Code（看着没用，但**不建议现在删**）

| 文件 | 符号 | 为什么可能死 | 为什么保留 |
|---|---|---|---|
| `Sources/Protocol/Event.swift`（全文 108 行） | `BrewPingProtocol.Event`、`EventPayload`、`EventType`（12 个常量） | 全仓零引用 | 文件头**明确写着**"为未来实时同步（WebSocket / Push / Relay）预留；当前阶段仅定义结构"。这是**有意的未来 API 预留**，删除属产品决策而非清理；且其预期消费者 `relay-server/` 本身也没接线。**建议保留**，或移入 `docs/` + issue 追踪 |
| `Sources/App/ModelProviderStore.swift:320` | `proxyConfig() -> (enabled:port:failover:)` | 零引用 | 与 Windows 侧"代理特性开关关闭但后端保留"一致；删掉等于永久放弃 macOS 侧接线 |
| `Sources/BrewPingwinDesktop/src-tauri/src/services/http_server.rs:183-184` | `PairBody.device_name` | 反序列化后从不读取（客户端传了被静默忽略） | 可能是**协议字段对齐**（iOS 侧照发）。删字段会让 serde 收紧、旧客户端请求被拒 |
| `rename_conversation`（Rust，已注册于 `lib.rs` `generate_handler!`） | 前端 0 调用 | 反向孤儿 | 后端功能完整，可能只是 UI 还没加入口 |
| Android `ConversationSummary.createdAtMs/titleSource/latestCommandId`、`TranscriptEntry.source/commandId`、`DesktopDevice.version/status/agents/...` 等 | 只解析不读 | 手动 `org.json` 解析（非 `@Serializable`，不涉及反射） | **契约镜像字段**：与电脑端/iOS 接口逐字段对齐，删了以后要用还得加回来 |
| `relay-server/`（整目录，17 个已跟踪文件） | — | 全仓 0 消费者：Swift/Kotlin/Rust/TS 里**无任何 `ws://`/`wss://`**；CI 无 relay job；README:324/354/364 等只有"尚未接线/勿公网部署"的文字提及；其自述亦写"尚未接入任何 BrewPing 客户端…仅作为早期原型随源码提供" | **判断依据充分**，但删除是产品决策。建议**移入 `archive/` 或独立分支**，而不是直接删（Dockerfile + types + tests 有参考价值） |

---

## 3. Duplicate Logic（重复实现）

### 3.1 🚨 跨平台同一个病根：厂商配置的「路径表」被手工复制多份

这是本次最值得收敛的重复——**两端各自复制了同一张配置路径表，靠注释提醒"要保持一致"**：

| 平台 | 位置 | 份数 |
|---|---|---|
| Swift | `Sources/Agents/AgentConfigDiscovery.swift:63`（读侧）、`Sources/App/ClaudeProviderConfig.swift:98`、`CodexProviderConfig.swift:136`、`OpenCodeProviderConfig.swift:114`（写侧） | **4** |
| Rust | `agent_config.rs:138/221/320/409/417`、`opencode_config.rs:174`、`claude_config.rs:118`、`codex_provider_config.rs:167`、`pi_config.rs:181,190`、`cli_takeover.rs:110-116` | **6** |

证据（注释自述同步义务）：`ClaudeProviderConfig.swift:97` / `OpenCodeProviderConfig.swift:7` 都写着"与 `AgentConfigDiscovery.configPaths` 一致/同一顺序"。
**风险**：中。漂移后果是"读到的路径"与"写入的路径"不一致 → 配置写了但读不到。

### 3.2 Rust —— 逐字节相同的函数副本

| 函数 | 副本位置 | 份数 |
|---|---|---|
| `is_valid_provider_key` | `codex_provider_config.rs:113`、`opencode_config.rs:117`、`pi_config.rs:132` | 3 |
| `slugify_provider_key` | `codex_provider_config.rs:141`、`opencode_config.rs:145`、`pi_config.rs:155` | 3 |
| `type_name(&Value)` | `claude_config.rs:167`、`opencode_config.rs:230`、`pi_config.rs:227` | 3 |
| `config_lock()` | `claude_config.rs:140`、`codex_provider_config.rs:209`、`opencode_config.rs:199`、`pi_config.rs:222` | 4 |
| `read_config_at` / `write_config_at` | claude / opencode / pi 各一份（pi 版= 同体 + temp+rename） | 3+3 |
| `json_response` | `folder_api.rs:21`（私有）vs `http_server.rs:220`（pub） | 2 |

> ⚠️ `config_lock()` 四份**各自独立 `OnceLock<Mutex<()>>`，互不相通** → 名为"配置锁"却挡不住跨模块并发写。这是**隐藏缺陷**，不只是重复。
> ⚠️ 反例（勿误合并）：`entry_to_value`/`value_to_entry` 在 claude/opencode/pi 三处**同名但语义不同**，不可合并。

### 3.3 Swift

| 位置 | 内容 | 风险 |
|---|---|---|
| `CLIConfigSupport.swift:72` vs `:99` | `writeJSONObject` 与 `writeJSONObjectAtomic` 除写入方式外约 20 行重复（编码 + 建目录 + 补 `0x0A`） | 低（差异有安全理由：保权限，注释已说明） |
| `CLIConfigSupport.swift:26` vs `AgentConfigDiscovery.swift:56` | BOM 剥离两份（一份对 `Data`、一份对 `String`） | 低 |
| `AgentInfo.swift:4` vs `Protocol/Agent.swift:16` | 两个 `AgentStatus`（一个顶层、一个嵌套在 `BrewPingProtocol` 下）——**因嵌套故不冲突**，但同名易混淆，语义也不同（运行状态 vs 协议状态） | 低（**建议不改**，改会动协议） |
| `AgentManager.swift:85` vs `:116` | `activeAgentID` 与 `defaultAgentID` 是**完全相同的 getter**，两个都在用（前者 Desktop/UI，后者 App/HTTP 层） | 低。⚠️ 附带问题：`:114` 注释写"Legacy API（保持向后兼容）"，但 `defaultAgentID` 有 7 处调用、是实际主名 —— **注释是错的** |

### 3.4 Android

| 位置 | 内容 | 风险 |
|---|---|---|
| `DesktopApiClient.kt:443/477/549/673` | HTTP 状态映射（401/404/501/非 200）四份雷同 | 中 |
| `HomeViewModel.kt:132/552/600` | "host/port → DesktopDevice" 三份 | 中 |
| `HomeScreen.kt:136/395` + `HomeViewModel.kt:214` | 设备"复用/新建"三份近似 | 中 |
| `HomeViewModel.kt:46` vs `ConversationStore.kt:32` | 本地化 `msg()` 逐字重复 | 低 |

### 3.5 单调用点却被设计成复杂抽象

| 位置 | 内容 | 风险 |
|---|---|---|
| `Sources/Agents/TerminalAgent.swift:25` | `protocol TerminalAgent` **只有唯一遵循者 `OpenCodeAgent`**；作为 existential 使用也为 0 处 | 低（**建议保留**：它给"session 型 vs headless 型"提供了明确边界，是文档性价值） |
| Rust `model_transform.rs:554` | `pub fn create_anthropic_sse_stream<E,S>` 泛型 + 约 300 行 `SseState` 状态机，唯一生产调用点 `model_proxy.rs:375` | 低（**不建议动**，SSE 转换本质复杂） |
| Rust `model_list.rs:11/35` | 整模块 67 行，唯一调用点 `lib.rs:1226`；其中 `dedup_sort` 是 `pub` 但仅本文件用 → 该降为私有 | 低 |
| Rust `model_transform.rs:336` | `pub fn is_openai_o_series` 仅本文件内用 → 该降为私有 | 低 |

---

## 4. Lifecycle Issues

| # | 位置 | 原因 | 风险 | 修改方式 | 修改后行为 |
|---|---|---|---|---|---|
| 1 | Rust `lib.rs:1458` `std::mem::forget(mdns)` | `MdnsBroadcaster` 是局部变量，靠 `forget` 续命才能让 mDNS 常驻 → **有意泄漏**。后果：`mdns_broadcast.rs:83 stop()` 与 `:91 is_broadcasting()` **永不可达**（与 §1.5 互为印证）；退出时无 mDNS 优雅注销，手机端设备列表要等 TTL 才消失 | 中低 | 把 broadcaster 存进 `DesktopCore`（`app.manage`），退出走 `stop()` | 进程内只多一个受管句柄；可优雅注销；`stop()/is_broadcasting()` 复活。⚠️ 非"内存持续增长"型泄漏（每进程一次），**不建议为此改架构**，但存进 Core 是低风险正解 |
| 2 | Swift `Sources/Agents/AgentDiscovery.swift:107-131` `SystemCommand.run` | **先 `waitUntilExit()`（:120）再读 pipe（:128）**。子进程输出超过管道缓冲（macOS 64KB）→ 子进程阻塞在 write → 永不退出 → 超时 `terminate()` → 返回 nil | 中 | 参照 Windows 侧同款修法：`command_runner.rs:378` 注释已明确"stderr 必须与 stdout 并发读：串行读会在 stderr 管道写满（4KB）时死锁"——**Windows 修了，macOS 没修**。改为并发读或先读后等 | 大输出不再误判。**当前表现**：`HeadlessCLIAgent.execute` 把 nil 报成 `"Failed to launch \(name) (\(path))"` —— **错误信息具有误导性**（进程其实启动了） |
| 3 | Android `ui/QrScanScreen.kt:96-138` | 相机 `provider.bindToLifecycle(lifecycleOwner /* = Activity */, …)`（:125）绑到 **Activity** 生命周期；:124 有防御性 `unbindAll()`，但它只在 provider future 回调里执行一次，**没有 `DisposableEffect{ onDispose { provider.unbindAll() } }`** | 中 | 加 `DisposableEffect(Unit)`，onDispose 里 `unbindAll()` | 关闭扫码浮层（`HomeScreen.kt:387 if (showQrScan)`）即释放相机，而不是等 Activity onStop。**注**：因绑的是 Activity 生命周期，这不是永久泄漏，是**延迟释放**（补：`:86-88` 的 `analysisExecutor.shutdown` 已正确） |
| 4 | Android `ui/HomeViewModel.kt:588-598` | 模型轮询 `while(true)`：离开页面后靠 `ConversationDetailScreen.kt:157-160` 的 `onDispose` 清空 `currentModelAgentId`，循环 `continue` 空转 | 低-中 | 让循环在 id 为空时退出 | 少一个空转协程 |
| 5 | Android `ui/HomeViewModel.kt:630-634` | `onCleared` 调 `repository.stop()`，而 repository 是 App 级单例 → **Activity 销毁即停 NSD 发现** | 低 | 明确生命周期归属（若确实需要常驻发现则应移出） | 行为不变，但消除"单例被 Activity 关闭"的语义矛盾 |
| 6 | React `App.tsx:412-480` | 九处 Tauri `listen()` 的 cleanup 用 `unlistenX.then(fn => fn())`，**未处理竞态**：StrictMode 下首轮 unlisten 可能晚于第二轮 listen 才 resolve，把第二轮订阅取消掉 | 低（仅 dev） | 改用 `disposed` 标记模式 | dev 下不再偶发丢事件；生产行为不变 |
| 7 | React `App.tsx:682`、`components/setup/setup-wizard.tsx:217/231` | `setTimeout` 无句柄保存、无 cleanup → 卸载后仍 `setState` | 低 | 补 cleanup | 消除卸载后 warn |

**未发现问题（已核查）**：BroadcastReceiver / ContentObserver / SensorManager / Handler / `Timer` 重复注册或未注销（全仓 0 处）；无界缓存（`environment-card.tsx:36` `logBuffer` 有 300 行上限，`taskStates` Map 键集合固定）；`Arc<Mutex>` 循环引用（`lib.rs:1303` 名义环形，AppHandle 与应用同生命周期，实质影响 0）；`reqwest` client 已 `OnceLock` 复用（`model_proxy.rs:73-84`）。
`command_runner.rs` 的 `spawn_blocking` + `std::thread::spawn` 读 stderr 并 `join`（:383/:391）**正确**，无泄漏。

---

## 5. Performance Issues（只列有明确依据的低风险项）

| # | 位置 | 原因 | 风险 | 建议 |
|---|---|---|---|---|
| 1 | Rust `command_runner.rs:360` | **每条用户消息**都调 `agent_discovery::extra_path_dirs()`，**无缓存**；内部 `nvm_version_dirs()` 做 `read_dir`，`nvm_home()`（`agent_discovery.rs:265-290`）在 `NVM_HOME` 不在 env 时**兜底 spawn `nvm root` 子进程**。对照：**macOS 侧 `AgentDiscovery.discover` 有 60s 缓存**（`AgentDiscovery.swift:185`） | 中 | 给 `extra_path_dirs()` 加进程内缓存（或 60s TTL）。纯加速，不改语义 |
| 2 | Rust `agent_discovery.rs:84 discover()` | 无缓存，每次对 4 个 agent 各 spawn 一次 `--version`；调用点 `lib.rs:1270`、`http_server.rs:871`、`tray.rs:126` → **点开托盘菜单即全量重扫（约 8 次进程 spawn）** | 中 | 复用 macOS 的 60s 缓存 +「首帧不阻塞」策略 |
| 3 | React `markdown-renderer.tsx:111` | `remarkPlugins={[...MARKDOWN_REMARK_PLUGINS]}` —— `:22` 已建**模块级单例**，这里展开又变回**每渲染新数组**，直接抵消 `:10` 注释里的规格约束 | 中 | 去掉展开 `[...]`（一行） |
| 4 | React `App.tsx:815-843`、`:855` | 全文 **0 个 `useMemo`**：每次渲染重建 `activeConversations/archivedConversations/groupMap/dirGroups/visibleGroups`（O(n) 分组+排序），`:855 fromTranscript()` 重建整个消息数组 | 中 | 只给这两处包 `useMemo`，不改结构 |
| 5 | React `markdown-renderer.tsx:2-7` + `main.tsx:7` | 顶层静态 import `streamdown`+`shiki`+KaTeX，且全局引 `streamdown/styles.css` → 首屏包 1.21MB / gzip 362KB（vite 已警告 >500KB） | 中 | 改 `React.lazy` + 动态 import，或 vite `manualChunks` |
| 6 | Android `ui/QrScanScreen.kt:180,201` | 每帧分配 `ByteArray(width*height)`，旋转时再复制一份 | 中 | 复用缓冲 |
| 7 | Android 重组内重算 | `HomeScreen.kt:239/287` 每次重组算 `devices.map{}.toSet()`；`:262/296` 读 `viewModel.agentNames`（`HomeViewModel.kt:100` 的 getter 每次都 `associate` 建 Map）；`ConversationListScreen.kt:91-92` 组合内调 `store.dirGroups`（排序）+ `archivedConversations`（filter+sort） | 中 | `remember(...)`/`derivedStateOf` 包裹 |
| 8 | Rust `conversation_store.rs:208 persist` | 同步 `std::fs::write`，被 async 路径直接调用（`http_server.rs:777`、`command_runner.rs:463`），未 `spawn_blocking` | 低 | 本地盘微秒级，可不动；要动就统一包 `spawn_blocking` |
| 9 | Android `DesktopApiClient.kt:332,352` | `get/post` 未用 `.use{}` 关闭 `Response`（`:421 executeRaw` 是正确的） | 低 | 补 `.use{}` |

**未采纳的"性能优化"（为避免无依据重构，明确不做）**：
`env_setup.rs:729 http_agent()` 每次新建 `ureq::Agent` —— 只在环境安装流程调用（低频），**不改**。
`spawn_blocking` 无明显滥用；`Command::new` 共 11 处探测点，均不在高频循环内。

---

## 6. Repository Cleanup

### 可删（不会参与 build / test / release / CI / 文档 / 开发工作流）

| 目标 | 现状 | 动作 |
|---|---|---|
| `ios/.DS_Store` | **已被跟踪**（`.gitignore` 有 `.DS_Store`，但该文件先于规则入库，ignore 对已跟踪文件无效） | `git rm --cached ios/.DS_Store`（保留本地文件） |

### 建议补入库（否则新克隆构建不出安装包）

| 目标 | 现状 | 说明 |
|---|---|---|
| `src-tauri/nsis-assets/{header.bmp,sidebar.bmp}` | **未跟踪**，但被 `tauri.conf.json:24-25` 引用 | NSIS 安装包必用（既有问题） |
| `src-tauri/src/services/proc.rs`、`single_instance.rs` | **未跟踪** | 本次新增，必须入库 |

### 视约定决定

| 目标 | 现状 | 说明 |
|---|---|---|
| `src-tauri/gen/schemas/{acl-manifests,capabilities,desktop-schema,windows-schema}.json` | 已跟踪，约 267KB，其中 `desktop-schema.json` 与 `windows-schema.json` 同为 133493 B | 由 `build.rs:2 tauri_build::build()` 生成；Tauri 官方模板亦常提交 → **团队约定**，若不入库则加 `src-tauri/gen/` 到 `.gitignore` |
| `Android/.kotlin/` | 当前空目录、未入库，但**无任何 ignore 规则覆盖** | 补一条 `.kotlin/`（预防性） |
| `relay-server/` | 17 文件已跟踪、无消费者 | 见 §2，建议移入 `archive/` 而非删除 |

**已确认干净**：`fb.log`（`*.log`）、`fbr.txt`（显式规则）、`Android/local.properties`、`node_modules/`、`src-tauri/target/`、`dist/`、`Android/build/`、`.claude/settings.local.json` —— 全部未入库。
`gradle-wrapper.jar` 入库正确（Android 构建必需）。

---

## 7. Protected Development Infrastructure（**明确不碰**）

### `.workbuddy/` —— 共享开发上下文，**不删、不 gitignore**

已跟踪 **43 个文件**，逐一确认仍在承担 Mac / Windows 同步职责：

- `.workbuddy/memory/`：`2026-09-10.md` … `2026-09-16.md`（7 个日志，**append-only**）+ `MEMORY.md`（长期约定）
- `.workbuddy/outputs/`：34 个产物（iOS/macOS 修复取证截图 20+ 张、`开源发布与网站分发合规审计报告.md`、`自动发现-Xcode直装vsTestFlight差异分析.md`）

根 `.gitignore` 只忽略 `.workbuddy/tauri-dev*.log`（本地 dev server 持有的运行时日志），**没有整体忽略 `.workbuddy/`** —— 符合你的要求，**本次不动**。
`memory/2026-09-16.md` 与 `MEMORY.md` 是**两端都会追加**的文件，改它们必须走「先备份 → 还原 → merge → 再追加」流程（MEMORY.md 里已写死这条）。

### 其他受保护项

| 类别 | 具体 |
|---|---|
| CI / Release | `.github/workflows/ci.yml`、`release-mac.yml`、`dependabot.yml`、`pull_request_template.md` |
| 构建脚本 | `build-app.sh`、`build-dmg.sh`、`Scripts/build-mac-app.sh`、`Scripts/mac/Desktop.entitlements`、`Scripts/mac/Info.plist` |
| 构建定义 | `Package.swift`（三 target 权威定义）、`vite.config.ts`、`tsconfig.json`、`Android/*.gradle.kts`、`src-tauri/Cargo.toml`、`tauri.conf.json` |
| 工具链 | `tools/`（`dmgbuild-settings.py`、`make-appicon.py`、`make-dmg-background.py`、`verify-cli-config.sh`、`verify-cli-config.swift`）、`ios/Scripts/check_localization.py` |
| 动态调用相关 | 所有 `@tauri::command`、`AndroidManifest.xml` 组件、`BrewPingApp`/`@main`、XCTest、Compose `@Composable`、AppKit/UIKit 生命周期回调 |
| 协议契约 | 所有 `Codable`/`serde` 字段、所有 `protocol`、`BrewPingProtocol` 全部类型、`*.lproj/*.strings`、`PrivacyInfo.xcprivacy` |
| 资源 | `ios/**/Assets.xcassets`、`logo/`、`design/BrewPing.pen`、`docs/screenshots/`、`docs/privacy.html` |
| 用户文档引用的命令 | `README*.md`、`SECURITY.md`、`CONTRIBUTING.md` 里出现的 CLI 入口与脚本名 |

### ⚠️ 一个需要你决策的 latent hazard

`Package.swift:12-16` 的 `BrewPingCore` 用 `path: "Sources"` + `exclude: ["BrewPing", "BrewPingDesktop"]`。
**`Sources/BrewPingwinDesktop` 未被排除**，落在 Core 的递归路径内（当前无 `.swift` 文件所以无害）。一旦有人往那儿放 Swift 文件，它会被编进 **macOS 核心库**。建议加进 `exclude`（Phase 2 候选，零风险）。

---

## 8. Potentially Dead But Kept（本次**不删**清单）

1. `Sources/Protocol/Event.swift` 全文件 —— 有意的未来实时同步 API 预留
2. `Sources/App/ModelProviderStore.swift:320 proxyConfig()`
3. Rust `PairBody.device_name`、`rename_conversation`
4. Android 全部"契约镜像字段"
5. `relay-server/` 整目录
6. `Sources/Agents/TerminalAgent.swift` 的 protocol（唯一遵循者，但有边界文档价值）
7. 跨 target 的同名类型（`ConversationStore`/`ContentView`/`LatteTheme`/`ConversationSummary` 等）
8. `ios/BrewPing/LanguageManager.swift:114 applyExternal` —— **在确认 Watch→iPhone 语言同步入口之前不删**
9. `Sources/Agents/AgentManager.swift:108 refreshAgents()` —— **在确认"启动后不重扫 Agent"是有意行为之前不删**
10. Android `CommandReceiver` —— 删它必须连测试一起删，先确认是否打算接线

---

## 9. Phase 2 建议（**待你批准后才动手**）

按风险从低到高，建议分三批：

**批 A（纯删除，零行为影响，约 180 行）**
`Protocol/Model.swift` 整文件、`CLIConfigSupport.fingerprint`、`desktopEventMatches`、`isEmptyTable`、`PTYText.escapedForDisplay`、`SetupWizardView.nodeDetail`、iOS `supportsWorkdir` / `LifecycleResponse`、Rust `rule_count` / `is_broadcasting` / `MdnsStatus`、Android `statusPollJob` / `Color.kt` 12 常量、React 3 个死组件 + 3 个死函数 + 6 个死封装

**批 B（恢复检查能力 + 仓储卫生，零行为影响）**
① 移除 `lib.rs:1` 的 `#![allow(dead_code, unused_variables)]`（**最高杠杆**）
② `git rm --cached ios/.DS_Store`
③ 入库 `nsis-assets/` + `proc.rs` + `single_instance.rs`
④ `Package.swift` 的 `exclude` 补 `BrewPingwinDesktop`
⑤ 补 `.kotlin/` 到 ignore

**批 C（有语义后果，需逐条确认）**
① Android `HomeViewModel` 死链 + `sendMessage` 链删除（连带测试）
② `AgentManager.refreshAgents()` 删 or 接线
③ `mem::forget(mdns)` → 存进 `DesktopCore`
④ macOS `SystemCommand.run` 改并发读 pipe
⑤ Android 相机 `DisposableEffect` 解绑
⑥ 重复函数收敛（`is_valid_provider_key`/`slugify_provider_key`/`type_name`/`config_lock`、两端配置路径表）

**明确不做**：任何"为了更现代"的重构；`AgentStatus` 双定义合并；跨 target 类型统一；`TerminalAgent` protocol 拆除；SSE 状态机改写。

---

## 10. Validation 状态

**Phase 1 未执行任何验证**（只审计、不改代码）。

### Phase 2 批 A 的验证结果（2026-09-16 21:35）

| 检查项 | 结果 |
|---|---|
| Rust `cargo test` | ✅ **314 passed / 0 failed / 1 ignored**（与删除前完全一致） |
| 前端 `tsc`（`noUnusedLocals: true`） | ✅ exit 0 |
| 前端 `vite build` | ✅ exit 0，`built in 5.37s` |
| 悬空引用扫描（Swift / React 全仓词边界） | ✅ **No matches found** —— 17 个被删符号零残留 |
| Swift 结构完整性 | ⚠️ **本机无 Swift 工具链**（Windows），逐个回读改动区域人工核对括号层级 |
| Android 编译 | ⚠️ **本机无 JDK**，无法本地编译；删的是私有字段/顶层常量，静态核对通过 |
| `swift test` / Debug / Release / macOS / iOS 构建 | ⏳ 交由 CI（`ci.yml` 的 swift + apple-targets + windows job） |

---

## 11. Phase 2 · 批 A 执行记录（已完成，零行为影响）

**净删除 356 行，0 行新增。**

| # | 文件 | 删除内容 | 行数 |
|---|---|---|---|
| 1 | `Sources/Protocol/Model.swift` | **整文件**（`ModelProvider` + `AgentModel`） | −42 |
| 2 | `Sources/App/CLIConfigSupport.swift` | `CLIConfigIO.fingerprint(at:)` | −7 |
| 3 | `Sources/App/DesktopEvents.swift` | `desktopEventMatches(_:_:)` | −5 |
| 4 | `Sources/App/MiniTOML.swift` | `isEmptyTable(_:)` | −6 |
| 5 | `Sources/PTY/PTYText.swift` | `escapedForDisplay(_:maxChars:)` | −12 |
| 6 | `Sources/BrewPingDesktop/SetupWizardView.swift` | `private func nodeDetail(...)` | −6 |
| 7 | `ios/BrewPing/FolderBrowserStore.swift` | `supportsWorkdir(agentID:)` | −5 |
| 8 | `ios/BrewPing/ContentView.swift` | `LifecycleResponse` | −7 |
| 9 | `src-tauri/src/services/danger_pattern.rs` | `rule_count()` | −5 |
| 10 | `src-tauri/src/services/mdns_broadcast.rs` | `is_broadcasting()` + `MdnsStatus` | −12 |
| 11 | `android/.../ui/HomeViewModel.kt` | `statusPollJob` 字段 + 两处 no-op `cancel()` | −4 |
| 12 | `android/.../ui/theme/Color.kt` | 12 个 `BrewPing*` 兼容色彩别名 | −14 |
| 13 | `src/components/{StatusCard,AgentList,NetworkInfo}.tsx` | **3 个整文件删除** | −144 |
| 14 | `src/components/chat/chat-view.tsx` | `buildMessages`/`deriveTitle`/`COMPOSER_PILL_CLASS`/`COMPOSER_SELECT_CLASS` | −41 |
| 15 | `src/api/tauri.ts` | 6 个未调用封装（含文档注释） | −46 |

### 执行中的两个发现（都已处理）

1. 🚨 **我自己犯过一次错，靠 `tsc` 抓住**：删掉 `setApprovalMode` 后我以为 `ApprovalMode` 类型 import 也没用了，一并删除 → `tsc` 立刻报
   `src/api/tauri.ts(102,18): error TS2304: Cannot find name 'ApprovalMode'`。
   实际它还被另一个函数（`:102`、`:243`）用作参数类型。**已恢复该 import**。
   → 教训：**"删了 A 就以为依赖 A 的 import 也没用" 是不可靠的推断，必须靠编译器验证。**
2. ✅ **未制造新的死代码**：删除 `MiniTOML.isEmptyTable` 后检查它唯一可能带走的依赖 —— `tableNames(withPrefix:)` 仍被
   `CodexProviderConfig.swift:254/299` 使用，不受影响。

### 语义后果（已确认，均为"零行为影响"）

- `ios/FolderBrowserStore.supportsWorkdir` 是一个**已写好但从未接线的**客户端预检（注释自称"提前拦住避免一次注定失败的请求"）。
  它没被调用 ⇒ 删掉**不改变任何行为** —— 服务端本来就会拒绝 opencode 的 workdir 请求，只是少了一次"不存在的"优化。
- Android `HomeViewModel.statusPollJob` 恒为 `null`，两处 `cancel()` 本来就是空操作；真正的轮询在 `DesktopRepository`。
- `ios/ContentView.LifecycleResponse` 与文件里 `:19` 的注释（"SubmitResponse / CommandStatusResponse 已移到 CommandReceiver.swift"）
  互相印证：它是同一次迁移**漏下的孤儿**。
- Rust `MdnsStatus` / `is_broadcasting` 与 §4 的 `mem::forget(mdns)` 互为印证 —— 本设计应把 broadcaster 存进 `DesktopCore`，最终没存。

### 明确未动（批 A 未包含，保留待批 C）

`AgentManager.refreshAgents()`、`ios/LanguageManager.applyExternal`、`Android CommandReceiver` + `sendMessage` 链、
`Rust PairBody.device_name`、`Sources/Protocol/Event.swift`、`relay-server/`、`lib.rs:1` 的 `allow(dead_code)`。

