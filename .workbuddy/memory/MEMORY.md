# BrewPing — 项目长期记忆

跨端：手机/Watch/Android 远程指挥电脑 Agent。`ios/`、`Sources/`（Mac=SwiftPM 三 target；Win=Tauri2+axum+React）、`Android/`。日志 append-only，写前必 Glob+Read 防覆盖。

## 环境事实（本机 Windows）
- 🚨 命令回显常坏 → 落盘再 Read；Start-Process/taskkill 沙箱拦、Stop-Process 可用；读文件一律 Read/Grep/Glob。
- 🚨 前台 git rebase 被强杀曾毁 .git（refs/logs/pack 全丢）→ git 秒完成或后台落盘轮询；cwd 丢用 git -C；恢复=归档.git→init→fetch→reset→重提交。
- 🚨 Git Bash coreutils 全缺、cd 坏、npm 是 WSL shim → 不 cd+全绝对路径，npm/tsc 用 `node.exe <全路径>`；长任务后台跑。
- WinPS5.1：写配置 `[System.IO.File]::WriteAllText`+UTF8 no-BOM；删文件 `[System.IO.File]::Delete`。
- Android：strings.xml 新 key 先 grep 重名；构建需 JDK 17。

## 全局作用域（勿混）＋端口
模型 per-Agent／授权 per-对话（safe|askAll|auto，TTL 300s=拒）／Agent per-对话（创建绑定）。
`8787`=http；`15721`=model_proxy(503 正常)；同机 cc-switch 必互踩。

## iOS / Watch
- 只做 iPhone；iOS 17。
- 🚨 新 Swift 文件登 pbxproj 四处；🚨 译文 %@ 个数=实参数（多一个崩），改完跑 ios/Scripts/check_localization.py。
- i18n：`Text("字面量")` 靠 `.environment(\.locale)`；String 用 L()/LW；`Text(变量)` 必须 LocalizedStringKey(变量)。
- 局域网明文 http；Bearer+Timestamp±120s+Nonce；改端点必同步 DemoBackend.swift。

## macOS 桌面端
- 🚨 DesktopCommands.swift 是 UI 唯一入口；UI 不直碰 Store/Gate；执行类命令切后台队列；执行唯一路径 ConversationCommandService+CommandRouter.shared 唯一。
- DesktopStrings.swift 由 locales.ts 机械生成，改文案两端同批；样式照 Latte 令牌。
- 🚨 NSTextView 必须 scrollableTextView()；高度钳在 sizeThatFits；Enter 走 textView(_:doCommandBy:)。
- 徽章一律 .fixedSize() 永不压缩；空态居中=ScrollView frame(minHeight: 视口高)；验证 swift build --disable-sandbox。

## Windows 桌面端
- 🚨 tokio Mutex 不可重入；HTTP 错误体永远 JSON（query 用 Option<String> 手工解析）。
- ⚠️ 两处 Command::new（http_server.rs/lib.rs）同批改；cargo test 不链 tauri GUI（EventSink）；改 capabilities 后 cargo clean -p brewping-desktop；重启走 PowerShell `npm run tauri dev`+WEBVIEW2=--no-sandbox。
- 鉴权 route_layer 全表；白名单仅 POST /api/pair+GET /api/status；GET 免 nonce。
- 🚨 serde：base_url 必须显式 `rename="baseURL"`（否则 camelCase 派生 baseUrl→白屏）。
- 🚨 同 commandId 双条目：转录 user/assistant 共用 commandId；撤流式占位只认 assistant/error，否则 700ms 轮询误删气泡。
- TOML/JSON 基线（同源）：Claude 只覆盖 env；Codex [model_providers] name 必填+不碰 auth.json；pi 成对；OpenCode 深合并。
- 对话级语义：Agent 创建绑定；模型=model_override 成对>Agent 偏好>active；授权=对话档位>全局；草稿手选不写全局。偏好 ~/.brewping/*.json 一文件一，Stored #[serde(default)]，测试 with_path(temp)。
- Setup Wizard 存 localStorage brewping.setup.*三键，绝不自动安装。🚨 i18n sw* 键无点号才生成与 Mac 同名 LKey。

## 模型配置代理
- 两套体系：①路由表 model_providers.json ②CLI 原生配置（模型发现唯一来源）；只②→503。🚨 Codex 接管必须 wire_api="responses"。
- 🚨 预设端点按 agent 分派：provider_catalog 每条带 endpoints[AgentEndpoint]；/anthropic 只属 Claude Code；Codex=OpenAI Responses；OpenCode/pi=OpenAI 兼容。⚠️ Windows 拉模型按顶层 /anthropic 匹配必失配（macOS 已修，待同批）。
- 特性开关 model-config-card.tsx 两 false，后端保留。

## 其他
- 上架：隐私政策 GitHub Pages；TEAM TGA82PM3DZ；不做国区。

---

# 归档细节（2026-09-15 恢复自整理前版本；Windows 侧压缩时误删的长期条目）

## 本机 cc-switch（排查模型配置参照）
- `~/.cc-switch/cc-switch.db`(SQLite，providers 复合主键 `(id,app_type)`；settings_config 含明文 Key 只 select 非敏感列)；`settings.json` 有 currentProvider*。
- 只在「激活」时把配置投影进 CLI 文件（`~/.codex/config.toml` 等）；「文件里有=当前生效」。
- 🚨 同机装 cc-switch + BrewPing 接管**必然互踩**：cc-switch 激活时按自己格式整体投影覆盖 BrewPing 写的段。


## Android
- 改名走 `DeviceStore.renameDevice`；网络失败 code=0 单独分支。空状态单卡片与 iOS 同构。
- 唯一出口 `DesktopApiClient.kt`；深链 singleTask+onNewIntent setIntent；无 NSD 权限。
- 已归档区块独立于 dirGroups；DELETE 无响应体不能复用 parseConversationMutation。
- 🚨 `values/strings.xml` 新增前先 grep 同名 key。


## 授权确认
三档 safe/askAll/auto 作用域=全局；检测点=命令进 agent 前；超时默认拒绝（TTL 300s）；危险模式本地正则绝不信任 agent 自报。


## BOM / 编码
`strip_prefix('\u{feff}')`；不只 JSON：TOML/YAML 行首 BOM 会静默丢整段配置（两端均已修）。


## 已知坑
- 8787 被旧进程占→curl 静默打旧进程（先 Get-NetTCPConnection 核对）。
- canonicalize 出 `\\?\`→dunce::simplified；进程名 brewping-desktop。


## 上架
隐私政策在 GitHub Pages；TEAM TGA82PM3DZ；待重新 Archive；暂不做国区。


## macOS 桌面端（详细版，与简版互补）
- 🚨 `DesktopCommands.swift` 是 UI 唯一入口；UI 不得直碰 Store/Gate；执行类命令切后台队列。
- 单一执行路径 `ConversationCommandService`；`CommandRouter.shared` 全局唯一。
- i18n：`DesktopStrings.swift` 由 locales.ts 机械生成，改文案两端同批；主题/尺寸照 Latte 令牌。
- 🚨 NSTextView：必须 `scrollableTextView()`；高度钳制在 sizeThatFits；Enter 走 `textView(_:doCommandBy:)`。
- 改完必 `swift build --disable-sandbox`；本机无 Xcode 完整工具链，验证走 `./tools/verify-cli-config.sh`。
- CLI 原生厂商面板样式（`CLIProviderPanels.swift`）：三层 = `cliCard`（淡主色底+主色描边，与"自有库"中性卡片刻意区分）/ `cliRowCard`（一条厂商一描边块，当前项主色高亮）+`cliInset` / `cliLabelValue`（标签定宽+等宽值）。间距节奏 **块内 4–6 / 块间 8 / 组间 12**，靠"块间>块内"分组，不靠加线。
- 🚨 行内截断策略对齐 Windows：**徽章一律 `.fixedSize()`（永不压缩），只有 URL 走 `.truncationMode(.middle)`**。否则 HStack 里的 Spacer 会与文本抢配额 → 「已配 Key」被压成「已配…」。`LatteBadge` 垂直内边距已从 0 调成 1.5（原来胶囊被压成一条线）。
- 预览截图技巧：debug 实例窗口默认 560×620 而设置页要 780 宽 → **右侧会被裁**；临时把 `DesktopRootView` 的 `minWidth` 改大即可拍全（截完必还原）。`screencapture -l <winID>` 拍的是"点"尺寸 × 屏幕缩放（本机 1.739×）。

## macOS 按钮样式约定
- `LatteButtonStyle` 自带内边距：`regular`（默认，文本钮 12/5）/ `icon`（方形图标钮 6/6）。**纯图标按钮必须传 `size: .icon`** 且不要再套 `.frame(width:height:)`（会裁掉内边距）；字号尊重调用处（样式不再强制 sm）。
- 空态问候垂直居中的写法：ScrollView 内容 `.frame(minHeight: 视口高)`（GeometryReader），不要直接把内容丢进 ScrollView（会顶在页首）。
