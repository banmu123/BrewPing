# Android / iOS 功能对齐审查

> 以 **iOS 为基准**比对 Android。基线 `2760047`（2026-09-19）。
> 方法：双端模块清单 + 同一组能力探针打两端 + 关键差异点逐个回读代码坐实。
> 未验证的推断都标注「待确认」，不臆断。

## 0. 规模概览

| | iOS | Android |
|---|---|---|
| 主源码 | 27 个 `.swift` | 26 个 `.kt` |
| 手表端 | **9 个 `.swift`（Watch App）** | 无 |
| 单测 | — | 6 个 `.kt`（Jetpack 单测） |
| 最大文件 | `ContentView.swift` 1551 | `HomeScreen.kt` 1031 |

**结论先行**：核心链路（配对、发现、多对话、命令、审批、工作目录、模型、语言）**Android 基本对齐**；差距集中在 **Demo 模式、帮助/隐私/支持入口、令牌存储安全性、命令引擎的架构收敛**，以及 iOS 独占的手表/语音。

---

## 一、两端均已实现（对齐清单）

| 模块 | iOS | Android |
|---|---|---|
| 局域网自动发现 | `BonjourDiscovery.swift`（NWBrowser，`_brewping._tcp`） | `discovery/DesktopDiscoveryManager.kt`（NSD） |
| 手动添加设备（IP/端口/名称） | `ContentView.swift` 设备表单 + `ManagedDevice.swift` | `HomeScreen.kt` + `HomeViewModel.kt` + `model/ManagedDevice.kt` |
| 扫码配对 | `QRScannerView.swift` | `ui/QrScanScreen.kt` |
| 深链配对（`brewping://`） | `PairingURLHandler.swift` | `model/PairingDeepLink.kt` |
| 配对令牌换取与持久化 | `KeychainStore.swift` + `BrewPingHTTP.swift` | `store/PairingStore.kt` |
| 请求签名（Bearer + Timestamp ±120s + Nonce） | `BrewPingHTTP.swift` | `api/DesktopApiClient.kt` `signed()` |
| 命令提交 | `CommandReceiver.swift` `submit()` → `POST /api/message` | `DesktopApiClient.kt` `submitMessage()` → 同端点 |
| 命令状态轮询 | `CommandReceiver.swift` `poll()` → `GET /api/message/:id` | `DesktopApiClient.kt` `pollCommandStatus()` → 同端点 |
| 审批门禁 | `ApprovalRequestView.swift` + `decide()` → `POST /api/approvals/:id` | `HomeScreen.kt` / `ConversationDetailScreen.kt` + `decideApproval()` → 同端点 |
| 多对话（列表 / 详情 / 归档） | `ConversationStore.swift` + `ConversationListView/DetailView.swift` | `store/ConversationStore.kt` + `ConversationListScreen/DetailScreen.kt` |
| 对话设置（重命名 / 工作目录 / 审批模式 / 模型） | `ConversationDetailView.swift` | `ui/ConversationSettingsSheet.kt` |
| 工作目录浏览 | `FolderBrowserStore.swift` + `FolderBrowserView.swift` | `ui/FolderBrowserSheet.kt` |
| 模型偏好 | `ModelCatalog.swift`（507） | `store/ModelStore.kt`（203） |
| 语言三档（system / zh / en）App 内切换 | `LanguageManager.swift` | `LocalePrefs.kt`（★ 已对齐，见 §三.4） |
| 中英文案 | `en.lproj` / `zh-Hans.lproj` | `values` / `values-zh`（各 101 条） |
| 设备持久化 | `DeviceStore.swift` | `store/DeviceStore.kt` |
| 主题（Latte 奶白） | `LatteTheme.swift` | `ui/theme/Theme.kt` + `Color.kt` |
| Markdown 渲染 | 内嵌于 `ConversationDetailView.swift`（8 处） | 独立组件 `ui/MarkdownText.kt`（197） |

---

## 二、Android 缺失或实现不完整（以 iOS 为基准）

### ① Demo 模式 —— **完全缺失**（影响最大）

| | iOS | Android |
|---|---|---|
| 实现 | `DemoBackend.swift`（655）+ `DemoURLProtocol.swift`（77），另有 Demo 分支散在 `BrewPingHTTP.swift`、`ContentView.swift`、`DeviceStore.swift`、`ManagedDevice.swift` 共 **6 个文件** | **全仓零命中** |

iOS 的 `HelpView.swift` 明确写着「Add a Demo device to walk through the whole flow — no computer and no hardware needed」—— 这是**为审核员/新用户准备的零门槛体验路径**。Android 完全没有，意味着：审核员没有电脑时无法走通流程；新用户装完只能面对空状态。

### ② 帮助 / 关于 / 隐私政策 / 支持 / 商标免责 —— **完全缺失**

| iOS `HelpView.swift`（108 行，8 个 Section） | Android |
|---|---|
| 语言切换、How it works、Set up your computer、Try Demo、Privacy（政策链接）、Support（邮箱）、Legal（商标免责）、About（版本） | **无任何对应 UI**；`values/strings.xml` 101 条文案里也没有 help / privacy / support / about 相关条目 |

注：`DesktopApiClient.kt` 里出现过 "support"/"设置" 字样，但那只是 API 字段与对话设置，**不是帮助页**。

### ③ 配对令牌存储安全性 —— **实现层级偏低**

- iOS：`KeychainStore.swift`（64）→ **Keychain**（系统级加密、卸载才丢）
- Android：`store/PairingStore.kt`（37）→ **`SharedPreferences` 明文**

Android 侧注释自己写明了「每台设备一个长期 token」「卸载 App 才会丢失」，但用的是明文 `MODE_PRIVATE` 的 SP。Android 有 `EncryptedSharedPreferences` / Keystore 可直接替换，**不需要引入新依赖**。

### ④ 命令引擎的架构 —— **Android 分散且带一个死桩**

- iOS：`CommandReceiver.swift`（**467**）是**单一命令引擎** —— `submit()` / `poll()` / `decide()` / `cancelPolling()` / `localizedReasons()` / `fromWatch` 标记，且有一处 P0 修复痕迹（decision 后的轮询必须挂在可取消的 `pollTask` 上）。
- Android：等价逻辑**分散**在 `DesktopApiClient.kt`(833) + `HomeViewModel.kt`(645) + `ConversationDetailScreen.kt`(739) + `repository/DesktopRepository.kt`(411)。
- 而 `CommandReceiver.kt` 只有 **23 行**（一个把字符串转发给回调的空壳），注释写着「matches iOS CommandReceiver」—— 但实测：
  - `MainActivity.kt` 注入 1 次、`HomeViewModel.kt` 持有 3 次、**生产代码从未调用 `.receive()`**
  - 唯一使用者是 `CommandReceiverTest.kt`（15 次）

  → 这是一个**让人误以为已对齐的陷阱**：按文件名看两端都有 `CommandReceiver`，实际 Android 那个从未接线。

### ⑤ 语音输入 / 手表 —— iOS 独占（平台差异）

- iOS：`WatchConnectivityManager.swift`（887）+ Watch App 9 个文件 + `WatchAudioRecorder.swift`，支持手表录音 → 手机转写 → 命令下发。
- Android：无 Wear OS 模块。

**建议**：不强行对齐（Wear OS 是独立工程），但 Android 可用系统 `SpeechRecognizer` 做**本机语音输入**作为能力补齐（见 §四 P2）。

### ⑥ 权限引导 —— 机制不同，Android 缺"被拒后去设置"的通用路径

- iOS：`PermissionCenter.swift`（208）—— 语音 / 相机 / 本地网络三项，**串行请求**（避免连弹）、被拒后提供「打开系统设置」。
- Android：仅 `QrScanScreen.kt` 处理相机；NSD 发现不需要危险权限，所以差异**基本合理**。但缺少一个统一的「权限被拒 → 引导去设置」组件。

---

## 三、两端存在差异的地方（交互 / 逻辑）

1. **命令生命周期的归属**：iOS 集中在 `CommandReceiver`；Android 散在 ViewModel/Screen/Repository（见 §二④）。
2. **轮询的取消语义**：iOS 用可取消的 `Task`（`pollTask`，并已修过"decision 后轮询脱离句柄"的 P0）；Android 用 `while(true) + delay` 的协程循环。**待确认**：Android 在页面离开/切换对话时是否都有等价的取消语义（先前审计发现 `HomeViewModel` 的模型轮询在离开页面后仍靠空转 `continue`，未真正退出）。
3. **语言切换的生效方式**：iOS 立即重渲染；Android 走 `attachBaseContext` 包 Context + `activity.recreate()`——**会重建 Activity**（有短暂白屏/状态重建，行为可感知）。
4. **Markdown 组件归属**：Android 有独立 `MarkdownText.kt`；iOS 内嵌在 `ConversationDetailView.swift` 里 —— 功能都有，但复用性/一致性不同（iOS 其他页面无法复用）。
5. **设备模型字段**：`ManagedDevice.swift`(100) vs `ManagedDevice.kt`(56)。Android 侧字段更少，且先前审计发现 `displayName` / `baseUrl()` 在 Android 是**零引用的死代码** → 模型能力实际不一致。
6. **主机类型（Mac / Windows 识别）**：iOS 用 `DeviceOSType`（从 Bonjour TXT 的 `platform` 读）；Android `model/Device.kt` 有相关字段，但先前审计判定其中若干为「契约镜像字段，只解析不读」。
7. **错误文案本地化机制**：iOS 走 `L()` / `localizedReasons()`（代码内字符串）；Android 走 `strings.xml` 资源。**待确认**两者错误覆盖是否一一对应。
8. **发现端重扫策略**：两端都无缓存（每次全量重扫）；macOS 桌面端反而有 60s 缓存 —— 这是三端不一致的点，非双端差异。

---

## 四、对齐情况总结与处理优先级

### P0 — 上架 / 合规 / 安全（建议最先做）

| # | 项 | 动作 | 涉及文件 |
|---|---|---|---|
| 1 | **Android 缺帮助/隐私/支持入口** | 新增 Help/About 页：使用说明、隐私政策链接（复用 `https://banmu123.github.io/BrewPing/privacy.html`）、支持邮箱、商标免责、版本。Play 商店与合规都要求可达 | 新增 `Android/.../ui/HelpScreen.kt` + 中英 `strings.xml` |
| 2 | **令牌明文存 SP** | 换 `EncryptedSharedPreferences`（AndroidX Security，无新第三方依赖） | `store/PairingStore.kt` |

### P1 — 体验 / 审核友好（紧随 P0）

| # | 项 | 动作 | 涉及文件 |
|---|---|---|---|
| 3 | **Android 缺 Demo 模式** | 对齐 iOS：加 Demo 设备，让无电脑用户/审核员走通全流程 | 新增 `Android/.../demo/DemoBackend.kt` 等（对齐 `ios/BrewPing/DemoBackend.swift`） |
| 4 | **CommandReceiver 死桩** | 二选一：①删除（连同 `CommandReceiverTest.kt`）；②把命令生命周期收敛进它。**不要留着不接线** —— 它正是"看起来对齐、实际没接"的典型 | `CommandReceiver.kt` / `HomeViewModel.kt` / `MainActivity.kt` |

### P2 — 一致性 / 增强（有余力再做）

| # | 项 | 动作 |
|---|---|---|
| 5 | Android 本机语音输入（替代手表方案） | 用 `SpeechRecognizer`，对齐 iOS「语音 → 命令」的体验 |
| 6 | 设备模型与 Markdown 组件对齐 | `ManagedDevice.kt` 补齐字段（并清理零引用的 `displayName`/`baseUrl()`）；Markdown 抽成两端都可复用的组件 |
| 7 | Android 权限被拒后的「去设置」通用引导 | 抽一个小组件，对齐 iOS `PermissionCenter` 的恢复路径 |
| 8 | 错误文案覆盖度双向核对 | 建一份错误码 → 中英文案对照，确保两端一致 |

### 不建议强行对齐的项

- **Watch / Wear OS**：平台独占，属独立工程，不应算作 Android 的"缺失"。
- **本地网络权限弹窗**：Android NSD 无需危险权限，没有 iOS 那套授权语义，差异合理。

---

## 五、一句话结论

**Android 在"能干什么"上基本追平 iOS，差距在"配套的门面"上** —— Demo 体验、帮助/隐私/支持入口、令牌安全存储这三项是真正的短板（其中帮助/隐私涉及合规，优先级最高）；另外 `CommandReceiver.kt` 这个 23 行的空壳是当前最大的**认知陷阱**，建议尽快处理掉。
