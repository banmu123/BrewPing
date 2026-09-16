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
- 局域网明文 http；Bearer+Timestamp±120s+Nonce；改端点必同步 `DemoBackend.swift`。

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
