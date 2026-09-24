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
- Release：GET /releases/tags/<tag> 取 id → PATCH 只传 {name}。🚨 **发行状态事实（勿夸大，2026-09-24 更新）**：**iOS / watchOS 已上架 App Store**（App Store 链接暂不公开，README 只写「search for BrewPing」）；macOS / Windows 走 GitHub Release `v1.0.0`；**Android 未提交 Google Play、Wear OS 未发布**。README 双语 + `docs/PROJECT_STATUS.md` 三处必须同口径，别再写「App Review / 未公开发布」。

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
- 🚨 `strings.xml` 新增前先 grep 同名 key；中英 key 集合须一致（现 **138** 条）；用 `@ExperimentalMaterial3Api` 组件（`CenterAlignedTopAppBar`）必须 `@OptIn`。⚠️ **aapt2 拒绝 `\uXXXX` 转义**（报 `Invalid unicode escape sequence`）→ 破折号写字面 `—`、撇号写 `\'`。⚠️ Kotlin 反引号测试名**不能含 `/`**（`Name contains illegal characters`）。深链 singleTask + `onNewIntent setIntent`；NSD 不需额外权限；DELETE 无响应体。
- 手表 provisioning：WearProvisionSender→/brewping/provision→WearProvisionReceiverService（host/port 普通持久化，**token 走 Keystore**）；手表无摄像头 → QR 不可用。Wear Manifest 需 watch feature（`<manifest>` 直接子元素）+ standalone + cleartext。
- 🚨 **命令生命周期唯一权威=`DesktopRepository`**（`_commandPhase` + `submitMessage`/`startCommandPolling`/`decideApproval`，已是 `BrewPingApp` 级单例）；`ConversationDetailScreen` ← `HomeViewModel.commandPhase` 只是透传。⚠️ **与 iOS 不同构**：iOS `CommandReceiver`+`CommandSubmitter` 存在的前提是「WCSession 能在后台唤醒进程投递命令」，**Android 无此通道**（Wear 直连桌面端不经手机；`:app` 清单只有 MainActivity，无 Service/Receiver/WorkManager）→ 曾模仿 iOS 命名而建的 `CommandReceiver.kt` 已于 2026-09-24 删除（含 `CommandReceiverTest.kt` 5 例与注入链），**别再按 iOS 名字重建**。
- 验证：JAVA_HOME=<jdk17> ./gradlew.bat test assembleDebug :wear:assembleDebug（**109=core 67+app 42**；用例数从 JUnit XML `grep -c '<testcase '` 取，别信 gradle stdout）。
- 🔄 **与 iOS 已对齐**（2026-09-24 实施完成，详见 `docs/BrewPing-Android-iOS-功能对齐审查.md`）：核心链路本就平齐（发现/配对/签名/命令+轮询/审批三档/多对话/置顶归档/工作目录/模型/多设备/语言三档/主题/Markdown/Keystore 令牌），本轮补齐 **Demo 模式**。
  **Demo 实现**（`:core/demo/`）：`DemoBackend.kt`（16 端点，形状与桌面端同构）+ `DemoInterceptor.kt`（**OkHttp Interceptor** 拦截 `demo.brewping.local`，对齐 iOS 的 `URLProtocol` 方案 → `DesktopApiClient` 40 个方法零改动）+ `DemoStrings`（文案由 `:app` 注入，随语言切换）。`ManagedDevice.isDemo` **由主机名派生**（不加存储字段，避免旧 JSON 反序列化失败）；`HomeViewModel.isPaired` 对 Demo 放行。
  ⚠️ **原审计的两条误判已更正**：「手机端语音」**不是缺口** —— iOS 手机端**无麦克风入口**，其 `SFSpeechRecognizer` 只用于转写**手表音频**（`transcribeAndForward(audioURL:)`）；「权限恢复引导」同理（手机端只需相机权限，NSD 无需权限）。
  **Android 反超 iOS**：会话启停 UI、设备重命名（iOS 均 0 命中）。**手机端执行阶段两端都是客户端 `CommandPhase` 七态**（同名同态）；服务端 `run.phase`（含 stalled）目前**只有 Wear 端消费**。

## 工具与协作约定
- 🚨 **同一文件多编辑不得并行**；改完必须回读/git diff 核对。
- 🚨 静态核对≠能编译；有编译器就跑（本机 JS/TS/Rust/Java 齐，Swift 视环境）。
- 🚨 UI 禁止「未就绪即定论」：等数据源确认过才渲染空/错误态。
- 📄 文档事实口径：测试数 Swift 66/**Android 109**/Rust 318 以 README+PROJECT_STATUS+CONTRIBUTING 为准；LICENSE 纯 MIT；experimental/ 不在产品链路。⚠️ **测试数变动必须四处同步**（README.md / README.zh-CN.md / docs/PROJECT_STATUS.md / CONTRIBUTING.md）——曾出现日志已记 114、文档仍写 83 的漏同步。
- 🚨 **跨端同名文件是认知陷阱主源**：移植/命名前先验证该抽象赖以存在的约束在目标端是否成立。判定死代码要看「**注入链完整但类体内零读取**」，不能只看有没有被 import（`CommandReceiver.kt` 就是这样潜伏的）。
- 提交：分主题多提交，信息走 .commit-msg-N.txt；不确定就不删。
