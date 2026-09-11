# BrewPing — 项目长期记忆

## 项目概况

跨端工具：让 iPhone / Apple Watch 远程给电脑上的 AI Agent 发指令。
- `ios/` —— SwiftUI 主 App（`BrewPing`）+ watchOS App（`BrewPing Watch App`）。
- `Sources/` —— Mac 端 SwiftPM 包（`BrewPingCore` / `BrewPingDesktop`，菜单栏 App）。
- `relay-server/` —— TS 中继服务（iOS 端尚未接入）。
- `Android/`、`design/`、`logo/` —— 其他端与设计稿。

## 关键约定（务必遵守）

- **Bundle ID**：主 App `com.brewping.ios`，Watch `com.brewping.ios.watchkitapp`。二者的 `WKCompanionAppBundleIdentifier` 必须对应主 App。
  - 历史：旧值 `local.brewping.app`，2026-09-11 起已改为 `com.brewping.ios`（提交前确认 App Store Connect 里已建好该 ID）。
- **版本**：`CFBundleShortVersionString` = `1.0.0`。
- **部署目标**：iOS/iOS 模拟器 17.0 起（用到 `.onChange` 双参数、`NavigationStack`）。
- **设备族**：**只做 iPhone，不做 iPad**（2026-09-11 用户明确确认的定位）。iOS target `TARGETED_DEVICE_FAMILY = 1`、仅竖屏；Watch 为 `4`。因为是 iPhone-only，所以**不需要** iPad 方向声明、布局适配或 iPad 截图。代码、配置、文档里都不要引入 iPad 相关项。
- **网络**：局域网明文 `http://`，不引入 ATS 例外；Apple 审核元数据统一表述为"同一局域网内"。
- **本地化（App 内中英切换）**：两条通道缺一不可 —— ① SwiftUI `Text("字面量")` 靠根视图 `.environment(\.locale, ...)`；② String 上下文用全局函数 `L(_:_:)`（Watch 端 `LW(_:_:)`），读 `currentLocalizedBundle()` 的 `.lproj` 快照。
  - **禁止**用 `object_setClass(Bundle.main, ...)` 覆盖 `localizedString` 来"透明"接管 SwiftUI —— 实测无效（已删除该实现）。
  - `Text(变量)` 必须显式 `Text(LocalizedStringKey(变量))`，否则走 verbatim 不翻译。
  - `Localizable.strings` 在 pbxproj 里用**普通 PBXFileReference**（本工程无 `PBXVariantGroup` section）；`knownRegions` 含 `"zh-Hans"`。
  - 产物里 `.strings` 是**二进制 plist**，别用 `wc -l` 判断是否打包成功。
  - Watch 语言不自建设置，由 iPhone 经 WCSession `applicationContext` 的 `"language"` 键同步。
  - **🚨 译文的 `%@` 个数必须与代码插值/实参个数完全相等，且顺序不可调换** —— 多一个 `%@` 会去读不存在的实参，直接 `EXC_BAD_ACCESS (code=1, address=0x1)`（2026-09-11 实际踩到：未配对卡片中文译文多写一个 `%@`）。中文语序与英文不同时**改措辞**，不要重排占位符。
  - 改完 `Localizable.strings` 必跑 `python3 ios/Scripts/check_localization.py`（退出码 1 = 有会崩的问题）。
- **模型切换**（iPhone + Watch）：数据源**只用** Mac 端已有接口 —— `GET /api/agents/<agentId>/models`（返回 `providers[].models[]` 两层嵌套）与 `POST /api/agents/models/default`（`{"agentId","modelId"}`）。底层是 `Sources/Agents/AgentConfigDiscovery` 读各 Agent 真实配置文件。**不要新增第二个配置源**。
  - iOS 侧统一由 `ModelStore.shared`（`ios/BrewPing/ModelCatalog.swift`）持有；Watch 不直连 Mac，经 `WatchConnectivityManager.knownModels` / `activeModelID` 随 `pushStatus` 与 `requestStatus` reply 下发，手表用 `switchModel` 消息回传意图。
  - **当前模型的判定顺序：`preferredModelId` → 本地记录 → `activeModelId` → 第一个**。本地记录必须排在 `active` 之前，否则"下次进来保持上次选择"会被配置文件里的 active 盖掉。
  - 入口显示条件：`models.count > 1`（0 个或 1 个都隐藏）；主机没实现该接口时 `canSwitch` 也必须是 false（见 `ModelStore.unsupported`）。
  - **iOS"当前 Agent"取自 `/api/status` 的 `defaultAgent`**，**不是** `session.agent`。`session` 描述的是"正在跑的会话"，主机切换默认 Agent 时会把会话置空（Windows 端就是这样），用它会导致"切了默认 Agent 界面纹丝不动"。取值顺序：`defaultAgent` → `session.agent` → `opencode`。
  - **会话启停按钮的门控是个例外**：它只能看 `sessionState == .running || runningSessionAgentID == "opencode"`，**不能**跟着 `defaultAgent` 走 —— Windows 端发命令要求先有会话，用默认 Agent 判断会导致（默认是 headless 时）按钮消失、人被困死。
- **主机类型（`osType`）不能靠猜**：`brewping://pair?...` 深链必须带 `osType`（Mac 发 `mac`、Windows 发 `windows`），mDNS 的 TXT 记录带 `platform`（Mac `macOS` / Windows `windows`）。统一由 iOS `DeviceOSType.parse(_:)` 归一化，**缺失或未知一律回落 `.mac`**（老版本兼容）。
  - `NetServiceDelegate` 回调**不携带 TXT**，所以 Bonjour 路径要在浏览阶段（`NWBrowser.Result.metadata` → `NWTXTRecord.get("platform")`）先把类型存起来，解析完成时再取用。
  - 扫到**已存在**的同 host:port 设备时，要用新的 osType **自愈式更新**（否则早期存成 Mac 的记录永远修不好）。
- **授权确认（危险命令拦截）**：三档模式 `safe`（默认）/`askAll`/`auto`，存 `~/.brewping/approval.json`(0600，含 alwaysAllow 白名单)。
  - **作用域 = 全局（所有 agent 共用一份档位）**，刻意不做 per-agent。理由：危险检测点统一在"命令进入 agent 之前"，作用对象是这条遥控通道而非某个 agent；且安全设置全局更保守、不会漏配。用户 2026-09-11 明确确认保持全局。**注意与模型切换相反**——模型是 per-agent 存的（`AgentManager.setDefaultModel(_:for:)`），别搞混。
  - **检测点是「命令进入 agent 之前」**：`HTTPAPI.messageResponse` 入口过 `ApprovalGate.shared.check(text:)`。safe 命中危险 → 挂起（不写 PTY）+ 返回 `pending_approval`；未命中/auto → 走 `executeCommand`。
  - **危险模式本地内置**（`Sources/App/DangerPattern.swift` 正则），**绝不信任 agent 自报**。每类带稳定 `code`（iOS 据此本地化文案）+ `detail`。
  - 受限于 opencode 是黑盒 TUI，只能拦"用户发的消息入口"，拦不到"agent 会话中途自行推断出的 shell 命令"——这是当前架构下 L3 的诚实简化版。
  - API：`GET/POST /api/approvals/mode`、`GET /api/approvals`、`POST /api/approvals/:id`（`{"action":"approve"|"deny"|"always_approve"}`）。
  - **超时默认拒绝**：Mac 端 pending TTL 300s 过期即 prune（不执行）。缺席不表态 ≠ 默认放行。
  - iOS 侧 `CommandSubmitter.pendingApproval` + `ApprovalRequestView` 弹窗；`ApprovalModeStore` 读写模式。
  - **模式切换的 UI 位置**：主入口在**会话页 `sessionCard`（Active Agent）里紧跟模型入口 `modelRow` 之后**（`ContentView.approvalModeRow`），有设备即显示（不像 `modelRow` 需要 `canSwitch`）；`HelpView` 里保留一份作为详细设置。用户明确要求"显眼、放在选择模型下面"。
  - Demo 设备也支持同构 approvals（`DemoBackend` 内联简化危险检测），`ApprovalModeStore` 不排除 Demo，模拟器零硬件即可演示弹窗与模式切换。
- **配对**：Mac 端菜单栏「Show Pairing Code」显示 6 位码 + 二维码（内容 `brewping://pair?host=&port=&deviceId=&name=&code=`）。
  - iOS 端两条扫码路径：① 系统相机/微信扫 → 系统唤起 `brewping://` → `PairingURLHandler.handle` → `consumePairAction`（自动加设备 + 自动配对）；② **App 内扫码**（`QRScannerView.swift`，AVCaptureSession）→ 结果**填进配对表单**由用户确认后再 Pair。两条都复用同一套 `brewping://` 参数格式。
  - 相机权限 `NSCameraUsageDescription` 已加，审核表述"仅用于扫配对码"。**模拟器无相机**，扫码页会走降级提示，真机才能验证实际扫描。
- **鉴权**：Mac 端所有写操作走 Bearer token + `X-BrewPing-Timestamp`(±120s) + `X-BrewPing-Nonce`；token 在 iOS 侧存 Keychain（`DeviceAuth`，键 `deviceToken.<device.id>`），Mac 侧存 `~/.brewping/pairing.json`(0600)。
- **Demo 模式**：iOS 侧通过 `DemoURLProtocol` 拦截 `demo.brewping.local`，**不改动调用方代码**；`ManagedDevice.isDemo` 靠 host 判定（故意不加 Codable 字段，避免旧 UserDefaults JSON 解码失败清空设备列表）。
- **日志**：iOS 用 `BrewPingLog`、Watch 用 `WatchLog`，禁止裸 `print`；可能含用户内容的值标 `privacy: .private`。
- **隐私清单**：主 App 声明 `NSPrivacyAccessedAPICategoryUserDefaults / CA92.1`；Watch 声明 `NSPrivacyAccessedAPICategoryFileTimestamp / C617.1`。用了新的 Required Reason API 时必须同步更新对应 `PrivacyInfo.xcprivacy`。

## 已知坑

- **轮询与 scenePhase**：状态轮询的起停只能用 `!isInBackground`（`scenePhase != .background`）判定。用 `== .active` 会在系统弹窗（如首次语音授权）导致 `.inactive` 时直接 return，界面卡死在"离线"。
- **URLProtocol 读请求体**：URLSession 会把 `httpBody` 转成 `httpBodyStream`，只读 `httpBody` 会永远拿到空 body；必须 fallback 读 stream。
- **OSLog 插值**：`privacy:` 形式的值参数是 `@autoclosure`，在实例方法里直接插 `self` 的属性会报 "implicit use of 'self' in closure"，需先取到局部变量。
- **`build-device/**/Info.plist` 是过期产物**，缺 Bonjour / 语音权限 / 图标字段，不能作为合规判断依据——必须重新 Archive。`build*/` 已加进 `.gitignore`。
- **Watch 端录音**不用 `WKExtendedRuntimeSession`，故**不需要** `UIBackgroundModes`（这是正确做法，别"补"上）。
- **watchOS 别用很矮的 `TabView(.page)` 承载卡片**：`frame(height:)` 给到 30+ 时，页码点正常但**卡片文字渲染为空白**（数据与索引都对）。手表端切换类控件改用「左右箭头按钮 + 中间当前值」的一行 HStack 更稳。
- **Mac 端 `isRunning` 不能当"App 进程在跑"用**：它的真实语义是"`/api/status` 返回 online"，spawn 期间（5-10s）一直是 false，UI 会误显示红色 Offline。**必须用三段式 `RuntimeState`（idle/starting/online/offline）**，start() 立刻置 starting；启动后前 5s 每 200ms 轮询，之后回到 2s；离开 starting 即停 fast loop。这是 `Sources/App/DesktopCore.swift` + `Sources/BrewPingDesktop/MenuBarView.swift` 的当前实现。
- **改完 Mac 端后，先确认没有残留的旧打包进程占着 8787 端口**：`build/BrewPing Desktop.app` 这类旧 .app 若仍在后台（菜单栏常驻），`swift run` 的新实例 HTTP server 会因端口被占而起不来，`curl` 会**静默打到旧进程**上，表现为"新加的路由 404、新逻辑不生效"（2026-09-11 踩到：`/api/approvals/mode` 一直 404）。排查：`lsof -nP -iTCP:8787 -sTCP:LISTEN`，看 PID 对应的可执行文件路径是不是旧 .app。
- **`build-app.sh` 必须全量构建，不能用 `--target`**：脚本原来写的是 `swift build --target BrewPingDesktop -c release`，**`--target` 只编该 target 本身，依赖库 `BrewPingCore` 不会重编** —— 于是改完 `Sources/App/**`（HTTPAPI、ApprovalGate 等都在 Core 里）后打出的 .app 仍是旧逻辑（2026-09-11 实际踩到：iOS 切授权模式一直没反应，因为 .app 里根本没有 `/api/approvals` 路由）。已改为 `swift build -c release --disable-sandbox`（去掉 `--target`、补上 `--disable-sandbox`）。
  - 快速自检产物是否含最新代码：`strings "build/BrewPing Desktop.app/Contents/MacOS/BrewPingDesktop" | grep -c "api/approvals"`（0 = 旧二进制）。
  - **release 与 debug 是两套独立缓存**：平时 `swift build` 只更新 debug；只跑过 debug 验证不代表 release 产物也是新的。

### Windows 桌面端（`Sources/BrewPingwinDesktop`，Tauri v2 + WebView2）

- **窗口在、客户区全黑 = 渲染进程死了，不是前端代码的问题**。判别第一步永远是**看颜色值**：纯黑 `(0,0,0)` 说明 CSS 压根没加载；我们的背景 `--term-bg: #0f0f0f` 应是 `(15,15,15)`。再去数 `msedgewebview2.exe` 进程（按 `CommandLine -match "com\.brewping\.desktop"` 过滤）：**计数 0 且 app 进程 `children=NONE` → 别翻 App.tsx 了**。
- **破案关键：让 WebView2 自己说话**。启动前设 `$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--enable-logging --v=1"`，再读 `%LOCALAPPDATA%\com.brewping.desktop\EBWebView\chrome_debug.log`。本次给出的真凶：`GPU process exited unexpectedly: exit_code=1` ×9 → `FATAL: GPU process isn't usable. Goodbye.`（**GPU 进程静默 exit_code=1、自己一行日志都不留 = 起不来，不是崩溃**），浏览器进程遂自杀。
- **根因：Chromium 的 GPU 子进程无法在受限进程环境里启动**。反证：同机 `cc-switch.exe`（同为 Tauri/WebView2）GPU 正常 → **不是机器显卡问题，是启动它的进程环境**。
  - **我（Agent）在沙箱内替用户启动 Tauri 桌面端时必须带 `--no-sandbox`**，否则界面必黑。`--disable-gpu` **无效**（新版 Chromium 软件渲染仍会拉 GPU 进程）。
  - **`tauri.conf.json` 不要为此改动**：`--no-sandbox` 是安全降级，用户自己终端跑预期正常。真在用户侧复现，才考虑加 `"additionalBrowserArgs": "--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection --disable-gpu-sandbox"`（更温和，只关 GPU 进程沙箱，**尚未验证**）。
- **判断"自杀 vs 被杀"用 0.5s 采样进程数**：默认 `4` → 约 3 秒归零；`--no-sandbox` 下 `6` 全程稳定、日志 2940B→42961B。
- **截屏取证会骗人**：`SetForegroundWindow` 常被 Windows 拒绝，会截到**背后的 VS Code 深灰**，看起来"渲染好了"。必须 `SetWindowPos(hwnd, HWND_TOPMOST=-1, …)` 强制置顶，并**靠颜色值判定**，不要靠肉眼。
- **rustc ICE**：Tauri lib target（`staticlib+cdylib+rlib` 三合一叠加 `-C debuginfo=2`）配增量编译会稳定触发 `rmeta/encoder.rs:2407: no entry found for key`。用 `src-tauri/.cargo/config.toml` 的 `[build] incremental = false` 根治（删缓存只是治标，构建被打断即复发）。沙箱内 `Remove-Item target\debug\incremental` 会失败，别指望它。
- **与 iOS 的对接（2026-09-11 真机实测配对通过）**：
  - `POST /api/pair` 请求体 `{code, deviceName}`、响应 `{success, token, deviceId, deviceName}`，与 iOS `BrewPingHTTP.pairingRequest` 对齐；iOS token 存 Keychain 且**按本地设备 UUID 索引、不使用服务端 deviceId**，所以两端 deviceId 不同也不会错位。
  - token 落 `~/.brewping/pairing.json`（64 hex）→ **重启桌面端不必重新配对**。
  - 联网三件套已就位：监听 `0.0.0.0:8787`；防火墙 `BrewPing` 入站放行（Private+Public，程序=target/debug/brewping-desktop.exe）；iOS 侧 `NSAllowsLocalNetworking` + `NSLocalNetworkUsageDescription`。
  - **端点对齐**：status / agents / agents/default / session start·stop / message / approvals / **`GET /api/agents/{id}/models`** / **`POST /api/agents/models/default`** 全部 ✅。**仍缺** `POST /api/agents/{id}/switch`（Watch 切 agent）。
  - **模型列表的真实数据源**：`services/agent_config.rs` 是 macOS `AgentConfigDiscovery.swift` 的移植，读同一批配置文件（`~/.config/opencode/opencode.json`、`~/.claude/settings.json`、`~/.codex/config.toml`、`~/.aider.conf.yml`）。**只读、不伪造**；解析函数做成纯函数便于测试；TOML 用极简行解析（不引依赖）。
  - **用户选定的模型落 `~/.brewping/models.json`**（`services/model_prefs.rs`），**刻意不复用 macOS 的 `config.json`**（避免两端写同一个文件互相覆盖）。真正生效靠 spawn CLI 时追加 `--model <id>`（claude-code / codex / aider，与 `CLIAgentImplementations.swift` 同序）。**`AppState` 加字段时别忘了同步 `lib.rs` 与测试 `test_state` 两处构造点。**
  - **未知路由必须返回 JSON**：用 `.fallback(handle_not_found)`。axum 默认 404 是**空 body**，客户端按 JSON 解析会报 "The data couldn't be read because it isn't in the correct format." —— 把"没有这个接口"误报成"数据格式错误"（就是 iPhone 那句"未能读取数据，因为它的格式不正确"的病根）。
  - **缺陷（未修）**：iOS 扫码/深链建设备时曾硬编码 `.mac`（`ContentView.swift`），已改为读深链/TXT 的 osType。

## 占位值（提交前必须替换）

集中在 `ios/BrewPing/BrewPingConfig.swift`：
- `privacyPolicyURLString` = `https://brewping.app/privacy`（需公网可达，App Store Connect 也会校验）
- `supportEmail` = `support@brewping.app`
- `macAppName` = `BrewPing Desktop`
- 另需在 Xcode 填 Team ID 后重新 Archive。

## 相关文档

- `docs/AppStore-PreSubmission-Review.md` —— 上架前审核报告 + 修复清单落地记录 + 手动收尾步骤。
- `README.md` —— 含配对流程、Demo 说明、API 鉴权列、Trademarks 免责声明。

## 架构事实（做任何新接口/新会话能力前必读）

- **HTTP 层不解析 query string**：`Sources/App/HTTPServer.swift:203-206` 会把 `?` 之后整段丢掉，`HTTPRequest`（`:4-10`）也没有 query 字段。**任何需要 `?key=value` 的新接口都要先补这里**；Demo 侧同样（`ios/BrewPing/DemoURLProtocol.swift:22` 只透传 `url.path`）。绕开办法是改用 POST 体传参（代价：非 GET 会被 `PairingStore` 要求 timestamp+nonce）。
- **`HTTPServer` 路由是 `(method, path)` 的 switch**（`Sources/App/HTTPAPI.swift:21`），前缀匹配用 `path.hasPrefix(...)`；响应统一走 `HTTPResponse.json(status, reason, dict)`。注意**响应体不统一带 `success` 字段**（`/api/agents`、`/api/agents/:id/models` 就没有），客户端解码时别假设有。
- **鉴权规则**（`Sources/App/PairingStore.swift:97-134`）：`GET` 只需 `Authorization: Bearer`，**不校验 nonce**；非 `GET` 还要 `X-BrewPing-Timestamp` + `X-BrewPing-Nonce`（时间窗 120s，nonce 一次性）。iOS 的 `BrewPingHTTP.request` 已对任意 method 自动附加这三个头。→ **只读接口优先设计成 GET，可免掉 nonce 开销。**
- **会话工作目录链路**：`OpenCodeAgent.cwd`（`Sources/Agents/OpenCodeAgent.swift:10,16`，当前写死为 `FileManager.default.currentDirectoryPath`）→ `SessionInfo.cwd`（`Sources/Session/SessionManager.swift:12`）→ `AgentResponse.cwd` → `ProtocolStateService.project(from:)`（`:208`，取 lastPathComponent 当项目名）。**改了 cwd，`/api/status` 和 `/api/protocol/state` 的 `project` 会自动跟着变，无需额外改动。**
  - **⚠️ 但 PTY 不认这个 cwd**：`Sources/PTY/PTYSession.swift:80-98` 的 fork 子进程分支只做 `setenv` + `strdup` + `execv`，**没有 `chdir`**；`PTYManager.startProcess`（`PTYManager.swift:8`）也没有 cwd 参数。要让工作目录真正生效，必须三处一起改（spawn 加 `cwd` + 子进程 `chdir`，失败 `exit(126)` 以区分 127）。漏掉会**静默不生效**。
- **`~/.brewping/config.json` 的 `ConfigFile` 新增字段必须声明为 Optional**（`Sources/Agents/AgentManager.swift:27`）。老用户文件里没有该键，非可选会导致 `decode` 失败。同类教训已在 `ios/BrewPing/ManagedDevice.swift:38-42` 明文记录（`isDemo` 用 host 判定而非新增存储字段，就是为了避免清空用户设备列表）。
- **iOS 网络出口只有 `BrewPingHTTP`**（`ios/BrewPing/BrewPingHTTP.swift`）：① Demo 模式靠 `DemoURLProtocol` 挂在 `protocolClasses` 上透明拦截，所以**新接口必须在 `DemoBackend` 有对应用假实现**，否则 Demo 直接 404；② 它的 `request(device:path:)` 是 `URL(string: base + path)` **字符串拼接**，路径含空格/中文/`#` 会构造失败 → 需要 query 或非 ASCII 路径时必须加 `URLComponents` 版本重载。
- **iOS 端没有任何文件系统访问**，`ios/BrewPing/Info.plist` 里也没有文件权限声明。凡是"浏览/选择文件或文件夹"的需求，**在 iOS 上都必须是服务端驱动的自绘 UI**；用 `.fileImporter` / `UIDocumentPickerViewController` 会变成浏览 iPhone / iCloud，与 Mac 无关。
- **`ios/Scripts/check_localization.py` + 两个 `.lproj`**：新增任何用户文案都要同时落 `en.lproj` 与 `zh-Hans.lproj`，且**译文的 `%@` 个数必须与实参完全相等、顺序不可调换**（本项目实际踩过 `EXC_BAD_ACCESS (code=1, address=0x1)`）。
- **多主机 OS 类型已建模**：`ManagedDevice.osType` 有 `mac`/`windows`/`linux`（`ios/BrewPing/ManagedDevice.swift:4-24`），仓库里还有 `Sources/BrewPingwinDesktop`（Tauri/Rust）与 `Android/`。给 Mac 端设计新接口时**要留好跨平台字段**（如路径分隔符、盘符列表），否则将来接 Windows 主机要返工。
- **自测 Mac 端接口时的时间戳别用 `Get-Date -UFormat %s`**：PowerShell 5.1 下它与真实 epoch 偏差可超过 120s，会被 `PairingStore` 判 `stale request`（本项目实际踩到）。用 `[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()`。
