# BrewPing — 项目长期记忆

跨端遥控电脑 Agent（opencode/claude/codex/pi）：`ios/`、`Sources/`（Mac=SwiftPM；Win=Tauri2+axum+React）、`Android/`（`:app`+`:core`+`:wear`）。日志 append-only，写前必 Glob+Read。**只留高频规则，取证看当日日志。**

## 环境（Windows 本机）
- 🚨 回显常坏 → 落盘再 Read；沙箱拦 Start-Process/taskkill。Git Bash coreutils 缺、cd 坏、`timeout` 是 Windows 自带 exe → 不 cd、全绝对路径、长任务后台跑；**查找一律 Grep/Glob**（工具缺失会假报「无命中」）。
- 工具链：JDK17 `D:\study\java\devlop\jdk17`（显式设 JAVA_HOME，默认 jdk25 对 Gradle 8.14 偏新）；SDK `D:\software\androidSDK`；Xcode `/Applications/Xcode.app`；**无 Swift 工具链**。PS5.1 写文件用 `[IO.File]::WriteAllText` + UTF8 no-BOM。
- 🚨 **推送「卡住」≠ 失败**（GCM 在沙箱弹不出窗口）：先 `rev-list --left-right --count` 核对 remote 与 HEAD（实测 6.5 分钟无输出其实已推成功）；报 `could not read Username` 重试即可。`git credential fill` **绝不回显**。**无 `gh` CLI** → `urllib` + git 凭据调 GitHub API。
- 🚨 前台 rebase 被强杀曾毁 .git → 后台跑 + 落盘轮询；cwd 丢用 `git -C`。**推送前必先拉取**：fetch → 比 left-right → 落后则 **merge（绝不 rebase）** → **核对 tracked 数与目录级 ` D`**（曾误删 `ios/`：`git restore --source=HEAD --staged --worktree ios/`）；`core.filemode=false` 时提交不带 `-- paths`。
- memory 等 append-only 文件双方都改必冲突 → 备份 → untracked 同名日志移开 → `git checkout --` → merge → 回填。占位符禁用真实主机名/个人信息。
- 🚨 **TLS 间歇拦截**（502 / `CRYPT_E_NO_REVOCATION_CHECK` 0x80092012 / openssl `20`）：**首选 `-c http.sslBackend=schannel` 重试**；`schannelCheckRevoke=false` 无效；仅确认只读才 `sslVerify=false`。SDK 包同样被掐 → `HTTP Range` 续传。
- BOM：`strip_prefix('\u{feff}')`，不只 JSON —— TOML/YAML 行首 BOM 会静默丢整段配置。8787 被旧进程占 → curl 打的是旧进程。

## CI / Release 元数据
- 🚨 **`main` CI 红是第一优先级**；判断仓库质量**先看 CI 实际结论**。定位到步：`GET /actions/runs` → `/runs/{id}/jobs` 看每步 conclusion —— **Build 步过 + Unit tests 步挂 = 编译没问题、断言失败**。⚠️ `/actions/jobs/{id}/logs` 公开仓库也要高权限（401）→ 靠步粒度 + 静态镜像。🚨 判绿**必须先断言 job 数**（run 刚创建时 `jobs=[]`，`all([])` 恒 True → 会误报全绿）。
- 🚨 **Swift 本机无法验证** → 改纯逻辑必须**用 Python 逐条镜像「实现 × 断言」**。实战：`CommandStatus.completedWithRaw` 的 rawValue 是 `completed_with_raw`，测试却断言驼峰 → `derive` 落 default 返回 `idle` → main 两次 CI 红。
- Release 元数据：`GET /releases/tags/<tag>` 取 `id` → `PATCH /releases/<id>` 只传 `{name}`（tag/asset/正文不动）。首 tag `v1.0.0`（名已规范）；⚠️ Windows 内部版本号仍 `0.1.0`。分发统一走 GitHub Release。
- 🚨 **发行状态事实（勿夸大）**：iOS/watchOS **已提交 App Review、未公开发布**（仅 TestFlight）；Android **构建就绪、未提交 Google Play**；Wear **在仓库内、未发布**。文档**不得写成「已上架」**。

## iOS / Watch
- 只做 iPhone（`TARGETED_DEVICE_FAMILY=1`）；iOS 17；bundle `com.brewping.ios` / `.watchkitapp`。⚠️ ASC 截屏页签由**该版本所附构建**的 `UIDeviceFamily` 决定 → **重新 Archive 上传，不是补图**。隐私政策 https://banmu123.github.io/BrewPing/privacy.html（源 `docs/privacy.html`）；TEAM `TGA82PM3DZ`；不做国区。
- 🚨 新 Swift 文件登 pbxproj **四处**；译文 `%@` 个数=实参数 → 跑 `ios/Scripts/check_localization.py`。i18n：`Text("字面量")` 靠 `.environment(\.locale)`；`Text(变量)` 须 `LocalizedStringKey(变量)`。
- 🚨 **Bonjour 只能 `NWBrowser.Result.endpoint` → `NWConnection`，绝不用 `NetService.resolve`**（真机/TestFlight 停摆，模拟器正常）；`remoteEndpoint` 可能是 `fe80::…%en0` → 须 `internetProtocol.version = .v4` 并剥 `%en0`。局域网明文 http；Bearer+Timestamp±120s+Nonce；改端点同步 `DemoBackend.swift`。
- 🚨 **Logger 插值是 autoclosure**：插值里取实例属性必须 `self.xxx`（deinit 同）。`BrewPingLog` 是 `os.Logger`，**无 `#if DEBUG` 门控，TestFlight 照常输出**。
- 🚨 `PolicyDenied = -65570`；**-65555 是 `NoAuth`** → 别写字面值。**Xcode 直跑自动授权 → Debug 能发现 ≠ 权限没问题，必须 TestFlight 验**；Bonjour 浏览**不需** multicast 权限。
  🚨 iOS 无权限查询 API → **发起浏览即唯一查询方式**：别再加 `hasEverBeenGranted` 类门禁（曾锁死首装）；进设备页无条件 `startSearching()`，遇 `.waiting` 续期 ≤3 次。

## macOS 桌面端
- 🚨 `DesktopCommands.swift` 是 UI 唯一入口（UI 不直碰 Store/Gate）；执行唯一路径 `ConversationCommandService` + `CommandRouter.shared`。
- 🚨 **执行状态单一来源 `Sources/App/ConversationRun.swift`**：九阶段（idle→stalled，含 stopping），**绑定 commandId + conversationId**；阈值全在 `RunTiming`（首字 8s / stalled 30s / 停止 10s / UI 合并 100ms）；**必须放 `Sources/App/`**（链 SwiftUI 的 Desktop target 会让测试启动 GUI）。
  💡 后端推**累积全文** → 过时帧按「前缀关系」判（相同=重复、严格前缀=过时、`done=true` 一律接受）。`runs` 按 conversationId 分桶（切对话**不得清 runs**）；delta 入 `pendingDelta` 100ms 合并；`reconcileRun` **只认 assistant/error** 才终结命令。
- 🚨 **HTTP `run` 快照**：`GET /api/message/:id` 增 `run{commandId,phase,startedAtMs,lastOutputAtMs,updatedAtMs}`；推导纯函数 `RunPhaseDTO.derive`（`Sources/App/RunStatusTracker.swift`），**stalled 由桌面端权威判定**；「最后输出时刻」只进内存字典（逐帧写 CommandInfo 会写爆磁盘）。`POST /api/message` 的 `commandId` 是客户端幂等键。
- 🚨 **状态粒度必须一致**：**凡「按 X 归属」的状态，判定侧必须额外校验归属维度与语义角色**（历史坑：TerminalState 按 Agent、busy 按对话 → 串台；commandId 跨 role 复用 → 误清流式气泡）。
- ⚠️ `DesktopStrings.swift` 与 TS 对齐**仅限 `sw*`（Setup Wizard）组**；`chat.*`/`settings.*` 属 Mac 专有，**无生成脚本**；UI 样式照 Latte 令牌。
- 🚨 打包：bundle id 统一 `com.brewping.desktop`；Hardened Runtime **不开 App Sandbox**；`swift build` 要加 `--disable-sandbox`；⚠️ `release-mac.yml` 缺 `MACOS_*` secrets → **Mac 包只能本地打、手工挂**。
- 🚨 **公证会长时间排队**：`--wait` 报 `deadlineExceeded` **不代表失败** → `submit` 拿 id + `info` 轮询（`In Progress` 会被 `awk '{print $2}'` 截成 `In`）。替换 Release 同名资产**必须先 DELETE**；发布脚本**别用 `pipefail` 配 `grep`**；`set -u` 下变量先初始化。

## Windows 桌面端
- 🚨 tokio Mutex 不可重入；HTTP 错误体永远 JSON（query 用 `Option<String>` 手工解析）。
- 🚨 **子进程一律走 `services::proc::hide_console(&mut cmd)`**（否则 `.cmd` 包装的 CLI 每 spawn 弹黑窗）；`CREATE_NO_WINDOW` 是「**不新建**控制台」→ 只在装包/GUI 复现，改完必须装包实测。单实例在 `services/single_instance.rs`（`CreateMutexW`），`MAIN_WINDOW_TITLE` 与 `tauri.conf.json` 标题同批改。
- 🚨 Tauri 2 窗口在 `setup()` **之前**已建好 → setup 里同步阻塞会白屏/无响应；重活走 `spawn_blocking` + `emit("refresh-agents")`。
- 🚨 `lib.rs:1` 有 crate 级 `#![allow(dead_code, unused_variables)]` →「cargo check 零警告」**不能**当无死代码依据。**动态调用盲区**（看似零引用不可删）：`@main`/`body`/`NSViewRepresentable`/`URLProtocol`/Compose/`BackHandler`/CameraX；`Sources/Protocol/` **是活的**。
- 🚨 厂商配置「路径表」手工复制：Swift 4 份 / Rust 6 处，`config_lock()` **4 份独立 `OnceLock` 互不相通** → 改一处必须全改。⚠️ 别往 `Sources/BrewPingwinDesktop` 放 .swift。🚨 serde：`base_url` 必须 `rename="baseURL"`（否则白屏）。鉴权 `route_layer` 全表；白名单仅 `POST /api/pair` + `GET /api/status`，GET 免 nonce。
- 配置基线：Claude 只覆盖 env；Codex `[model_providers]` name 必填 + 不碰 auth.json；pi 成对；OpenCode 深合并。对话级：模型 = `model_override` 成对 > Agent 偏好 > active；授权 = 对话档 > 全局。

## 模型配置代理 / 授权
- ①路由表 `model_providers.json` ②CLI 原生配置（模型发现唯一来源）；只②→503。🚨 Codex 接管必须 `wire_api="responses"`。
- 🚨 预设端点**按 agent 分派**（`provider_catalog` 每条自带 `endpoints[AgentEndpoint]`）→ ⚠️ Windows 曾按顶层 `/anthropic` 匹配而必失配（macOS 已修）。枚举见 `docs/BrewPing-Provider管理-*.md`。
- 授权三档 safe/askAll/auto，作用域=**全局**；检测点=命令进 agent 前（`ApprovalGate.shared.check`）；超时默认拒绝（TTL 300s）；危险模式本地内置正则，**绝不信任 agent 自报**。

## Android / Wear OS
- 🚨 **compileSdk/targetSdk = 36**（Play 自 **2026-08-31** 要求）。链：targetSdk 36 → compileSdk 36 → **AGP ≥ 8.9**（**8.10 上限正好 36**）→ Gradle ≥ 8.11.1 → JDK 17 → `platforms;android-36` + `build-tools;36.0.0`。
- 🚨 **API 37（Play 2027-08-31 强制）= `ACCESS_LOCAL_NETWORK`**：NSD/mDNS、局域网 HTTP、`.local` 全受影响 → 须声明 + 运行时请求 + 拒绝后降级手动 IP。**光改版本号会让发现整体失效。**
- 🚨 **三模块**（`settings.gradle.kts` 全注册）：`:app` + `:core`（`com.brewping.core`）+ `:wear`（`com.brewping.wear`、minSdk 30、同 applicationId 但 versionCode 不重叠）。⚠️ Wear 必须用 **Wear Compose material3**，**不可引手机版 `androidx.compose.material3`**（主题串台）；Manifest 需 watch feature（`<manifest>` 直接子元素）+ standalone + cleartext。
- 🔌 **唯一 HTTP 出口 = `:core` 的 `DesktopApiClient.kt`**；`BrewPingTransport` + `DirectHttpTransport` 是抽象层，**UI 不得直连 HTTP**。令牌存 **Keystore AES-256/GCM**（明文 SP 透明迁移；`token/isPaired/saveToken/clearToken` 签名**不得变**）；`CommandReceiver.kt` 是死桩。
- 手表 provisioning：手机 `WearProvisionSender` → Data Layer `/brewping/provision` → 手表 `WearProvisionReceiverService`（host/port 普通持久化，**token 走 Keystore**）；手表无摄像头 → QR 不可用。
- 🚨 `strings.xml` 新增前先 grep 同名 key；中英 key 集合须一致；用 `@ExperimentalMaterial3Api` 组件（`CenterAlignedTopAppBar`）必须 `@OptIn`。
- 本机验证：`JAVA_HOME=<jdk17> ./gradlew.bat test assembleDebug :wear:assembleDebug`（单测 **83** = :core 36 + :app 47）。

## 工具与协作约定
- 🚨 **同一文件的多个编辑不得并行**（后写覆盖先写，**工具仍报 success**）；**改完必须回读 / `git diff` 核对**（2026-09-21 实测丢了 2 处改动）。
- 🚨 **静态核对（括号平衡/XML/引用存在性）证明不了能编译** —— 有编译器就跑（本机 JS/TS/Rust/Java 齐，**Swift 除外**）。
- 🚨 **UI 禁止「未就绪即定论」**：空态/错误态必须等数据源**确认过一次**才渲染（iOS `discoverySettled`；Android `!discoveryRunning`）。
- 📄 **文档事实口径**：测试数（Swift 66 / Android 83 / Rust 318）、平台、发行状态以 README 双语 + `docs/PROJECT_STATUS.md` 为单一来源；`LICENSE` 必须是**纯 MIT 文本**（尾部追加段落 → GitHub 识别不出），商标归 `TRADEMARKS.md`；`experimental/relay-server/` 是停放原型，不在产品链路/CI/安全边界。
- 提交：**分主题多个提交**，信息走 `.commit-msg-N.txt`。**不确定就不要删**；不为减行数而重构；「零警告/零引用」结论先确认检查没被关掉。
