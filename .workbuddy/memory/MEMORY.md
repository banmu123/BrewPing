# BrewPing — 项目长期记忆

跨端：手机/Watch/Android 远程指挥电脑 Agent（opencode / claude / codex / pi）。`ios/`、`Sources/`（Mac=SwiftPM 七模块；Win=Tauri2+axum+React）、`Android/`。日志 append-only，写前必 Glob+Read。**只留高频规则与触发条件，取证看当日日志。**

## 环境事实（Windows 本机）
- 🚨 回显常坏 → 落盘再 Read；沙箱拦 Start-Process/taskkill。Git Bash coreutils 常缺、cd 坏、npm 是 WSL shim → 不 cd、全绝对路径、长任务后台跑；⚠️ 查找一律用 Grep/Glob（`cmd || echo` 工具缺失时会**假报「无命中」**）。
- 🆕 工具链都在本机：JDK 17 `D:\study\java\devlop\jdk17`（默认 JAVA_HOME 是 jdk25，对 Gradle 8.14 偏新 → 显式指定）；Android SDK `D:\software\androidSDK`；Mac 侧 Xcode `/Applications/Xcode.app`。WinPS5.1 写文件 `[IO.File]::WriteAllText` + UTF8 no-BOM。
- 🚨 前台 git rebase 被强杀曾毁 .git → git 秒完成或后台落盘轮询；cwd 丢用 `git -C`。**推送前必须先拉取**（用户明令）：fetch → `rev-list --left-right --count` → 落后则 **merge（绝不用 rebase）** → **merge 后核对 tracked 数与有无目录级 ` D`**（曾误删整个 `ios/`，用 `git restore --source=HEAD --staged --worktree ios/` 恢复）；`core.filemode=false` 时提交**不带 `-- paths`**。
- 双方都改的 append-only 文件（memory）会与远端冲突 → **先备份 → untracked 同名日志先移开（否则 merge 直接中止）→ `git checkout --` 还原 → merge → 再把两侧内容回填/追加**。占位符**禁用真实主机名与个人信息**。
- 🚨 **网络间歇被 TLS 拦截**（本机安全软件 HTTPS 扫描）：502 / `CRYPT_E_NO_REVOCATION_CHECK`(0x80092012) / openssl `20`。**首选 `-c http.sslBackend=schannel` 重试**（常第 1~3 次通过）；`schannelCheckRevoke=false` 无效。仅反复失败且**确认只读**才 `sslVerify=false`。SDK 包同样被掐断 → Python `urllib` + `HTTP Range` 续传。

## 全局作用域（勿混）＋端口
模型 per-Agent／授权 per-对话（safe|askAll|auto，TTL 300s=拒）／Agent per-对话（创建绑定）。`8787`=http；`15721`=model_proxy(503 正常)；同机 cc-switch 必互踩。
**没装 `gh` CLI** → Python `urllib` + git 凭据调 GitHub API；**绝不打印/落盘 token**。仓库 `banmu123/BrewPing` 公开；首 tag `v1.0.0`；⚠️ Windows 内部版本号仍 `0.1.0`。分发统一走 **GitHub Release**（Mac 三 DMG 变体 + Windows setup.exe/msi）；官网只作介绍页。

## iOS / Watch
- 只做 iPhone（`TARGETED_DEVICE_FAMILY=1`）；iOS 17；bundle `com.brewping.ios` / `.watchkitapp`。⚠️ ASC 截屏页签由**该版本所附构建**的 `UIDeviceFamily` 决定：带 `"1,2"` 就有 iPad 页签 → **解法是重新 Archive 上传，不是补图**。
- 🚨 新 Swift 文件登 pbxproj **四处**；译文 `%@` 个数=实参数 → 跑 `ios/Scripts/check_localization.py`。i18n：`Text("字面量")` 靠 `.environment(\.locale)`；String 用 L()/LW；`Text(变量)` 须 `LocalizedStringKey(变量)`。
- 🚨 **Bonjour 发现只能用 `NWBrowser.Result.endpoint` → `NWConnection`，绝不用 `NetService.resolve`**（真机/TestFlight 停摆到超时，模拟器却正常）。`remoteEndpoint` 可能是 IPv6 链路本地（`fe80::…%en0`）→ 非法 URL；须设 `internetProtocol.version = .v4` 并剥掉 `%en0`。
- 局域网明文 http；Bearer+Timestamp±120s+Nonce；改端点必同步 `DemoBackend.swift`。
- 🚨 **Logger 插值是 autoclosure**：插值里取实例属性必须 `self.xxx`（deinit 同样）。`BrewPingLog` 是 `os.Logger`，**无 `#if DEBUG` 门控，TestFlight 照常输出**。
- Mac 编译：`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`；scheme `BrewPing` / `BrewPing Watch App`；模拟器 iPhone 16 Pro `C7C7F583-310C-43CE-B6ED-D4915F465154`。
- 🚨 `kDNSServiceErr_PolicyDenied = -65570`；**-65555 是 `NoAuth`** → 别写字面值。**Xcode 直跑自动授权（不弹框）→ Debug 能发现 ≠ 权限没问题，必须 TestFlight 验**；Bonjour 浏览**不需要** multicast 权限。
- 🚨 **首装发现死锁（已修）**：iOS 无权限查询 API，**发起 Bonjour 浏览本身就是唯一查询方式**（旧 UserDefaults `hasEverBeenGranted` 门禁锁死首装）。现：进设备页**无条件** `startSearching()`；8s 定时器遇 `.waiting` 续期（≤3 次）；`PermissionCenter` 结论靠 `.onReceive(bonjour.$localNetwork)` 回灌。

## macOS 桌面端
- 🚨 `DesktopCommands.swift` 是 UI 唯一入口；UI 不直碰 Store/Gate；执行唯一路径 `ConversationCommandService` + `CommandRouter.shared`。
- 🚨 **对话执行状态单一来源 `Sources/App/ConversationRun.swift`**：阶段 idle/submitting/queued/thinking/streaming/stopping/completed/failed/stalled，**绑定 commandId + conversationId**（用 Agent 全局态会误伤同 Agent 的其它对话）；UI 只读 `indicator(now:)`，阈值全在 `RunTiming`（首字 8s / stalled 30s / 停止确认 10s / UI 合并 100ms）；**必须放 `Sources/App/`**（链 SwiftUI 的 `BrewPingDesktop` 会让测试启动 GUI）。
  💡 后端推**累积全文** → 过时帧按「前缀关系」判定（相同=重复、严格前缀=过时、`done=true` 一律接受），无需序号。
  DesktopAppState：`runs` **按 conversationId 分桶**（切对话时 `cancelRunTracking()` **不得清 runs**）；delta 先入 `pendingDelta` 100ms 合并；`fetchGeneration` 防慢返回覆盖新对话；`reconcileRun` **只认 assistant/error** 才终结命令（user 同 commandId 只撤乐观占位），无条目但 `latestCommandId` 非空补 thinking。
- 🚨 **状态粒度必须一致**（同日同族 bug）：TerminalState 按 Agent 归属、busy 按对话 → 串台；流式占位按 commandId 判定而 **commandId 跨 role 复用** → 每次取到 user 消息就误清气泡。**凡「按 X 归属」的状态，判定侧必须额外校验归属维度与语义角色**。
- ⚠️ `DesktopStrings.swift` 与 TS 端对齐**仅限 Setup Wizard（`sw*`）组**；`chat.*`/`settings.*` 属 Mac 专有、改它们不必同步 TS；**仓库内无生成脚本**（旧记忆「机械生成、改文案两端同批」范围过宽，**已废**）。样式照 Latte 令牌（`LatteButtonStyle` 带内边距，纯图标传 `size:.icon`）。
- 🚨 NSTextView 必须 `scrollableTextView()`；高度钳在 `sizeThatFits`；Enter 走 `textView(_:doCommandBy:)`；空态居中 `.frame(minHeight:)`。流式期**跳过 Markdown 解析**（每帧全量分块会掉帧）、贴底滚动**不带动画**，落库后换回 MarkdownView。
- 验证 `swift build --disable-sandbox`（不加会静默失败）；配置验证走 `tools/verify-cli-config.sh`。**改完源码先用 `find Sources -name "*.swift" -newer <二进制>` 判断要不要重编**。
- 打包 `build-app.sh`（默认 arm64 release）+ `build-dmg.sh`：bundle id **统一 `com.brewping.desktop`**；Hardened Runtime **不开 App Sandbox**；⚠️ `release-mac.yml` 缺 `MACOS_*` secrets → **Mac 包只能本地打**。
- 🚨 **公证/发布**：① 单架构变体无需重编译 —— `lipo -thin` → 重签 app → 打 dmg → 签 dmg → 公证 → staple（profile `BrewPingNotary`）。② Apple 公证**会长时间排队**：`--wait` 报 `deadlineExceeded` **不代表失败**（已受理）→ 用 `submit` 拿 id + `info` 轮询；⚠️ 状态是 `In Progress` 整串，`awk '{print $2}'` 会截成 `In` 导致空转。③ 替换 Release 同名资产**必须先 DELETE**。④ 发布脚本**别用 `pipefail` 配 `grep`**（无匹配即误杀脚本）；`set -u` 下变量先初始化（全角冒号写进变量名 → `unbound variable`）。
- 🚨 **打 dmg 三坑**：① `hdiutil create -format` 只能配 `-srcfolder`/`-srcdevice`（建空白镜像用 `-size` + `-fs`）；② **dmg 自身也必须 codesign**，只公证 → `spctl` rejected，**先签名再公证**；③ **别用 dmgbuild**（挂 `/Volumes` + `ditto`，FDA 受限必失败）。✅ 正道：空白镜像 + `hdiutil attach -mountpoint` + cp + `ln -s /Applications` + detach + `convert UDZO`。

## Windows 桌面端
- 🚨 tokio Mutex 不可重入；HTTP 错误体永远 JSON（query 用 `Option<String>` 手工解析）。
- 🚨 **子进程一律走 `services::proc::hide_console(&mut cmd)`**：否则 CLI（`.cmd` 包装）每 spawn 一次弹黑窗。`CREATE_NO_WINDOW` =「**不新建**控制台」而非「剥离」→ **只在安装包/GUI 复现**，改完必须装包实测。
- 🚨 **单实例**：`services/single_instance.rs` 用 `CreateMutexW`；⚠️ `MAIN_WINDOW_TITLE` 与 `tauri.conf.json` 标题同批改。
- 🚨 **启动白屏 +「无响应」（已修）**：Tauri 2 窗口在 `setup()` **之前**已建好，事件循环等 setup 返回才转 → setup 里同步 `discover()` 会堵住消息泵。现：挪 `spawn_blocking` + `emit("refresh-agents")` + `index.html` 纯 CSS 占位页。
- 🚨 **「图标没换」先查 Windows 图标缓存**（`iconcache_*.db` mtime 比安装时间旧 = 旧缓存）；判定 exe 用哪张图 → `icon.ico` 的 PNG 帧原样嵌在 PE 的 RT_ICON，**字节比对**。
- 🚨 `src-tauri/src/lib.rs:1` 有 crate 级 `#![allow(dead_code, unused_variables)]` →「cargo check 零警告」**不能**当无死代码依据。**动态调用盲区**（看似零引用但不可删）：`@main`/`body`/`NSViewRepresentable`/`placeSubviews`/`URLProtocol`/Compose/`BackHandler`/CameraX；`Sources/Protocol/` **是活的**。
- ✅ **macOS `SystemCommand.run` 管道死锁已修**（2026-09-21）：改用 `readabilityHandler` 在 `waitUntilExit` **之前**持续排空管道（旧实现等退出才 read，长回复会在 pipe 写满后与子进程互等）；`terminationHandler` 必须在 `run` **之前**登记；超时路径 `terminate()` → 再等 5s → 关 handler；`onOutput` 回传**累积全文**。
- 🚨 厂商配置「路径表」被手工复制：Swift 4 份 / Rust 6 处，Rust `config_lock()` **4 份独立 `OnceLock` 互不相通** → 改一处必须全部同改。⚠️ 别往 `Sources/BrewPingwinDesktop` 放 .swift（`Package.swift` 只 exclude 了 `BrewPing`/`BrewPingDesktop`；`node_modules` 也应 exclude，否则 SwiftPM 报上万 unhandled file）。
- 鉴权 `route_layer` 全表；白名单仅 `POST /api/pair` + `GET /api/status`；GET 免 nonce。🚨 serde：`base_url` 必须显式 `rename="baseURL"`（否则白屏）；同 commandId 双条目撤流式占位只认 assistant/error。
- 配置基线（同源）：Claude 只覆盖 env；Codex `[model_providers]` name 必填 + 不碰 auth.json；pi 成对；OpenCode 深合并。对话级语义：模型 = `model_override` 成对 > Agent 偏好 > active；授权 = 对话档位 > 全局；草稿手选不写全局。

## 模型配置代理 / 授权
- 两套体系：①路由表 `model_providers.json` ②CLI 原生配置（模型发现唯一来源）；只②→503。🚨 Codex 接管必须 `wire_api="responses"`。
- 🚨 预设端点按 agent 分派：`provider_catalog` 每条带 `endpoints[AgentEndpoint]`；`/anthropic` 只属 Claude Code；Codex=OpenAI Responses；OpenCode/pi=OpenAI 兼容。⚠️ Windows 拉模型按顶层 `/anthropic` 匹配必失配（macOS 已修）。
- 授权三档 safe/askAll/auto，作用域=**全局**；检测点=命令进 agent 前（`ApprovalGate.shared.check`）；超时默认拒绝（TTL 300s）；危险模式本地内置正则，**绝不信任 agent 自报**。

## Android
- 🚨 **compileSdk / targetSdk = 36（Android 16）**：Play 自 **2026-08-31** 要求面向 API 36+。版本链：targetSdk 36 → compileSdk 36 → **AGP ≥ 8.9**（**8.10 最高正好 36**）→ Gradle ≥ 8.11.1 → JDK 17 → `platforms;android-36` + `build-tools;36.0.0`。
- 🚨 **API 37（Play 2027-08-31 强制）= 本地网络权限 `ACCESS_LOCAL_NETWORK`**（`NEARBY_DEVICES` 组）：NSD/mDNS、局域网 HTTP、`.local` 解析、OkHttp 全受影响 → 须声明 + 运行时请求 + 拒绝后降级手动 IP。**光改版本号会让发现功能整体失效。**
- 唯一出口 `DesktopApiClient.kt`；深链 singleTask + `onNewIntent setIntent`；NSD 不需要额外权限。改名走 `DeviceStore.renameDevice`；网络失败 `code=0` 单独分支；DELETE 无响应体，不能复用 `parseConversationMutation`。
- 🚨 `values/strings.xml` 新增前先 grep 同名 key；中英 key 集合须一致。用 `@ExperimentalMaterial3Api` 组件（`CenterAlignedTopAppBar` 等）必须加 `@OptIn`。
- 令牌存 **Android Keystore AES-256/GCM**（明文 SP 透明迁移，密文带 `v1:` 前缀）；Help/About = `HelpScreen.kt` + `BrewPingConfig.kt`。⚠️ `CommandReceiver.kt` 是死桩（生产从未调 `.receive()`），命令生命周期散在 `DesktopApiClient`/`HomeViewModel`/`ConversationDetailScreen`。
- 本机验证：`JAVA_HOME=<jdk17> ./gradlew.bat assembleDebug test`（单测 **83 × 2 变体 = 166**）。

## 其他
- BOM：`strip_prefix('\u{feff}')`，不只 JSON —— TOML/YAML 行首 BOM 会静默丢整段配置。8787 被旧进程占 → curl 打的是旧进程（先 `Get-NetTCPConnection`）；canonicalize 出 `\\?\` → `dunce::simplified`。
- 🚨 GitKraken 动过的仓库会留悬空 remote ref（`fetch` 报 `cannot lock ref`、`origin/main` 消失，objects 其实已下全）→ 写回 `refs/remotes/origin/<branch>` = 远程 sha 再 `fetch --all --prune`；不要先上 `remote prune`/`fetch --force`。
- 上架：隐私政策 https://banmu123.github.io/BrewPing/privacy.html（源 `docs/privacy.html`）；TEAM `TGA82PM3DZ`；不做国区。

## 工具与协作约定（踩过即写死）
- 🚨 **同一文件的多个编辑不得并行**（会「后写覆盖先写」静默丢改动），**改完必须回读关键行核对**。
- 🚨 **静态核对（括号平衡 / XML / 引用存在性）证明不了能编译** —— 有编译器就跑编译（本机 JS/TS/Rust/Java 都齐）。
- 🚨 **UI 判据禁止「未就绪即定论」**：空态/错误态必须等数据源**确认过一次**才渲染（iOS `discoverySettled`/`permissions.hasRefreshed`；Android `!discoveryRunning`/中性占位）。
- 提交：**分主题多个提交**（功能/文档/memory 分开），信息走 `.commit-msg-N.txt`（被 `.gitignore` 覆盖）。**不确定就不要删**；不为减行数而重构；「零警告/零引用」结论先确认检查本身没被关掉（`allow(dead_code)`、工具缺失）。
