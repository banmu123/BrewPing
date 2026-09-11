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
  - 入口显示条件：`models.count > 1`（0 个或 1 个都隐藏）。
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

## 占位值（提交前必须替换）

集中在 `ios/BrewPing/BrewPingConfig.swift`：
- `privacyPolicyURLString` = `https://brewping.app/privacy`（需公网可达，App Store Connect 也会校验）
- `supportEmail` = `support@brewping.app`
- `macAppName` = `BrewPing Desktop`
- 另需在 Xcode 填 Team ID 后重新 Archive。

## 相关文档

- `docs/AppStore-PreSubmission-Review.md` —— 上架前审核报告 + 修复清单落地记录 + 手动收尾步骤。
- `README.md` —— 含配对流程、Demo 说明、API 鉴权列、Trademarks 免责声明。
