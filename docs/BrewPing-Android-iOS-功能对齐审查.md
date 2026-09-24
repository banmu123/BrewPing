# Android / iOS 功能对齐审查（第二版）

> 以 **iOS 为基准**比对 Android，目标是「Android 对齐 iOS」。
> 基线：`d1f8317`（2026-09-24）。上一版基线 `2760047`（2026-09-19）**已过时** —— 其 P0 两项
> （Help/隐私入口、令牌加密）已落地，`CommandReceiver` 死桩已确认「确有但未接线」并**已删除**，详见 §3。
>
> 方法：双端源码清单 → 20+ 个能力探针打两端 → 关键差异逐个回读代码坐实。
> 所有结论都能在下列文件行号处复核；未经证实的推断标注「待确认」。

## 0. 规模概览

| | iOS | Android |
|---|---|---|
| 手机端主源码 | 27 个 `.swift` | `:app` 21 个 `.kt` + `:core` 12 个 `.kt` |
| 手表端 | `ios/Watch` **9 个 `.swift`** | `Android/wear` **7 个 `.kt`** |
| 单测 | Swift 侧 66 例（含核心） | **109 例**（`:core` 67 + `:app` 42） |
| 最大文件 | `ContentView.swift` 74 KB | `HomeScreen.kt` 47 KB |
| 文案规模 | `en/zh-Hans` 各 **237** keys | `values/values-zh` 各 **120** keys（key 集合一致） |
| i18n 调用点 | `L()`/`LW()`/`NSLocalizedString` **138** 处 | `stringResource(` **124** 处 |

**结论先行**：核心链路（发现、配对、多对话、命令、审批、工作目录、模型、多设备、语言、置顶归档、
令牌安全存储）**Android 已经对齐**，其中**有两项还超过了 iOS**；真正缺的只有 **Demo 模式**、
**帮助页的两段**、**手机端语音输入**、**权限恢复引导**，外加 **2 处硬编码文案**。

---

## 实施结果（2026-09-24）

| # | 项 | 状态 |
|---|---|---|
| ① | **Demo 模式** | ✅ **已实现** —— `:core/demo/DemoBackend.kt`（16 端点，形状与桌面端同构）+ `DemoInterceptor.kt`（OkHttp 拦截 `demo.brewping.local`）+ `DemoStrings`（文案由 `:app` 注入，随语言切换）；`ManagedDevice.isDemo` 由主机名派生；`HomeViewModel.isPaired` 对 Demo 放行；`DeviceStore.addDemoDevice()` 幂等；Help 页有入口。单测 31 例 |
| ② | **Help 页缺 2 段** | ✅ **已实现** —— 补 `Language`（三档选择 + 说明）与 `Try it without a computer`（Demo 入口 + 按钮），段序与 iOS `HelpView` 完全一致（8 段） |
| ③ | **手机端语音输入** | ❌ **不是缺口（本条为原审计的误判，已更正）** —— 见下方「更正」 |
| ④ | **权限被拒 → 去设置** | ⚠️ **非对齐项** —— 手机端唯一需要的危险权限是相机（扫码页已处理）；NSD 无需权限，语音走手表系统识别。iOS 那套 `PermissionCenter` 覆盖语音/本地网络，是平台差异 |
| ⑤ | **2 处硬编码文案** | ✅ **已修** —— `HomeScreen.kt` 的 `Add Device` / `Edit Device` 改用 `strings.xml`（中英各补 2 条） |
| ⑥ | **`CommandReceiver.kt` 死桩** | ✅ **已删除**（连同 `CommandReceiverTest.kt` 与 `:app` 注入链）—— 见 §3 |

### 更正：手机端语音不是对齐项

原审计把「手机端语音输入」列为缺口，**依据有误**。回读 iOS 后确认：

- iOS 手机端**没有任何麦克风入口**（`ios/BrewPing` 全目录搜不到 mic / record UI）；
- `SFSpeechRecognizer` 在 iOS 手机端只出现在 `WatchConnectivityManager.transcribeAndForward(audioURL:)`，
  即**转写手表传来的音频**，不是手机自己录音。

Android 侧：手机端 0 处语音（与 iOS 手机端一致），手表端用系统 `RecognizerIntent` 直接识别。
两边「抬手说一句」的用户能力都存在，只是实现位置不同。**在手机端加麦克风按钮属于 Android 独有增强，不是对齐。**

### 实施中新发现并修掉的两个 Demo 缺陷（iOS 的 Demo 后端同样存在）

1. **归档后删不掉**：`DELETE /api/conversations/:id` 只查静态基表，而归档是经 `PATCH` 写进
   `conversationOverrides` 的 → 永远读到 `archived=false` → 一直 409。改为查**合并后**的视图。
2. **内置对话无法真正删除**：删除只从 `createdConversations` 移除，静态的两条会立刻复现 →
   Demo 里的「归档 → 删除」是假的。新增 `deletedConversations` 登记集合。

两者都会让审核员走不完整流程，因此在 Android 侧修掉（**iOS 侧未改动**）。
另把 `/api/agents` 的 `active` 标记改为按当前 Agent **动态**计算，避免静态表里的过期值。


---

## 1. 已对齐（正面对照，含证据）

| 能力 | iOS | Android |
|---|---|---|
| 局域网自动发现 | `BonjourDiscovery.swift`（NWBrowser，`_brewping._tcp`） | `discovery/DesktopDiscoveryManager.kt`（NSD） |
| 手动添加 / 编辑 / 删除设备 | `ContentView.swift` 设备表单 + `DeviceStore.removeDevice` | `HomeScreen.kt` + `HomeViewModel` + `DeviceStore` |
| 扫码配对 | `QRScannerView.swift` | `ui/QrScanScreen.kt` |
| 深链配对 `brewping://` | `PairingURLHandler.swift` | `model/PairingDeepLink.kt` + `MainActivity.onNewIntent` |
| 令牌换取与**安全**存储 | `KeychainStore.swift` → Keychain | `:core/store/PairingStore.kt` → **Keystore AES-256/GCM**（明文 SP 透明迁移） |
| 请求签名（Bearer + Timestamp ±120s + Nonce） | `BrewPingHTTP.swift` | `:core/api/DesktopApiClient.kt` `signed()` |
| 命令提交 / 状态轮询 | `CommandReceiver.submit()/poll()` | `DesktopApiClient.submitMessage()/pollCommandStatus()` |
| **客户端执行阶段（7 态）** | `CommandPhase`: idle / sending / delivered / working / completed / completedRaw / failed | `CommandPhase`：**同名同态**（`HomeUiStateTest.kt:57-63` 有断言） |
| 审批门禁 + 三档 | `ApprovalRequestView.swift` + `ApprovalModeStore.swift` | `HomeScreen` / `ConversationDetailScreen` + `decideApproval()` |
| 多对话（列表 / 详情 / 设置） | `ConversationListView/DetailView.swift` | `ConversationListScreen/DetailScreen.kt` + `ConversationSettingsSheet.kt` |
| 置顶 / 归档 / 恢复 / 删除 | `ConversationListView.swift:82,97,127` | `ConversationStore.setPinned/setArchived` + `ConversationListScreen`「已归档」区块 |
| 工作目录浏览 | `FolderBrowserStore/View.swift` | `ui/FolderBrowserSheet.kt` |
| 模型 / Provider | `ModelCatalog.swift` | `:core` `Device.kt` + `ModelStore.kt` |
| 语言三档（system / zh / en） | `LanguageManager.swift` | `:core/LocalePrefs.kt` + `attachBaseContext` + `recreate()` |
| 主题（Latte 奶白令牌） | `LatteTheme.swift` | `ui/theme/Theme.kt` + `Color.kt` |
| Markdown 转录渲染 | 内嵌 `ConversationDetailView.swift` | 独立 `ui/MarkdownText.kt`（复用性更好） |
| 帮助 / 关于 / 隐私 / 支持 / 商标 | `HelpView.swift`（8 段） | `ui/HelpScreen.kt`（6 段，**缺 2 段**，见 §2） |
| 会话生命周期 API | `DemoBackend` 里模拟 | `:core` `DesktopApiClient.startSession/stopSession` + **UI 已接线** |

---

## 2. Android 缺失 / 未对齐（本次要补的清单）

### ① Demo 模式 —— **完全缺失**（最大缺口）

| | iOS | Android |
|---|---|---|
| 实现 | `DemoBackend.swift`（**656 行 / 27.6 KB**）+ `DemoURLProtocol.swift` | **全仓 0 命中**（`HelpScreen.kt:61` 自己写着「Android 尚未实现 Demo 模式」） |
| 覆盖端点 | `status`、`agents`(+`/:id`/`default`/`models/default`/`workdir`)、`approvals`(+`/:id`/`mode`)、`conversations`(+`/:id`)、`folders`(+`roots`)、`message`(+`/:id`)、`session/start|stop` —— **共 16 个** | — |
| 拦截方式 | `DemoURLProtocol`（注册进 `URLSession`，对 demo 设备短路） | — |
| 入口 | `HelpView.swift:49` `Section("Try it without a computer")` | — |

**为什么这是 P0**：没有 Demo，**没有电脑的用户 / 商店审核员无法走通任何流程**，只能面对空状态。
iOS 的 Demo 是审核与首次体验的关键路径，Android 完全没有对应物。

### ② 帮助页缺 2 段（iOS 8 段 vs Android 6 段）

| iOS `HelpView.swift` 的 Section | Android `HelpScreen.kt` |
|---|---|
| `Language`（:19） | **缺** —— Android 的语言切换在别处（`LocalePrefs` + 应用内切换），但帮助页没有这个入口 |
| `How BrewPing works`（:33） | ✅ `help_how_title` |
| `Set up your computer`（:39） | ✅ `help_setup_title` |
| `Try it without a computer`（:49） | **缺**（随 ① 一起补） |
| `Privacy`（:59） | ✅ `help_privacy_title` |
| `Support`（:70） | ✅ `help_support_title` |
| `Legal`（:78） | ✅ `help_legal_title` |
| `About`（:84） | ✅ `help_about_title` |

### ③ 手机端语音输入 —— Android 只有手表端有

- iOS：手机端具备完整语音转写能力 —— `WatchConnectivityManager.swift` 里 **20 处** `SFSpeechRecognizer`
  （转写手表传回的音频），`PermissionCenter.swift:46,60` 管理语音权限。
- Android：**`:app` 里 0 处语音相关代码**；只有 `:wear` 用系统 `RecognizerIntent`（`WearScreens.kt`）。
- 即：iOS 用户「对着手表说话 → 手机上转写 → 变成命令」这条路径**在 Android 手机上不存在**
  （Wear 端只能走系统识别，没有手机侧的转写/纠错层）。

### ④ 权限被拒后的通用恢复引导

- iOS：`PermissionCenter.swift` —— 语音 / 相机 / 本地网络三项**串行请求**，被拒后给出「打开系统设置」。
- Android：仅 `QrScanScreen.kt` 处理相机权限；**缺少统一的「被拒 → 去设置」组件**。
  （注：NSD 发现不需要危险权限，所以这块差异只在相机/麦克风路径上真实存在。）

### ⑤ 两处硬编码文案（与 iOS 的 i18n 对齐被破坏）

```
Android/app/.../ui/HomeScreen.kt:330   title = "Add Device"     ← 中文界面下仍显示英文
Android/app/.../ui/HomeScreen.kt:357   title = "Edit Device"
```
`values/strings.xml` 里**没有** `add_device` / `edit_device` 键（只有 `add` / `edit` 两个别的用途的键），
说明是漏用资源而非有键未接。iOS 侧对应文案全部走 `L()`。

### ⑥ 文案覆盖度待逐屏核对（低优先）

iOS 237 keys / Android 120 keys，但 i18n 调用点接近（138 vs 124）。除 ⑤ 外**本次探针没有发现其它硬编码**，
但两个数字的差距说明 Android 仍有屏级文案未覆盖 —— 建议后续做一次「按屏核对」。

---

## 3. 上一版结论的更正（避免继续沿用错误判断）

| 上一版（09-19）结论 | 现在的真实情况 |
|---|---|
| ① Android 缺帮助/隐私/支持入口（P0） | ✅ **已实现** `ui/HelpScreen.kt`（10.7 KB，6 段），只差 2 段 |
| ② Android 令牌明文存 SharedPreferences（P0） | ✅ **已修** `:core/store/PairingStore.kt` → Keystore AES-256/GCM，含明文透明迁移 |
| ③ `CommandReceiver.kt` 是「看起来对齐、实际没接」的死桩 | ✅ **已处置（删除）**：`Android/app/.../CommandReceiver.kt` 原为 23 行空壳（648 B），注入链完整（`MainActivity` → `HomeViewModel.Factory` → 构造参数）但**类体内 0 次读取**；真实生命周期一直在 `DesktopRepository`（`submitMessage` / `startCommandPolling` / `decideApproval` + `_commandPhase`，本身已是 `BrewPingApp` 级单例）。已连同 `CommandReceiverTest.kt`（5 例）与注入参数一并删除。**选「删除」而非「收敛」的理由见下** |
| ④ Android 无手表端 | ⚠️ **已变化**：`Android/wear` 已存在（7 个 `.kt`），覆盖 status / approval / voice / conversations 子集，但**未发布** |

### 3.1 为什么是「删除」而不是「把命令生命周期收敛进去」

原审计给的二选一里，② **建立在一个不成立的前提上**：它假定命令生命周期「散在」四个文件里。回读代码后，实际分层是清晰且单向的：

| 层 | 文件 | 职责 |
|---|---|---|
| 传输 | `:core` `DesktopApiClient.kt` | 纯 HTTP：`submitMessage` / `pollCommandStatus` / `decideApproval` |
| **状态机（唯一权威）** | `:app` `DesktopRepository.kt` | `_commandPhase` + `submitMessage` / `startCommandPolling` / `decideApproval` |
| 转接 | `:app` `HomeViewModel.kt` | 只把 `repository.commandPhase` 透出去 + 转发 `decideApproval` |
| 展示 | `:app` `ConversationDetailScreen.kt` | 消费 `commandPhase` 渲染 |

生命周期**早已收敛在 `DesktopRepository`**，只是没叫 `CommandReceiver` 这个名字。

而 iOS 之所以需要 `CommandReceiver`（非 UI 入站通道）+ `CommandSubmitter`（单例引擎），前提是 **WCSession 能在 App 处于后台、界面尚未创建时唤醒进程投递命令**，因此提交逻辑必须与 SwiftUI 生命周期解耦（`CommandReceiver.swift:42-46` 记录了完整故障现象）。**这个前提在 Android 上不存在**：

1. **手表不经手机中转**：`Android/wear` 的 `WearRepository.submit()` → `transport` → **直连桌面端**（`:core` `DirectHttpTransport`）。iOS 是「手表 → 手机 → Mac」，Android 是「手表 → Mac」。
2. **`:app` 没有任何非 UI 入站入口**：`AndroidManifest.xml` 里只有 `MainActivity`（LAUNCHER + `brewping://` 深链），**无 `Service` / `BroadcastReceiver` / WorkManager**，不存在「后台被唤醒投递命令」的通道。
3. **解耦已经存在**：`DesktopRepository` 本身就是 `BrewPingApp` 持有的进程级单例，不受 ViewModel/Compose 生命周期影响 —— 即 iOS 用 `CommandSubmitter.shared` 换来的那条性质，Android 已经有了。

因此 ② 会**为 Android 不存在的问题引入抽象**，把一个已通过 109 例单测的工作链路（`ConversationDetailScreen` → `HomeViewModel` → `DesktopRepository`）重构一遍，收益为零，且会制造「两处都可能拥有命令状态」的新隐患。故取 ① **删除**：认知陷阱的根因是「文件名在模仿 iOS，而 iOS 那个文件赖以存在的约束在 Android 不存在」，删掉即消除。

---

## 4. 对齐实施方案（按优先级，落到文件）

### P0 — 补 Demo 模式（对齐 iOS 的关键路径）

推荐**照搬 iOS 的拦截思路**，但用 Android 原生机制：iOS 用 `URLProtocol`，Android 用 **OkHttp `Interceptor`**。

| 步骤 | 文件 | 说明 |
|---|---|---|
| 1 | 新增 `Android/core/.../demo/DemoBackend.kt` | 移植 iOS `DemoBackend.swift` 的 16 个端点响应（改为 Kotlin + `JSONObject`），保持同一组演示数据（OpenCode/Claude 已装、Codex 未装、一条对话、一条待审批） |
| 2 | 新增 `Android/core/.../demo/DemoInterceptor.kt` | OkHttp `Interceptor`：当前设备 `isDemo` 时短路，直接吐 DemoBackend 的响应；否则 `chain.proceed()` |
| 3 | `:core` `DesktopApiClient.kt` | 允许注入 `Interceptor`（构造参数或 client 工厂），**生产路径默认不带** |
| 4 | `:core` `model/ManagedDevice.kt` + `Device.kt` | 加 `isDemo` 标记（对齐 iOS `ManagedDevice` 的 demo 判定） |
| 5 | `:app` `DeviceStore` / `HomeViewModel` | 「添加演示设备」入口 + 持久化（重启仍在） |
| 6 | `:app` `HelpScreen.kt` + `strings.xml` | 补 `Try it without a computer` 段作为 Demo 入口（同时补 `Language` 段，见 P1） |
| 7 | `:core` 单测 | `DemoBackendTest`：逐端点断言状态码/结构，对齐 iOS 的端点覆盖 |

### P1 — 帮助页补段 + 手机端语音

| # | 项 | 文件 |
|---|---|---|
| ① | Help 补 `Language` 段（应用内切换入口） | `HelpScreen.kt` + `strings.xml`（中英各 +2） |
| ② | 手机端语音输入：用 `SpeechRecognizer` 做本机口述 → 填入消息输入框（对齐 iOS「语音 → 命令」体验，但不依赖手表） | 新增 `:app/.../voice/SpeechInput.kt` + `HomeScreen` 麦克风按钮 + 权限请求 |
| ③ | 权限被拒 → 「去设置」通用引导 | 新增小工具 `:app/.../ui/PermissionRationale.kt`；`QrScanScreen` 与语音入口共用 |

### P2 — 一致性收尾

| # | 项 | 文件 |
|---|---|---|
| ① | 修 2 处硬编码文案 | `HomeScreen.kt:330,357` + `strings.xml` 中英各 +2（`add_device` / `edit_device`） |
| ② | ~~`CommandReceiver.kt` 死桩：**二选一**~~ ✅ **已按「删除」收口** —— 连同 `CommandReceiverTest.kt`（5 例）与 `:app` 注入链一并移除；为何不选「收敛」见 §3.1 | ~~`CommandReceiver.kt`~~ / `HomeViewModel.kt` / `MainActivity.kt` |
| ③ | 文案覆盖度按屏核对 | 全 `:app` UI |

### 反向项（iOS 应看齐 Android，不属本次目标）

- **会话启停 UI**：Android 有（`HomeViewModel.startSession/stopSession` → 已接 UI）；iOS **0 命中**，
  只在 `DemoBackend` 里模拟 —— iOS 反而缺这个入口。
- **设备重命名**：Android 有（`DeviceStore.renameDevice` + `HomeViewModel:196`）；iOS **0 命中**。

### 不建议强行对齐

- **watchOS（9 swift）↔ Wear OS（7 kt）**：平台独占、独立工程。Wear 已覆盖三大功能子集，
  且**未发布**；不应把 iOS 手表的全部能力算作 Android 的「缺失」。
- **本地网络权限弹窗**：Android 的 NSD 不需要危险权限，没有 iOS 那套授权语义 —— 差异合理。

### 三端共有待办（不是 Android 独缺）

**服务端权威 `run.phase`（含 `stalled`）目前只有 Wear 端在消费**：`:core` 已解析成 `CommandRunStatus`
（`model/RunStatus.kt`、`DesktopApiClient.kt:258`），但 **Android 手机端 0 处消费，iOS 手机端同样 0 处**
（两端手机端都用各自的客户端 `CommandPhase`）。若要「抬手就能看到是否卡住」，需要三端一起改。

---

## 5. 一句话结论

**Android 已与 iOS 完成对齐。** 核心链路本就平齐（另有两项反超），本轮补齐了最后一处大缺口
**Demo 模式**（16 端点 + OkHttp 拦截 + 语言化文案 + 31 例单测），并补上帮助页的两段与 2 处硬编码文案。

原审计里列为缺口的「手机端语音输入」「权限恢复引导」经回读 iOS 后确认**不成立**（详见开头的「更正」）。
原唯一遗留 `CommandReceiver.kt` 死桩**已删除**（连同 5 例测试与 `:app` 注入链，理由见 §3.1）——
Android 侧对齐工作至此收口，单测基线 **109 例**（`:core` 67 + `:app` 42，本机实测 0 失败）。
