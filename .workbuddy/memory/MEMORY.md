# BrewPing — 项目长期记忆

跨端：手机/Watch/Android 远程指挥电脑 Agent。`ios/`、`Sources/`（Mac=SwiftPM 三 target；Win=Tauri2+axum+React）、`Android/`。日志 append-only，写前必 Glob+Read 防覆盖。

## 环境事实（本机 Windows）
- 🚨 命令回显常坏 → 落盘再 Read；沙箱拦 Start-Process/taskkill（Stop-Process 可用）；读文件一律 Read/Grep/Glob。
- 🚨 Git Bash coreutils 全缺、cd 坏、npm 是 WSL shim → 不 cd、全绝对路径；npm/tsc 用 `node.exe <全路径>`；长任务后台跑。
- WinPS5.1：写配置 `[System.IO.File]::WriteAllText` + UTF8 no-BOM；删文件 `[System.IO.File]::Delete`。
- 🚨 前台 git rebase 被强杀曾毁 .git → git 操作要么秒完成要么后台落盘轮询；cwd 丢用 `git -C`。
- 🚨 **推送前必须先拉取**（用户明令）：`fetch` → `rev-list --left-right --count` → 落后则 **merge（绝不用 rebase）** → **merge 后立刻核对有无目录级 ` D`**（配合记录 merge 前后 `git ls-files` 数量，曾误删整个 `ios/`，靠 `git restore --source=HEAD --staged --worktree ios/` 零损失恢复）→ 再 push。push 一律走 `PortableGit\bin\bash.exe`（PowerShell 下 exit 128）。
- 🚨 `core.filemode=false` 时 `git commit -F msg -- <paths>` 会把 chmod=+x 打回 100644 → 提交**不带 `-- paths`**，用 `git update-index --chmod=+x`。
- memory 日志这类双方都改的 append-only 文件会与远端冲突 → 合并前先备份、`git checkout --` 还原，merge 完再追加回去。

## 全局作用域（勿混）＋端口
模型 per-Agent／授权 per-对话（safe|askAll|auto，TTL 300s=拒）／Agent per-对话（创建绑定）。
`8787`=http；`15721`=model_proxy(503 正常)；同机 cc-switch 必互踩。

## iOS / Watch
- 只做 iPhone（`TARGETED_DEVICE_FAMILY=1`）；iOS 17；bundle `com.brewping.ios` / `.watchkitapp`。
- 🚨 新 Swift 文件登 pbxproj **四处**（`grep -c` ≥4）；🚨 译文 `%@` 个数=实参数（多一个崩），改完跑 `ios/Scripts/check_localization.py`。
- i18n：`Text("字面量")` 靠 `.environment(\.locale)`；String 用 L()/LW；`Text(变量)` 必须 `LocalizedStringKey(变量)`；Watch 语言随 WCSession 同步。
- 🚨 **iOS Bonjour 自动发现用 `NWBrowser.Result.endpoint` → `NWConnection`，绝不用 `NetService.resolve`**：真机/TestFlight 上 NetService 解析会在首帧不完整回调后停摆至超时（partial=1 → 10s → `netServiceDidStop`），而同一代码在模拟器正常、Mac 侧 dns-sd 记录也完整 → 该路径在真机不可用。旧实现（TrackedNetService/ResolveStage/ResolveStats/看门狗/NetServiceDelegate）**已于 2026-09-17 验证通过后整体删除**；屏幕诊断行（diag）同步移除，保留 `conn:` / `bonjour:` 等 os_log 作为长期排障入口。
- 🚨 `NWConnection.currentPath?.remoteEndpoint` 可能给出 **IPv6 链路本地**（`fe80::…%en0`）→ 下游 `http://\(host):\(port)` 会拼出非法 URL。探测参数必须**固定 IPv4**：`(params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4`（⚠️ `internetProtocol` 返回基类需转型；枚举是 `.v4`/`.v6`，不是 `.ipv4`）。另注意 `NWEndpoint.Host` 字符串可能带 `%en0` scope 后缀，要剥掉。
- 局域网明文 http；Bearer+Timestamp±120s+Nonce；改端点必同步 `DemoBackend.swift`。
- 🚨 **Logger 插值是 autoclosure**：`log.info("\(xxx, privacy: .public)")` 里引用**实例属性**必须写 `self.xxx`，否则 `Reference to property 'x' in closure requires explicit use of 'self'`；**deinit 里也一样**；局部变量与 `Self.xxx` 不受影响。另：别用 `+` 拼 Logger 字符串（收的是 `OSLogMessage`，一律单字面量）。
- 🆕 **本机（Mac）其实装了完整 Xcode**（`/Applications/Xcode.app`），只是 `xcode-select -p` 指向 CommandLineTools → 裸跑 `xcodebuild`/`simctl` 会报 requires Xcode / unable to find utility。**加环境变量即可，无需 sudo**：`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` → `xcodebuild` / `xcrun simctl` / `xcrun swiftc` 全部可用。**别再以「没有 Xcode」为由跳过本地编译与模拟器验证**（2026-09-17 修正，此前认知错误）。
  - 编译：`xcodebuild -project ios/BrewPing.xcodeproj -scheme BrewPing -destination 'generic/platform=iOS Simulator' -configuration Debug SYMROOT=/tmp/bp-sym OBJROOT=/tmp/bp-obj build CODE_SIGNING_ALLOWED=NO`（scheme `BrewPing` / `BrewPing Watch App`）。
  - 模拟器实跑：iPhone 16 Pro `C7C7F583-310C-43CE-B6ED-D4915F465154`；`simctl log stream --level debug --predicate 'subsystem BEGINSWITH "com.brewping"'` 抓 App 日志。
  - 快速单文件检查仍可用桩：`xcrun swiftc -typecheck -sdk "$(xcrun --show-sdk-path)" ios/Scripts/offline-typecheck-stub.swift <目标文件>`（跨文件符号误报忽略；缺符号往桩里补）。
- 🚨 **`kDNSServiceErr_PolicyDenied = -65570`**（`dns_sd.h:801`）；**-65555 是 `NoAuth`**。判「本地网络被拒」用 -65570 + -65571(`NotPermitted`)，**直接引用 C 符号 `kDNSServiceErr_PolicyDenied`（Swift 可见，已验证），别写字面值**。曾写死 -65555 → TF 上真被拒被判成「还在等授权」→ 不出被拒提示 + 永远扫不到设备。
- 本地网络：**Xcode 直跑会被自动授权（不弹框）→ Debug 能发现不代表权限没问题，必须 TestFlight 验**；Bonjour 浏览**不需要** `com.apple.developer.networking.multicast`（只有自己发 UDP 广播才需要）。
- `PermissionCenter` 只在 `attach()` 同步一次本地网络状态 → 自动探测的结论要回灌：`.onReceive(bonjour.$localNetwork) { _ in permissions.refresh() }`，否则 `allGranted` 恒假。
- 排查手法：`dns-sd -B _brewping._tcp` / `dns-sd -L <名> _brewping._tcp local.` 可在 Mac 上直接验广播侧是否正常（本轮据此排除桌面端）。

## macOS 桌面端
- 🚨 `DesktopCommands.swift` 是 UI 唯一入口；UI 不直碰 Store/Gate；执行类命令切后台队列；执行唯一路径 `ConversationCommandService` + `CommandRouter.shared` 唯一。
- `DesktopStrings.swift` 由 `locales.ts` 机械生成 → **改文案两端同批**（键名 ≡ LKey rawValue，sw* 无点号）；样式/尺寸照 Latte 令牌。
- 🚨 NSTextView 必须 `scrollableTextView()`；高度钳在 `sizeThatFits`；Enter 走 `textView(_:doCommandBy:)`。
- 徽章一律 `.fixedSize()`（只有 URL 走 middle 截断）；空态居中 = ScrollView 内容 `.frame(minHeight: 视口高)`。
- 按钮：`LatteButtonStyle` 自带内边距（regular 12/5、icon 6/6），纯图标必传 `size:.icon` 不再套 frame。
- CLI 厂商面板三层 `cliCard`/`cliRowCard`+`cliInset`/`cliLabelValue`；间距块内 4–6、块间 8、组间 12。
- 验证 `swift build --disable-sandbox`（不加会静默失败）；本机无完整 Xcode 工具链，配置验证走 `./tools/verify-cli-config.sh`。
- 打包：`build-app.sh` / `Scripts/build-mac-app.sh`，bundle id **统一 `com.brewping.desktop`**，Hardened Runtime **不开 App Sandbox**，Developer ID→notarytool→staple；`.github/workflows/release-mac.yml` 打 tag 发布（v1.0.0 已发布）。

## Windows 桌面端
- 🚨 tokio Mutex 不可重入；HTTP 错误体永远 JSON（query 用 `Option<String>` 手工解析）。
- ⚠️ 两处 `Command::new`（http_server.rs / lib.rs）同批改；cargo test 不链 tauri GUI（EventSink）；改 capabilities 后 `cargo clean -p brewping-desktop`；重启走 PowerShell `npm run tauri dev` + `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--no-sandbox`。
- 🚨 **子进程一律走 `services::proc::hide_console(&mut cmd)`**（唯一入口，别再加 `creation_flags`）：
  否则 CLI（`.cmd` 包装）每 spawn 一次弹一个 cmd 黑窗；启动时 `discover()` 对 4 个 agent
  各探测一次版本 → 「打开应用满屏黑框」。`CREATE_NO_WINDOW` 语义是「**不新建**控制台」而非
  「剥离控制台」→ **只在安装包/GUI 进程复现，dev 模式与单元测试都看不出来**，改完必须装包实测。
  ⚠️ debug 构建应用自身会带控制台（`windows_subsystem` 仅 release 生效）。
- 🚨 **单实例**：`services/single_instance.rs` 用 `CreateMutexW` 具名互斥体挡住第二个实例
  （拿到 EXISTS 就把已有窗口拎到前台再自己退出），接在 `run()` 最前面。无新依赖（只用
  `windows-sys`）。⚠️ `MAIN_WINDOW_TITLE` 与 `tauri.conf.json` 的窗口标题**必须同批改**。
- 🚨 **「图标没换」先查 Windows 图标缓存，别急着改代码**：取证顺序 =
  ① 直接渲染 `icons/*.png` 与 `icon.ico` 各帧 ② `git log --follow -- icons/icon.ico` 看是否换过图标
  ③ **`icon.ico` 的 PNG 帧原样嵌在 PE 的 RT_ICON 里 → 对 exe 做字节子串比对即可判定它用的是哪个图**
  （NSIS 的 setup.exe 自身压缩，比对不到属正常）④ 解析 `.lnk` 原始字节看 target/IconLocation
  ⑤ 查 `%LOCALAPPDATA%\Microsoft\Windows\Explorer\iconcache_*.db` 的 **mtime** ——
  比安装时间旧就说明任务栏/开始菜单读的是旧缓存（`ie4uinit.exe -show` 常常**刷新不掉**，
  得删缓存 + 重启 explorer）。
- 🚨 **`src-tauri/src/lib.rs:1` 有 `#![allow(dead_code, unused_variables)]`（crate 级）** → `cargo check` 的
  「零警告」不能作为 Rust 侧没有死代码的依据。查 Rust 死代码前先看这行是否还在。
- 🚨 **Swift 死代码审查方法**：正则抽符号 + 全仓词频交叉引用（别靠文件名猜）。**三个盲区必须人工补**：
  ① 带缩进的 `var/let` 属性抓不到；② XCTest / `@main` / SwiftUI `body` / `NSViewRepresentable` /
  `Layout.placeSubviews` / `URLProtocol` 覆写 / `NetServiceDelegate` / Compose / CameraX 全是动态调用，
  一律显示「零引用」但**一条都不能删**；③ 不同 target 的同名类型不算重复（`ConversationStore`/`ContentView`/
  `LatteTheme` 分属不同编译单元）。`Sources/Protocol/` **是活的**（`Provider`/`Model` 被 AgentConfigDiscovery、
  `FailureReason` 被 ErrorClassifier、`ProtocolStateService.snapshot` 被 HTTPAPI 用），只有 `Protocol/Model.swift` 死了。
- 🚨 **macOS `SystemCommand.run`（`Sources/Agents/AgentDiscovery.swift:107-131`）先 `waitUntilExit()` 再读 pipe**
  → 子进程输出超 64KB 管道缓冲即阻塞 → 超时返回 nil → 被报成「Failed to launch」（**误导性错误**）。
  Windows 同款坑已在 `command_runner.rs:378` 修好（注释写明「stderr 必须与 stdout 并发读」）——**macOS 未修**。
- 🚨 厂商配置「路径表」被手工复制：Swift 4 份（`AgentConfigDiscovery.configPaths` + 三个 `*ProviderConfig.configPaths`）、
  Rust 6 处；两端注释都自述「要保持一致」。另 Rust `config_lock()` **4 份各自独立 `OnceLock<Mutex<()>>`、互不相通**
  → 名为配置锁却挡不住跨模块并发写（隐藏缺陷）。
- ⚠️ `Package.swift` 的 `BrewPingCore` 用 `path: "Sources"` 只 `exclude: ["BrewPing","BrewPingDesktop"]`，
  **`Sources/BrewPingwinDesktop` 在其递归路径内** → 往那儿放 .swift 会被编进 macOS 核心库。
- 鉴权 `route_layer` 全表；白名单仅 `POST /api/pair` + `GET /api/status`；GET 免 nonce。
- 🚨 serde：`base_url` 必须显式 `rename="baseURL"`（否则派生 baseUrl → 白屏）。
- 🚨 同 commandId 双条目：转录 user/assistant 共用 commandId；撤流式占位只认 assistant/error，否则 700ms 轮询误删气泡。
- TOML/JSON 基线（同源）：Claude 只覆盖 env；Codex `[model_providers]` name 必填+不碰 auth.json；pi 成对；OpenCode 深合并。
- 对话级语义：Agent 创建绑定；模型 = `model_override` 成对 > Agent 偏好 > active；授权 = 对话档位 > 全局；草稿手选不写全局。偏好 `~/.brewping/*.json` 一文件一，`Stored` 带 `#[serde(default)]`，测试 `with_path(temp)`。
- Setup Wizard 存 `localStorage brewping.setup.*` 三键，绝不自动安装。

## 模型配置代理
- 两套体系：①路由表 `model_providers.json` ②CLI 原生配置（模型发现唯一来源）；只②→503。🚨 Codex 接管必须 `wire_api="responses"`。
- 🚨 预设端点按 agent 分派：`provider_catalog` 每条带 `endpoints[AgentEndpoint]`；`/anthropic` 只属 Claude Code；Codex=OpenAI Responses；OpenCode/pi=OpenAI 兼容。⚠️ Windows 拉模型按顶层 `/anthropic` 匹配必失配（macOS 已修，待同批）。
- 特性开关 `model-config-card.tsx` 两 false，后端保留。

## 授权确认
三档 safe/askAll/auto，作用域=**全局**；检测点=命令进 agent 前（`ApprovalGate.shared.check`）；超时默认拒绝（TTL 300s）；危险模式本地内置正则，**绝不信任 agent 自报**。

## Android
- 改名走 `DeviceStore.renameDevice`；网络失败 `code=0` 单独分支；空状态单卡片与 iOS 同构。
- 唯一出口 `DesktopApiClient.kt`；深链 singleTask+`onNewIntent setIntent`；无 NSD 权限。
- 已归档区块独立于 dirGroups；DELETE 无响应体，不能复用 `parseConversationMutation`。
- 🚨 `values/strings.xml` 新增前先 grep 同名 key；构建需 JDK 17。

## 其他
- BOM：`strip_prefix('\u{feff}')`，不只 JSON —— TOML/YAML 行首 BOM 会静默丢整段配置。
- 已知坑：8787 被旧进程占 → curl 静默打旧进程（先 `Get-NetTCPConnection` 核对）；canonicalize 出 `\\?\` → `dunce::simplified`；进程名 `brewping-desktop`。
- 🚨 **GitKraken 动过的仓库会出现「悬空 remote-tracking ref」**：`.git/packed-refs` 缺失 +
  `.git/refs/remotes/origin/` 空目录 → `fetch` 报 `cannot lock ref ... unable to resolve reference`，
  `origin/main` 整个消失（`for-each-ref` 只剩 `refs/heads/main`），但 objects/FETCH_HEAD 其实已下全。
  **修法**：直接写回 `.git/refs/remotes/origin/<branch>` = 远程 sha（UTF8 no-BOM，末尾 `\n`），
  再 `fetch --all --prune` 即恢复；**不要**先上 `git remote prune` / `fetch --force` 折腾。
  排查入口：`.git/gk/config` 的 `gk-last-accessed`（能看出 GitKraken 何时动过）。
- 上架：隐私政策 GitHub Pages；TEAM `TGA82PM3DZ`；不做国区。
- 本机 cc-switch（排查参考）：`~/.cc-switch/cc-switch.db`（providers 复合主键 `(id,app_type)`；settings_config 含明文 Key 只 select 非敏感列）；只在「激活」时投影进 CLI 文件。

## 工具与协作约定（踩过即写死）
- 🚨 **同一文件的多个编辑不得并行发起**：并行 Edit 同文件会「后写覆盖先写」、静默丢改动
  （曾在 `ContentView.swift` 丢过一处判据，直到核对截图+回读源码才发现）。**改完必须回读
  关键行核对**（grep/python 断言）。
- 🚨 **UI 判据禁止「未就绪即定论」**：任何空态/错误态（「没有桌面端」「未授权」「未配对」）
  都必须等数据源**确认过一次**才渲染 —— iOS 的 `discoverySettled` / `permissions.hasRefreshed`、
  Android 的 `!discoveryRunning` / `device == null → 中性占位` 是同一规则的落地。
  瞬时未知（搜索中、异步物化中、状态未读）只能显示中性占位。
- 模拟器取证：权限状态可直接写 `<device>/data/Library/TCC/TCC.db`（关机状态写），
  `simctl uninstall` 会清掉；首帧类 bug 用「连拍 16 帧 + 逐帧 md5 比对」定位。
