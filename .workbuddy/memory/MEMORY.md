# BrewPing — 项目长期记忆

跨端遥控电脑 Agent（opencode/claude/codex/pi）：`ios/`、`Sources/`（Mac=SwiftPM；Win=Tauri2+axum+React）、`Android/`（`:app`+`:core`+`:wear`）。日志 append-only，写前必 Glob+Read。**只留高频规则，取证看当日日志。**

## 环境（Windows 本机）
- 回显常坏→落盘再 Read；沙箱拦 Start-Process/taskkill；不 cd、全绝对路径；查找一律 Grep/Glob。PS5.1 写文件 `[IO.File]::WriteAllText`+UTF8 no-BOM。
- 工具链：JDK17 `D:\study\java\devlop\jdk17`（显式 JAVA_HOME）；SDK `D:\software\androidSDK`。**无 `gh` CLI** → urllib+git 凭据调 GitHub API；`git credential fill` 绝不回显。
- 🚨 推送「卡住」≠失败：`rev-list --left-right --count` 核对。推送前必先拉取：fetch→落后则 **merge（绝不 rebase）**→核对误删（曾删 `ios/`）。前台 rebase 被强杀曾毁 .git→后台跑+落盘轮询。
- 🚨 TLS 间歇拦截（502/0x80092012）：首选 `-c http.sslBackend=schannel`；SDK 包用 HTTP Range 续传。BOM：TOML/YAML 行首 BOM 静默丢配置。
- 🚨 memory 等 append-only 文件双方都改必冲突 → 备份 → untracked 同名日志先移开 → `git checkout --` 还原 → merge → 回填；占位符禁用真实主机名/个人信息。8787 被旧进程占 → curl 打的是旧进程。GitKraken 动过的仓库留悬空 remote ref（`cannot lock ref`）→ 写回 `refs/remotes/origin/<branch>` 再 `fetch --all --prune`，**别先** `remote prune`。

## CI / Release
- 🚨 main CI 红是第一优先级。定位：GET /actions/runs → /runs/{id}/jobs 每步 conclusion；判绿**必先断言 job 数**（jobs=[] 时 all([]) 恒 True）。
- 🚨 Swift 改纯逻辑本机无法验证 → Python 逐条镜像「实现×断言」。
- Release：GET /releases/tags/<tag> 取 id → PATCH 只传 {name}。🚨 **发行状态事实（勿夸大）**：iOS 已提交 App Review 未公开发布（仅 TestFlight）；Android 未提交 Play。文档不得写「已上架」。

## iOS / Watch
- 只做 iPhone（TARGETED_DEVICE_FAMILY=1）；iOS 17；TEAM TGA82PM3DZ；隐私政策源 `docs/privacy.html`。⚠️ ASC 截屏页签由**该版本所附构建**的 `UIDeviceFamily` 决定 → **重新 Archive 上传，不是补图**。
- 🚨 新 Swift 文件登 pbxproj 四处；跑 `ios/Scripts/check_localization.py`；`Text(变量)` 须 LocalizedStringKey。
- 🚨 Bonjour 只能 NWBrowser endpoint→NWConnection，绝不用 NetService.resolve；IPv4 剥 %en0；Bearer+Timestamp±120s+Nonce；改端点同步 DemoBackend.swift。
- 🚨 PolicyDenied=-65570，-65555=NoAuth 别写字面值；Xcode 直跑自动授权≠权限没问题，必须 TestFlight 验；iOS 无 LocalNetwork 权限查询 API→进设备页无条件 `startSearching()`，遇 `.waiting` 续期 ≤3 次。
- 🚨 Logger 插值 autoclosure 取 self.xxx；BrewPingLog 无 DEBUG 门控。
- 🚨 **权限交互（5.1.1(iv) 合规，2026-09 审核后）**：权限卡只许「说明 + 单一 Continue」（Continue→`PermissionCenter.requestLocalNetwork`）；**绝无 Grant/Allow/Grant All 按钮**；相机=扫码页 JIT、语音=手表语音送达 JIT，卡内只显示真实状态徽章；首装 onAppear **不自动** startSearching（LN 系统框必须由 Continue 触发），scenePhase 仅 `.denied` 或曾授权才自动续扫；Open Settings 只在「已被拒」时出现。
- 💡 本机 xcode-select 指向 CLT → xcodebuild/simctl 加 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`；模拟器不弹 LN 权限框；`simctl spawn booted defaults write com.brewping.ios <key>` 可伪造持久化标记做老用户验证。

## macOS 桌面端
- 🚨 UI 唯一入口 DesktopCommands.swift；执行唯一路径 ConversationCommandService+CommandRouter.shared。
- 🚨 执行状态单一来源 `Sources/App/ConversationRun.swift`（九阶段，绑定 commandId+conversationId，必须放 Sources/App/）；RunPhaseDTO.derive 在 RunStatusTracker.swift。状态判定须额外校验归属维度与语义角色。
- 🚨 HTTP `run` 快照：`GET /api/message/:id` 增 `run{commandId,phase,startedAtMs,lastOutputAtMs,updatedAtMs}`；推导纯函数 `RunPhaseDTO.derive`，**stalled 由桌面端权威判定**（阈值同 `RunTiming.stallSeconds`=30s）；「最后输出时刻」只进内存字典（逐帧写 CommandInfo 会写爆磁盘）。`POST /api/message` 的 `commandId` 是客户端幂等键。
- ⚠️ `DesktopStrings.swift` 与 TS 对齐**仅限 `sw*`（Setup Wizard）组**；`chat.*`/`settings.*` 属 Mac 专有，**无生成脚本**；UI 样式照 Latte 令牌。
- 🚨 打包：bundle com.brewping.desktop；Hardened Runtime 不开 App Sandbox；swift build 加 --disable-sandbox；Mac 包只能本地打。公证 --wait 超时≠失败→submit+info 轮询；替换 Release 资产先 DELETE。

## Windows 桌面端
- 🚨 子进程走 services::proc::hide_console（否则弹黑窗）；单实例 services/single_instance.rs。
- 🚨 Tauri 2 窗口 setup() 前已建→setup 阻塞白屏；重活 spawn_blocking+emit("refresh-agents")。
- 🚨 厂商配置路径表：Swift 4 份/Rust 6 处，config_lock() 4 份 OnceLock 全改；serde base_url 必须 rename="baseURL"。
- 🚨 tokio Mutex 不可重入；HTTP 错误体永远 JSON（query 用 `Option<String>` 手工解析）。鉴权 `route_layer` 全表；白名单仅 `POST /api/pair` + `GET /api/status`，GET 免 nonce。
- 🚨 `lib.rs:1` 有 crate 级 `#![allow(dead_code, unused_variables)]` →「零警告」**不能**当无死代码依据；**动态调用盲区**（`@main`/`body`/`NSViewRepresentable`/`URLProtocol`/Compose/`CameraX`）看似零引用但不可删。
- 配置基线：Claude 只覆盖 env；Codex `[model_providers]` name 必填 + 不碰 auth.json；pi 成对；OpenCode 深合并。对话级：模型 = `model_override` 成对 > Agent 偏好 > active；授权 = 对话档 > 全局。

## App 内授权（ApprovalGate）
- safe/askAll/auto 全局作用域；检测点=命令进 agent 前；超时默认拒绝（TTL 300s）；危险模式本地内置正则，**绝不信任 agent 自报**。
- 模型接入两套：①路由表 `model_providers.json` ②CLI 原生配置（模型发现唯一来源）；只②→503。🚨 Codex 接管必须 `wire_api="responses"`；预设端点**按 agent 分派**（Windows 曾按顶层 `/anthropic` 匹配而必失配，macOS 已修）。

## Android / Wear OS
- 🚨 compileSdk/targetSdk=36 链：AGP≥8.9→Gradle≥8.11.1→JDK17→platforms;android-36。API 37=ACCESS_LOCAL_NETWORK（勿只改版本号）。
- 🚨 三模块 :app+:core+:wear；Wear 必须用 Wear Compose material3，不可引手机版。
- 🔌 唯一 HTTP 出口=:core DesktopApiClient.kt；令牌 Keystore AES-256/GCM，token/isPaired 签名不得变。
- 🚨 `strings.xml` 新增前先 grep 同名 key；中英 key 集合须一致；用 `@ExperimentalMaterial3Api` 组件（`CenterAlignedTopAppBar`）必须 `@OptIn`。深链 singleTask + `onNewIntent setIntent`；NSD 不需额外权限；DELETE 无响应体。`CommandReceiver.kt` 是死桩。
- 手表 provisioning：WearProvisionSender→/brewping/provision→WearProvisionReceiverService（host/port 普通持久化，**token 走 Keystore**）；手表无摄像头 → QR 不可用。Wear Manifest 需 watch feature（`<manifest>` 直接子元素）+ standalone + cleartext。
- 验证：JAVA_HOME=<jdk17> ./gradlew.bat test assembleDebug :wear:assembleDebug（83=core 36+app 47）。

## 工具与协作约定
- 🚨 **同一文件多编辑不得并行**；改完必须回读/git diff 核对。
- 🚨 静态核对≠能编译；有编译器就跑（本机 JS/TS/Rust/Java 齐，Swift 视环境）。
- 🚨 UI 禁止「未就绪即定论」：等数据源确认过才渲染空/错误态。
- 📄 文档事实口径：测试数 Swift 66/Android 83/Rust 318 以 README+docs/PROJECT_STATUS.md 为准；LICENSE 纯 MIT；experimental/ 不在产品链路。
- 提交：分主题多提交，信息走 .commit-msg-N.txt；不确定就不删。
