# BrewPing — 项目长期记忆

跨端：手机/Watch/Android 远程指挥电脑 Agent。`ios/`、`Sources/`（Mac=SwiftPM 三 target；Win=Tauri2+axum+React）、`Android/`。
日志 append-only，写前必 Glob+Read 防覆盖。**本文件只留高频规则与触发条件，取证过程看当日日志。**

## 环境事实（本机 Windows）
- 🚨 命令回显常坏 → 落盘再 Read；沙箱拦 Start-Process/taskkill（Stop-Process 可用）。
- 🚨 Git Bash coreutils 缺失（`grep`/`head`/`ls` 可能都没有）、cd 坏、npm 是 WSL shim → 不 cd、全绝对路径、长任务后台跑。
  ⚠️ `cmd || echo "(无)"` 在工具缺失时会**假报「无命中」**（曾据此误判 `BackHandler` 不存在）→ 查找一律用 Grep/Glob 工具。
- 🆕 工具链**都在本机**，别再以「没有编译器」为由跳过验证：JDK 17 `D:\study\java\devlop\jdk17`（默认 `JAVA_HOME` 是
  jdk25，对 Gradle 8.14 偏新 → 显式指定 17）；Android SDK `D:\software\androidSDK`；Mac 侧完整 Xcode 在 `/Applications/Xcode.app`。
- WinPS5.1：写配置 `[System.IO.File]::WriteAllText` + UTF8 no-BOM；删文件 `[System.IO.File]::Delete`。
- 🚨 前台 git rebase 被强杀曾毁 .git → git 要么秒完成要么后台落盘轮询；cwd 丢用 `git -C`。
- 🚨 **推送前必须先拉取**（用户明令）：`fetch` → `rev-list --left-right --count` → 落后则 **merge（绝不用 rebase）**
  → **merge 后立刻核对有无目录级 ` D`**（记录 merge 前后 `git ls-files` 数量；曾误删整个 `ios/`，
  靠 `git restore --source=HEAD --staged --worktree ios/` 零损失恢复）→ 再 push。
- 🚨 `core.filemode=false` 时 `git commit -F msg -- <paths>` 会把 chmod=+x 打回 100644 → 提交**不带 `-- paths`**。
- memory 这类双方都改的 append-only 文件会与远端冲突 → 合并前备份、`git checkout --` 还原，merge 完再追加回去。
  ⚠️ 本地 untracked 的同名日志会**直接挡住 merge** → 先移开再合并，最后把两侧内容都回填。
- 示例文案/占位符**禁用真实主机名与个人信息**（曾把 Mac 主机名 `Chenzk` 写进设备名示例 → 已换 `My Mac`/`我的 Mac`）。
- 🚨 **网络间歇性被 TLS 拦截**（`netsh winhttp show proxy` 显示「直接访问」→ 多为本机安全软件 HTTPS 扫描）：
  git 报 502 / `CRYPT_E_NO_REVOCATION_CHECK` / openssl `20` → 重试 2~3 次 → `-c http.schannelCheckRevoke=false`
  → `-c http.sslBackend=openssl`；最终手段加 `-c http.sslVerify=false`（**仅只读操作、绝不持久化**）。
  Android SDK 包同样被掐断（AGP 报 `Error on ZipFile unknown archive`）→ Python `urllib` + HTTP `Range` 断点续传。

## 全局作用域（勿混）＋端口
模型 per-Agent／授权 per-对话（safe|askAll|auto，TTL 300s=拒）／Agent per-对话（创建绑定）。
`8787`=http；`15721`=model_proxy(503 正常)；同机 cc-switch 必互踩。
- **没装 `gh` CLI** → Python `urllib` + git 凭据（GCM）调 GitHub API；**绝不打印/落盘 token**。
  仓库 `banmu123/BrewPing` **公开**；首个 tag = `v1.0.0`。⚠️ Windows 内部版本号仍是 `0.1.0`（与资产名 `1.0.0` 不一致）。
- 分发统一走 **GitHub Release**（Mac 三个 DMG 变体 + Windows setup.exe/msi）；官网只作介绍页。

## iOS / Watch
- 只做 iPhone（`TARGETED_DEVICE_FAMILY=1`）；iOS 17；bundle `com.brewping.ios` / `.watchkitapp`。
  ⚠️ ASC 截屏页签由**该版本所附构建**的 `UIDeviceFamily` 决定：历史构建若带 `"1,2"` 就会出现 iPad 页签 →
  **解法是重新 Archive 上传新构建，不是补图**。
- 🚨 新 Swift 文件登 pbxproj **四处**（`grep -c` ≥4）；译文 `%@` 个数=实参数 → 改完跑 `ios/Scripts/check_localization.py`。
- i18n：`Text("字面量")` 靠 `.environment(\.locale)`；String 用 L()/LW；`Text(变量)` 必须 `LocalizedStringKey(变量)`。
- 🚨 **Bonjour 发现只能用 `NWBrowser.Result.endpoint` → `NWConnection`，绝不用 `NetService.resolve`**
  （真机/TestFlight 上解析停摆至超时，模拟器却正常；旧实现已于 2026-09-17 验证通过后删除）。
- 🚨 `NWConnection.currentPath?.remoteEndpoint` 可能是 IPv6 链路本地（`fe80::…%en0`）→ 拼出非法 URL。必须固定 IPv4：
  `(params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4`（需转型；枚举是 `.v4`/`.v6`）；
  `NWEndpoint.Host` 的 `%en0` 后缀要剥掉。
- 局域网明文 http；Bearer+Timestamp±120s+Nonce；改端点必同步 `DemoBackend.swift`。
- 🚨 **Logger 插值是 autoclosure**：插值里取**实例属性**必须 `self.xxx`（deinit 里也一样）；别用 `+` 拼 Logger 字符串。
  `BrewPingLog` 是 `os.Logger`，**无 `#if DEBUG` 门控，TestFlight 照常输出**。
- Mac 编译：`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`（免 sudo）；scheme `BrewPing` /
  `BrewPing Watch App`；模拟器 iPhone 16 Pro `C7C7F583-310C-43CE-B6ED-D4915F465154`。
- 🚨 `kDNSServiceErr_PolicyDenied = -65570`；**-65555 是 `NoAuth`**。直接引用 C 符号别写字面值（曾写死 → 真被拒被判成「还在等授权」）。
- 本地网络：**Xcode 直跑会自动授权（不弹框）→ Debug 能发现不代表权限没问题，必须 TestFlight 验**；
  Bonjour 浏览**不需要** `com.apple.developer.networking.multicast`。
- 🚨 **首装发现死锁（已修）**：iOS 无权限查询 API，**发起 Bonjour 浏览本身就是唯一查询方式**。旧代码拿 UserDefaults
  `hasEverBeenGranted`（只在 `.ready` 写）当门禁 → 首装 false → 不浏览 → 永不 ready → 永远 false。现：进设备页
  **无条件** `startSearching()`；flag 只作首帧近似值；8s 定时器遇 `.waiting`（授权框还挂着）**续期**（上限 3 次）。
- `PermissionCenter` 只在 `attach()` 同步一次 → 结论要回灌 `.onReceive(bonjour.$localNetwork) { _ in permissions.refresh() }`。

## macOS 桌面端
- 🚨 `DesktopCommands.swift` 是 UI 唯一入口；UI 不直碰 Store/Gate；执行唯一路径 `ConversationCommandService` + `CommandRouter.shared`。
- `DesktopStrings.swift` 由 `locales.ts` 机械生成 → **改文案两端同批**（键名 ≡ LKey rawValue）；样式照 Latte 令牌
  （`LatteButtonStyle` 自带内边距，纯图标传 `size:.icon`；徽章一律 `.fixedSize()`）。
- 🚨 NSTextView 必须 `scrollableTextView()`；高度钳在 `sizeThatFits`；Enter 走 `textView(_:doCommandBy:)`。空态居中用 `.frame(minHeight:)`。
- 验证 `swift build --disable-sandbox`（不加会静默失败）；配置验证另走 `tools/verify-cli-config.sh`。
- 打包 `Scripts/build-mac-app.sh` + `build-dmg.sh`：bundle id **统一 `com.brewping.desktop`**（9-15/9-16 老包是
  `local.brewping.desktop`，已废弃）；Hardened Runtime **不开 App Sandbox**；Developer ID→notarytool→staple。
  ⚠️ `release-mac.yml` 因缺 `MACOS_*` 证书 secrets 在 import 步失败 → **Mac 包只能本地打**。
- 🚨 **打 dmg 的两个坑**（曾误判成 FDA 权限问题绕大弯）：① `hdiutil create -format` **只能配 `-srcfolder`/`-srcdevice`**，
  建空白镜像要写 `hdiutil create -size 200m -fs HFS+ -volname "X" raw.dmg`；② **dmg 自身也要
  `codesign --sign <Developer ID> --timestamp`**，只公证不签名 → `spctl` 判 `rejected / source=no usable signature`，
  且**先签名、再公证**（签名会改内容）。
- 🚨 **别用 dmgbuild**：它挂 `/Volumes` 后 `ditto` 写入，FDA 受限必失败（`ditto: Operation not permitted`），
  且失败只留 40KB 空镜像极难排查。✅ 改用 空白镜像 + `hdiutil attach -mountpoint /tmp/xxx` + cp +
  `ln -s /Applications` + detach + `hdiutil convert -format UDZO`（全程不碰 `/Volumes`）。
- 💡 **单架构变体不用重编译**：对已签名的 Universal app 用 `lipo -thin arm64/x86_64` 抽架构 → 重签 app → 打 dmg
  → 签 dmg → 公证 → staple（两变体约 1.5 分钟）。notary profile 统一 **`BrewPingNotary`**（`--wait` 约 35-40s Accepted）。

## Windows 桌面端
- 🚨 tokio Mutex 不可重入；HTTP 错误体永远 JSON（query 用 `Option<String>` 手工解析）。
- 🚨 **子进程一律走 `services::proc::hide_console(&mut cmd)`**：否则 CLI（`.cmd` 包装）每 spawn 一次弹黑窗。
  `CREATE_NO_WINDOW` =「**不新建**控制台」而非「剥离」→ **只在安装包/GUI 复现**，dev 与单测看不出，改完必须装包实测。
  ⚠️ debug 构建自身带控制台（`windows_subsystem` 仅 release）。
- 🚨 **单实例**：`services/single_instance.rs` 用 `CreateMutexW` 具名互斥体；⚠️ `MAIN_WINDOW_TITLE` 与 `tauri.conf.json` 标题必须同批改。
- 🚨 **启动白屏 +「无响应」根因**：Tauri 2 窗口在 `setup()` **之前**已建好（`app.rs:2524`），事件循环等 setup 返回才转 →
  setup 里同步跑 `discover()`（4 个 CLI 各 spawn `--version`）会堵住消息泵。现：探测挪 `spawn_blocking` → 回填状态 +
  `emit("refresh-agents")`；主窗口 `set_background_color`；`index.html` 加纯 CSS 占位页。埋点 `setup completed in …`。
- 🚨 **「图标没换」先查 Windows 图标缓存**（`iconcache_*.db` mtime 比安装时间旧 = 读旧缓存；`ie4uinit -show` 常刷不掉）。
  判定 exe 用的哪张图 → **`icon.ico` 的 PNG 帧原样嵌在 PE 的 RT_ICON，直接字节比对**。
- 🚨 **`src-tauri/src/lib.rs:1` 有 crate 级 `#![allow(dead_code, unused_variables)]`** → 「cargo check 零警告」**不能**作为无死代码的依据。
- 🚨 **动态调用盲区**（看似零引用但**一条都不能删**）：XCTest/`@main`/`body`/`NSViewRepresentable`/`Layout.placeSubviews`/
  `URLProtocol`/`NetServiceDelegate`/Compose/`BackHandler`/CameraX；带缩进的 `var/let` 正则抓不到。`Sources/Protocol/` **是活的**。
- 🚨 **macOS `SystemCommand.run`（`Sources/Agents/AgentDiscovery.swift:107-131`）先 `waitUntilExit()` 再读 pipe**
  → 输出超 64KB 管道缓冲即死锁 → 超时 nil → 报成误导性的「Failed to launch」。Windows 同款坑已在 `command_runner.rs:378`
  修好，**macOS 未修**。
- 🚨 厂商配置「路径表」被手工复制：Swift 4 份、Rust 6 处；Rust `config_lock()` **4 份独立 `OnceLock<Mutex<()>>`、互不相通**。
- ⚠️ `Package.swift` 的 `BrewPingCore` 用 `path: "Sources"` 只 exclude 了 `BrewPing`/`BrewPingDesktop` →
  `Sources/BrewPingwinDesktop` 在其递归路径内，往那儿放 .swift 会被编进 macOS 核心库。
- 鉴权 `route_layer` 全表；白名单仅 `POST /api/pair` + `GET /api/status`；GET 免 nonce。
- 🚨 serde：`base_url` 必须显式 `rename="baseURL"`（否则白屏）；同 commandId 双条目时撤流式占位只认 assistant/error，
  否则 700ms 轮询误删气泡。
- 配置基线（同源）：Claude 只覆盖 env；Codex `[model_providers]` name 必填 + 不碰 auth.json；pi 成对；OpenCode 深合并。
- 对话级语义：模型 = `model_override` 成对 > Agent 偏好 > active；授权 = 对话档位 > 全局；草稿手选不写全局。

## 模型配置代理 / 授权
- 两套体系：①路由表 `model_providers.json` ②CLI 原生配置（模型发现唯一来源）；只②→503。🚨 Codex 接管必须 `wire_api="responses"`。
- 🚨 预设端点按 agent 分派：`provider_catalog` 每条带 `endpoints[AgentEndpoint]`；`/anthropic` 只属 Claude Code；
  Codex=OpenAI Responses；OpenCode/pi=OpenAI 兼容。⚠️ Windows 拉模型按顶层 `/anthropic` 匹配必失配（macOS 已修，待同批）。
- 授权三档 safe/askAll/auto，作用域=**全局**；检测点=命令进 agent 前（`ApprovalGate.shared.check`）；超时默认拒绝（TTL 300s）；
  危险模式本地内置正则，**绝不信任 agent 自报**。

## Android
- 🚨 **compileSdk / targetSdk = 36（Android 16）**：Play 自 **2026-08-31** 要求新 App 与更新面向 API 36+。版本链绑定：
  targetSdk 36 → compileSdk 36 → **AGP ≥ 8.9**（**AGP 8.10 支持的最高 API 正好是 36**，再往上必须升 AGP）
  → Gradle ≥ 8.11.1 → JDK 17 → SDK `platforms;android-36` + `build-tools;36.0.0`。
- 🚨 **API 37（Play 2027-08-31 强制）= 本地网络权限 `ACCESS_LOCAL_NETWORK`**（属 `NEARBY_DEVICES` 组）：本地网络默认封闭，
  **NSD/mDNS、局域网 HTTP、`.local` 解析、OkHttp 全受影响** → 迁移时须声明 + 运行时请求 + 拒绝后降级到手动 IP。
  **光改版本号会让发现功能整体失效。**
- 唯一出口 `DesktopApiClient.kt`；深链 singleTask + `onNewIntent setIntent`；NSD 不需要额外权限。
- 改名走 `DeviceStore.renameDevice`；网络失败 `code=0` 单独分支；已归档区块独立于 dirGroups；DELETE 无响应体，
  不能复用 `parseConversationMutation`。
- 🚨 `values/strings.xml` 新增前先 grep 同名 key；中英 key 集合必须一致。
- 🚨 用 `@ExperimentalMaterial3Api` 的组件（`CenterAlignedTopAppBar` / `TopAppBarDefaults.*TopAppBarColors`）
  必须加 `@OptIn(ExperimentalMaterial3Api::class)`，否则编不过。
- 配对令牌存 **Android Keystore AES-256/GCM**（明文 SP 透明迁移，密文带 `v1:` 前缀）；Help/About = `HelpScreen.kt` +
  `BrewPingConfig.kt`。⚠️ `CommandReceiver.kt` 是 23 行死桩（生产代码从未调 `.receive()`），命令生命周期实际散在
  `DesktopApiClient`/`HomeViewModel`/`ConversationDetailScreen`。
- 本机验证：`JAVA_HOME=<jdk17> ./gradlew.bat assembleDebug test`（单测 **83 × 2 变体 = 166**）。

## 其他
- BOM：`strip_prefix('\u{feff}')`，不只 JSON —— TOML/YAML 行首 BOM 会静默丢整段配置。
- 已知坑：8787 被旧进程占 → curl 静默打旧进程（先 `Get-NetTCPConnection` 核对）；canonicalize 出 `\\?\` → `dunce::simplified`。
- 🚨 **GitKraken 动过的仓库会出现悬空 remote-tracking ref**：`.git/packed-refs` 缺失 + `.git/refs/remotes/origin/` 空 →
  `fetch` 报 `cannot lock ref`、`origin/main` 消失（objects/FETCH_HEAD 其实已下全）。**修法**：写回
  `.git/refs/remotes/origin/<branch>` = 远程 sha（UTF8 no-BOM，末尾 `\n`），再 `fetch --all --prune`；
  **不要**先上 `git remote prune` / `fetch --force`。
- 上架：隐私政策 https://banmu123.github.io/BrewPing/privacy.html（源 `docs/privacy.html`）；TEAM `TGA82PM3DZ`；不做国区。

## 工具与协作约定（踩过即写死）
- 🚨 **同一文件的多个编辑不得并行发起**（会「后写覆盖先写」静默丢改动）。**改完必须回读关键行核对**。
- 🚨 **静态核对（括号平衡 / XML / 引用存在性）证明不了能编译** —— 有编译器就跑编译（本机 JS/TS/Rust/Java 都齐）。
- 🚨 **UI 判据禁止「未就绪即定论」**：空态/错误态都必须等数据源**确认过一次**才渲染（iOS `discoverySettled`/
  `permissions.hasRefreshed`；Android `!discoveryRunning`/中性占位）。瞬时未知只显示中性占位。
- 提交：用户偏好**分主题多个提交**（功能/文档/memory 分开），信息走 `.commit-msg-N.txt`（被 `.gitignore` 覆盖）。
- **不确定就不要删**；不为了减少行数而重构；任何「零警告/零引用」结论先确认检查本身没被关掉（`allow(dead_code)`、工具缺失）。
