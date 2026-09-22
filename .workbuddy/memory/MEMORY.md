# BrewPing — 项目长期记忆

跨端遥控电脑 Agent（opencode/claude/codex/pi）：`ios/`、`Sources/`（Mac=SwiftPM；Win=Tauri2+axum+React）、`Android/`（`:app`+`:core`+`:wear`）。日志 append-only，写前必 Glob+Read。**只留高频规则，取证看当日日志。**

## 环境（Windows 本机）
- 回显常坏→落盘再 Read；沙箱拦 Start-Process/taskkill；不 cd、全绝对路径；查找一律 Grep/Glob。PS5.1 写文件 `[IO.File]::WriteAllText`+UTF8 no-BOM。
- 工具链：JDK17 `D:\study\java\devlop\jdk17`（显式 JAVA_HOME）；SDK `D:\software\androidSDK`。**无 `gh` CLI** → urllib+git 凭据调 GitHub API；`git credential fill` 绝不回显。
- 🚨 推送「卡住」≠失败：`rev-list --left-right --count` 核对。推送前必先拉取：fetch→落后则 **merge（绝不 rebase）**→核对误删（曾删 `ios/`）。前台 rebase 被强杀曾毁 .git→后台跑+落盘轮询。
- 🚨 TLS 间歇拦截（502/0x80092012）：首选 `-c http.sslBackend=schannel`；SDK 包用 HTTP Range 续传。BOM：TOML/YAML 行首 BOM 静默丢配置。

## CI / Release
- 🚨 main CI 红是第一优先级。定位：GET /actions/runs → /runs/{id}/jobs 每步 conclusion；判绿**必先断言 job 数**（jobs=[] 时 all([]) 恒 True）。
- 🚨 Swift 改纯逻辑本机无法验证 → Python 逐条镜像「实现×断言」。
- Release：GET /releases/tags/<tag> 取 id → PATCH 只传 {name}。🚨 **发行状态事实（勿夸大）**：iOS 已提交 App Review 未公开发布（仅 TestFlight）；Android 未提交 Play。文档不得写「已上架」。

## iOS / Watch
- 只做 iPhone（TARGETED_DEVICE_FAMILY=1）；iOS 17；TEAM TGA82PM3DZ；隐私政策源 `docs/privacy.html`。
- 🚨 新 Swift 文件登 pbxproj 四处；跑 `ios/Scripts/check_localization.py`；`Text(变量)` 须 LocalizedStringKey。
- 🚨 Bonjour 只能 NWBrowser endpoint→NWConnection，绝不用 NetService.resolve；IPv4 剥 %en0；Bearer+Timestamp±120s+Nonce；改端点同步 DemoBackend.swift。
- 🚨 PolicyDenied=-65570，-65555=NoAuth 别写字面值；Xcode 直跑自动授权≠权限没问题，必须 TestFlight 验；iOS 无 LocalNetwork 权限查询 API→进设备页无条件 `startSearching()`，遇 `.waiting` 续期 ≤3 次。
- 🚨 Logger 插值 autoclosure 取 self.xxx；BrewPingLog 无 DEBUG 门控。
- 🚨 **权限交互（5.1.1(iv) 合规，2026-09 审核后）**：权限卡只许「说明 + 单一 Continue」（Continue→`PermissionCenter.requestLocalNetwork`）；**绝无 Grant/Allow/Grant All 按钮**；相机=扫码页 JIT、语音=手表语音送达 JIT，卡内只显示真实状态徽章；首装 onAppear **不自动** startSearching（LN 系统框必须由 Continue 触发），scenePhase 仅 `.denied` 或曾授权才自动续扫；Open Settings 只在「已被拒」时出现。
- 💡 本机 xcode-select 指向 CLT → xcodebuild/simctl 加 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`；模拟器不弹 LN 权限框；`simctl spawn booted defaults write com.brewping.ios <key>` 可伪造持久化标记做老用户验证。

## macOS 桌面端
- 🚨 UI 唯一入口 DesktopCommands.swift；执行唯一路径 ConversationCommandService+CommandRouter.shared。
- 🚨 执行状态单一来源 `Sources/App/ConversationRun.swift`（九阶段，绑定 commandId+conversationId，必须放 Sources/App/）；RunPhaseDTO.derive 在 RunStatusTracker.swift。状态判定须额外校验归属维度与语义角色。
- 🚨 打包：bundle com.brewping.desktop；Hardened Runtime 不开 App Sandbox；swift build 加 --disable-sandbox；Mac 包只能本地打。公证 --wait 超时≠失败→submit+info 轮询；替换 Release 资产先 DELETE。

## Windows 桌面端
- 🚨 子进程走 services::proc::hide_console（否则弹黑窗）；单实例 services/single_instance.rs。
- 🚨 Tauri 2 窗口 setup() 前已建→setup 阻塞白屏；重活 spawn_blocking+emit("refresh-agents")。
- 🚨 厂商配置路径表：Swift 4 份/Rust 6 处，config_lock() 4 份 OnceLock 全改；serde base_url 必须 rename="baseURL"。

## App 内授权（ApprovalGate）
- safe/askAll/auto 全局作用域；检测点=命令进 agent 前；超时默认拒绝（TTL 300s）；危险模式本地内置正则，**绝不信任 agent 自报**。

## Android / Wear OS
- 🚨 compileSdk/targetSdk=36 链：AGP≥8.9→Gradle≥8.11.1→JDK17→platforms;android-36。API 37=ACCESS_LOCAL_NETWORK（勿只改版本号）。
- 🚨 三模块 :app+:core+:wear；Wear 必须用 Wear Compose material3，不可引手机版。
- 🔌 唯一 HTTP 出口=:core DesktopApiClient.kt；令牌 Keystore AES-256/GCM，token/isPaired 签名不得变。
- 手表 provisioning：WearProvisionSender→/brewping/provision→WearProvisionReceiverService。验证：JAVA_HOME=<jdk17> ./gradlew.bat test（83=core 36+app 47）。

## 工具与协作约定
- 🚨 **同一文件多编辑不得并行**；改完必须回读/git diff 核对。
- 🚨 静态核对≠能编译；有编译器就跑（本机 JS/TS/Rust/Java 齐，Swift 视环境）。
- 🚨 UI 禁止「未就绪即定论」：等数据源确认过才渲染空/错误态。
- 📄 文档事实口径：测试数 Swift 66/Android 83/Rust 318 以 README+docs/PROJECT_STATUS.md 为准；LICENSE 纯 MIT；experimental/ 不在产品链路。
- 提交：分主题多提交，信息走 .commit-msg-N.txt；不确定就不删。
