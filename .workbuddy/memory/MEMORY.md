# BrewPing — 项目长期记忆

跨端工具：让 iPhone / Apple Watch 远程给电脑上的 AI Agent 发指令。
- `ios/` SwiftUI 主 App `BrewPing` + watchOS `BrewPing Watch App`。
- `Sources/` Mac 端 SwiftPM：`BrewPingCore`（共享核心）+ `BrewPingDesktop`（macOS 桌面端）+ `BrewPing`（CLI）。`Sources/BrewPingwinDesktop` 是 Windows 桌面端（Tauri 2 + axum + React）。
- `relay-server/` TS 中继（未接入）、`Android/`、`design/`、`logo/`。

## iOS / Watch 约定

- **Bundle ID** 主 App `com.brewping.ios`、Watch `com.brewping.ios.watchkitapp`（`WKCompanionAppBundleIdentifier` 必须对应）。版本 `1.0.0`。部署目标 iOS 17.0。
- **只做 iPhone，不做 iPad**：`TARGETED_DEVICE_FAMILY = 1`、仅竖屏；Watch 为 `4`。代码/配置/文档都不要引入 iPad 项。
- **网络**：局域网明文 `http://`，不加 ATS 例外；审核表述统一"同一局域网内"。
- **本地化（App 内中英切换）**：① `Text("字面量")` 靠根视图 `.environment(\.locale,…)`；② String 上下文用 `L(_:_:)`（Watch 用 `LW`），读 `currentLocalizedBundle()`。
  - **禁止** `object_setClass(Bundle.main,…)` 覆盖 `localizedString`（实测无效）。
  - `Text(变量)` 必须写 `Text(LocalizedStringKey(变量))`，否则走 verbatim 不翻译。
  - `.strings` 用普通 `PBXFileReference`；产物里是二进制 plist，别用 `wc -l` 判断。
  - Watch 语言不自建，随 WCSession `applicationContext` 的 `"language"` 同步。
  - **🚨 译文 `%@` 个数必须与代码实参完全相等、顺序不可调换** —— 多一个会 `EXC_BAD_ACCESS`。中文语序不同就改措辞，别重排占位符。
  - 改完必跑 `python3 ios/Scripts/check_localization.py`（退出码 1 = 有会崩的问题）。
- **🚨 新增 Swift 文件必须登记 `ios/BrewPing.xcodeproj/project.pbxproj`**（显式 PBXFileReference，非文件夹同步）。**四处缺一不可**：`PBXBuildFile` / `PBXFileReference` / 所属 `PBXGroup.children` / target `Sources`。ID 24 位十六进制，风格 `AA00000100000000NNNNNNNN`。**验**：`grep -c "<文件名>" project.pbxproj` ≥ 4。
- **配对**：Mac 菜单栏 Show Pairing Code 出 6 位码 + 二维码（`brewping://pair?host=&port=&deviceId=&name=&osType=&code=`）。iOS 两条路径共用该格式：① 系统相机/微信扫 → 唤起 App → `PairingURLHandler.handle` → `consumePairAction`（自动配对）；② App 内 `QRScannerView`（AVCaptureSession）→ 填表单由用户确认。`NSCameraUsageDescription` 已加，模拟器无相机走降级分支。
- **鉴权**：Bearer token + `X-BrewPing-Timestamp`(±120s) + `X-BrewPing-Nonce`。token iOS 存 Keychain（`DeviceAuth`，键 `deviceToken.<device.id>`），Mac 存 `~/.brewping/pairing.json`(0600)。
- **Demo 模式**：`DemoURLProtocol` 拦截 `demo.brewping.local`；`ManagedDevice.isDemo` 靠 host 判定（故意不加 Codable 字段）。
- **日志**：iOS `BrewPingLog`、Watch `WatchLog`，禁止裸 `print`；可能含用户内容的值标 `privacy: .private`。
- **隐私清单**：主 App `UserDefaults / CA92.1`；Watch `FileTimestamp / C617.1`。用新 Required Reason API 必须同步更新。

## 授权确认（危险命令拦截）

- 三档 `safe`（默认）/`askAll`/`auto`；**作用域 = 全局**（刻意不做 per-agent；与"模型 per-agent"相反，别搞混）。存 `~/.brewping/approval.json`(0600，含 alwaysAllow 白名单)。
- **检测点 = 命令进入 agent 之前**（`ApprovalGate.shared.check`）。命中 → 挂起不写 PTY + 返回 `pending_approval`。危险模式本地内置正则（`DangerPattern.swift`），**绝不信任 agent 自报**；每类带稳定 `code`。
- **超时默认拒绝**：pending TTL 300s 过期即作废。缺席 ≠ 放行。
- API：`GET/POST /api/approvals/mode`、`GET /api/approvals`、`POST /api/approvals/:id`（`{"action":"approve"|"deny"|"always_approve"}`）。
- iOS UI：`sessionCard`（Active Agent）里紧跟模型入口之后（`approvalModeRow`），有设备即显示；`HelpView` 保留一份。Demo 设备同构支持。
- 局限：opencode 是黑盒 TUI，只能拦"用户发的消息入口"，拦不到 agent 中途自推的 shell 命令。

## 模型切换

- 数据源**只用** Mac 已有接口：`GET /api/agents/<agentId>/models`（`providers[].models[]` 两层嵌套）、`POST /api/agents/models/default`。底层 `AgentConfigDiscovery` 读真实配置文件。**不要新增第二个配置源**。
- **模型 per-Agent**；**授权 per-对话**；**Agent per-对话**（创建时绑定）。三者作用域不同，别搞混。
- iOS 侧 `ModelStore.shared` 统一持有；Watch 经 WCSession `knownModels`/`activeModelID` 下发，`switchModel` 回传。当前模型的判定顺序：`preferredModelId` → 本地记录 → `activeModelId` → 第一个。
- Watch 侧硬约束：**切 Agent 必须"先同步本地权威值、再推送"**，且推送 context 带 `modelsAgent` 归属；`applyContext` 要有 `pendingAgentSwitch` 保护（超 5s 放弃）。`refreshAgents()` 不在 5s 轮询里 → 外部切 Agent 后要用 `watchDidSwitchAgent` 通知立即刷新，否则 "Default" 标记永不变。
- 状态轮询间隔 **5 秒**（不是 2 秒）。

## macOS 桌面端（Sources/BrewPingDesktop + Sources/App）

- **形态**：窗口化 App（`Window("BrewPing", id:"main")` + `.windowStyle(.hiddenTitleBar)`）承载全部交互 + `MenuBarExtra`（`.window`）承担 Windows 托盘职责。**不自绘窗口控制按钮**（红绿灯浮在 28pt 拖拽条上）；`applicationShouldTerminateAfterLastWindowClosed = false`；`preferredColorScheme(.light)`。
- **架构宪法：`Sources/App/DesktopCommands.swift` 是桌面 UI 唯一入口**（= Windows `#[tauri::command]` + `api/tauri.ts` 的等价物）。函数名 = Tauri 命令名驼峰化，DTO 与 `src/api/types.ts` 逐字段对齐。UI **不得**直接碰 `ConversationStore` / `ApprovalGate` / `PairingStore` 等内部类型 —— 需要新能力就在命令面加一个函数（并在必要时放宽对应成员的可见性）。
  - 执行类命令（`sendCommand` / `checkEnvironment` / 安装任务）在命令面里切后台队列（`offMain` / `withCheckedContinuation`），**绝不阻塞主线程**。
- **单一执行路径**：`ConversationCommandService`（submit / decide）是唯一实现，HTTP / 桌面 / Watch 共用；`Source` 只改终端回显前缀。`CommandRouter.shared` 是全局唯一实例（**别**再 `CommandRouter()` 起新队列）。
- **`SubmitSuccess.conversationID`** 是桌面 `send_command` 的返回值（不是 `sessionID`，那是 agent 会话 ID）。
- **i18n**：`DesktopStrings.swift` 由 `Sources/BrewPingwinDesktop/src/i18n/locales.ts` **机械生成**（`LKey` + zh/en，148 key 严格对齐）。**改文案必须两端同批**。`LangMode`(system/zh/en) 存 UserDefaults `brewping.langMode`；不重启、不依赖系统语言。
- **主题**：`LatteTheme.swift` 的 HSL 令牌逐条照搬 `app.css` 的 `:root`（`Color.latte(h:s:l:)` 自实现 HSL→sRGB）。改样式先改令牌，别在视图里写裸色值。
- **布局常数**：`LatteMetrics`（控件高 36 / 侧栏 208 / 内容列 736 / gutter 12→16）对应 Windows 的 Tailwind 类。**主区宽度**经 `EnvironmentValues.viewportWidth` 注入（`DesktopRootView` 里唯一一个 GeometryReader，只包主区）—— 会话内容列靠它算 `min(736, 可用)` 与断点留白；**别在会话内部逐处用 GeometryReader**（会吃掉 VStack 剩余高度，把 composer 顶飞）。
- **🚨 SwiftUI 输入框（NSTextView 包装）两坑**（2026-09-13 修）：
  1. **必须用 `NSTextView.scrollableTextView()` 构造**。手写 `NSScrollView() + NSTextView(frame: .zero)` 时 documentView 的 frame 是 `.zero`，AppKit 不替它布局 → 文本框不可见也不可点击（表现为"点不进、打不了字"）。
  2. **`.frame(minHeight:maxHeight:)` 是弹性框不是钳制框**：父级有余量就顶到 maxHeight 并把内容垂直居中 → 输入框永远最大高、文字浮中间。高度范围要钳在 `sizeThatFits` 里，外壳只留 padding + `.fixedSize(horizontal: false, vertical: true)`。
     - 超出上限后的滚动：`textView.frame.height` 用**未钳制**的自然高度（document 比 clip 高才滚得起来）。
     - Enter 发送走 `NSTextViewDelegate.textView(_:doCommandBy:)`，**不要**覆写 `keyDown`（前者组字期间不触发，不吞中文候选）。
     - Windows textarea 是 border-box：`min-h-[72px] max-h-44` **包含** `pt-3.5`(14)+`pb-1.5`(6) → 内容区 52…156，水平 16 走 SwiftUI padding（`textContainerInset` 只能给上下对称值）。
- **禁用**：`osascript` System Events 自动化本机未授权（见"已知坑"）。
- 改完必须 `swift build --disable-sandbox`；`swift test` 无 target（Mac 端暂无 XCTest）。

## Windows 桌面端（Sources/BrewPingwinDesktop，Tauri 2 + axum 0.8）

- **HTTP 错误体必须永远是 JSON**（`TC-HT-26`）→ 新增 query 参数必须声明 `Option<String>` 再手工解析（强类型反序列化失败会返回 400 纯文本）。
- 偏好落盘 `~/.brewping/*.json`，一个偏好一个文件；`Stored` 必须带 `#[serde(default)]`；测试用 `with_path(temp)` 隔离。
- **⚠️ Agent 执行有两处 `Command::new`**（`http_server.rs` 手机端 / `lib.rs` 桌面端）→ 执行相关改动必须同批改两处。
- `opencode` 在 Windows 端是 **stub**（只 append 文本，从不 spawn）→ 实现真执行需先做 ConPTY（独立工程）。设 workdir 对 opencode 明确 400。
- **⚠️ cargo test 二进制绝不能链入 tauri GUI 类型**（STATUS_ENTRYPOINT_NOT_FOUND）→ `EventSink` 模式：`pub type EventSink = Arc<dyn Fn(&str, serde_json::Value) + Send + Sync>`。
- **⚠️ 改 `src-tauri/capabilities/*.json` 后必须 `cargo clean -p brewping-desktop`**，否则 ACL 仍旧 → 只有自绘标题栏按钮没反应。窗口类 IPC 前端必须 `.catch` 记录错误。
- **⚠️ Windows 端"重启"必须走 `npm run tauri dev`**（PowerShell 后台）；直接跑 `target/release/*.exe` 内嵌的是编译时打包的旧 dist。Git Bash 里 `npm` 会解析成 WSL 版 → 必须用 PowerShell。带 `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--no-sandbox"`。
- 鉴权 `auth_middleware` 用 `route_layer` 作用全表（新增路由自动受保护）；公开白名单只有 `POST /api/pair` 与 `GET /api/status`。`authorize` 对 **GET 只校验 Bearer、免 nonce**。
- 新增/改端点**必须同步 `ios/BrewPing/DemoBackend.swift` 的 switch**；`DemoURLProtocol` 只传 `url.path`，query 要显式传 `url.query`。
- **多对话管理**：`conversation_store.rs`（两层分离）+ `command_runner.rs`（唯一执行路径 + 唯一命令状态写入点）+ `conversation_api.rs`（6 端点）。iOS 兼容：`/api/status.session` = active 对话；HTTP `/api/status` 无 `activeConversationId`（只有 Tauri `get_status` 有），属正常。
- **对话级设置语义**：**Agent** 创建时绑定（composer 里切 Agent = 开新草稿）；**模型** = 对话覆盖（`model_override` + `model_provider_override` 成对）> Agent 全局偏好 > 配置 active；**授权** = 对话档位（创建时随草稿固化）> 全局 approval.json。草稿手选**不写全局默认**。
- **获取文件夹**：`folder_browser.rs` + `workdir_prefs.rs` + `folder_api.rs`（3 端点）。**安全铁律**：UNC 在 realpath 前拒绝（SMB 凭据外泄）；白名单作用在 realpath **之后**（junction 防绕过）；`can_read_dir` 只探测目录句柄不读内容（OneDrive 防下载）；盘符用 `GetLogicalDrives` 枚举，**禁止 A–Z 探测**。
- macOS 侧对应实现：`Sources/App/FolderBrowser.swift`（根 = `/` + `/Volumes/*`，realpath 用 `resolvingSymlinksInPath`，`//server/share` 在 realpath 前拒绝，契约同为 camelCase）。

## 已知坑（通用）

- **轮询与 scenePhase**：起停只能用 `!isInBackground`；用 `== .active` 会在系统弹窗（`.inactive`）时 return → 界面卡在"离线"。
- **URLProtocol 读请求体**：URLSession 会把 `httpBody` 转成 `httpBodyStream`，必须 fallback 读 stream。
- **OSLog 插值**：`privacy:` 参数是 `@autoclosure`，实例方法里插 `self` 属性会报 "implicit use of 'self' in closure" → 先取局部变量。
- **Swift：async 函数的返回值必须显式 `return await ...`**（单表达式隐式 return 带 await 会报错）。Void 可省。
- **`build-device/**/Info.plist` 是过期产物**（缺 Bonjour/语音/图标字段），不能作为合规判断依据。
- **Watch 录音**不用 `WKExtendedRuntimeSession` → **不需要** `UIBackgroundModes`（别"补"上）。
- **watchOS 别用很矮的 `TabView(.page)` 承载卡片**：卡片文字会渲染成空白。改用「左右箭头 + 中间当前值」的 HStack，并**同时补滑动手势**（`.simultaneousGesture(DragGesture(minimumDistance: 20))`，判定 `abs(dx) > 30 && abs(dx) > abs(dy)`），否则"看起来能滑、实际滑不动"。
- **Windows 路径四坑**：`canonicalize` 必返回 `\\?\` verbatim → 用 `dunce::simplified`；「隐藏」要同时认点号与 `FILE_ATTRIBUTE_HIDDEN`；枚举盘符禁用 A–Z 探测；`is_symlink()` 对 junction 也返回 true。Windows 用户态**没有**查询进程 cwd 的 API。
- **客户端"设备存在" ≠ "可通信"**：依赖鉴权的 UI 要用 `DeviceAuth.isPaired(device)` 判定，而不是 `hasDevice`。
- **⚠️ 端口 8787 常被旧打包进程占用**：`build/BrewPing Desktop.app` 若常驻后台，新实例 HTTP server 起不来，`curl` 会**静默打到旧进程** → 表现为"新路由 404 / 新逻辑不生效"。排查 `lsof -nP -iTCP:8787 -sTCP:LISTEN`，看 PID 对应的可执行文件路径。
- **⚠️ 本机 `osascript` 无辅助访问权限**（`-25211`）→ 不能用 System Events 点击/置顶做 UI 自动化。
  - **UI 验收的可行路径**：① 小 Swift 脚本用 `CGWindowListCopyWindowInfo` 拿 `CGWindowID`；② `screencapture -x -o -l <id> out.png` 只截该窗口；③ 要到达非默认状态就在启动处临时读一个 `ProcessInfo.processInfo.environment[...]` 开关（备份原文件 → 改 → build → 带 env 启动 → 截图 → 还原）。
- **⚠️ `build-app.sh` 必须全量构建，不能用 `--target`**：`--target` 只编该 target，依赖库 `BrewPingCore` 不重编 → 改完 `Sources/App/**` 打出的 .app 仍是旧逻辑。已改为 `swift build -c release --disable-sandbox`。release 与 debug 是**两套独立缓存**。

## 上架配置 / 占位值

`ios/BrewPing/BrewPingConfig.swift`：
- `privacyPolicyURLString` = `https://banmu123.github.io/BrewPing/privacy.html` ✅（源文件 `docs/privacy.html`，GitHub Pages 源 = main 分支 `/docs`，push 即重发；App Store Connect 填同一地址）
- `supportEmail` = `czkbanmu@163.com` ✅
- `macAppName` = `BrewPing Desktop`；`DEVELOPMENT_TEAM` = `TGA82PM3DZ`（待确认是本人）
- **仍待办**：用最新代码重新 Archive（`build-device/` 是旧产物）。
- ⚠️ Pages 源是 `/docs` 整目录 → 该目录下其他文件（如审核报告 md）也会被服务。

## 相关文档

- `docs/AppStore-PreSubmission-Review.md` —— 上架前审核报告 + 修复落地记录。
- `docs/BrewPing-Windows端多对话管理实现方案.md`、`.workbuddy/outputs/BrewPing-获取文件夹-Windows落地方案.md`。
- `README.md` —— 配对流程、Demo 说明、API 鉴权、Trademarks 免责声明。
