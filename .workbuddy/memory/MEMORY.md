# BrewPing — 项目长期记忆

跨端：手机/Watch/Android 远程指挥电脑 Agent。`ios/`、`Sources/`（Mac=SwiftPM BrewPingCore/BrewPingDesktop/CLI；Win=BrewPingwinDesktop Tauri2+axum+React）、`Android/`。日志 append-only，写前必 Glob+Read 防覆盖。

## 环境事实（本机 Windows）
- 🚨 命令回显常坏 → 落盘再 Read；Start-Process/taskkill 沙箱拦、Stop-Process 可用；读文件一律 Read/Grep/Glob。
- 🚨 Git Bash coreutils 全缺、cd 坏、npm 是 WSL shim → 不 cd+全绝对路径，npm/tsc 用 `node.exe <全路径>`；长任务后台跑。
- WinPS5.1：写配置 `[System.IO.File]::WriteAllText`+UTF8 no-BOM；删文件 `[System.IO.File]::Delete`。
- Android：strings.xml 新 key 先 grep 重名；构建需 JDK 17。

## 全局作用域（勿混）＋端口
模型 per-Agent／授权 per-对话（safe|askAll|auto+对话覆盖；TTL 300s 超时=拒）／Agent per-对话（创建绑定）。
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
- ⚠️ 两处 Command::new（http_server.rs/lib.rs）同批改；cargo test 不链 tauri GUI（EventSink）；改 capabilities 后 cargo clean -p brewping-desktop；重启走 PowerShell `npm run tauri dev`（WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--no-sandbox）。
- 鉴权 route_layer 全表；白名单仅 POST /api/pair+GET /api/status；GET 免 nonce。
- 🚨 serde：base_url 必须显式 `rename="baseURL"`（否则 camelCase 派生 baseUrl→白屏）。
- 🚨 同 commandId 双条目：转录 user/assistant 共用 commandId；撤流式占位只认 assistant/error，否则 700ms 轮询误删气泡。
- TOML/JSON 基线（同源）：Claude 只覆盖 env；Codex [model_providers] name 必填+不碰 auth.json；pi 成对；OpenCode 深合并。
- 对话级语义：Agent 创建绑定；模型=model_override 成对>Agent 偏好>active；授权=对话档位>全局；草稿手选不写全局。偏好 ~/.brewping/*.json 一文件一，Stored #[serde(default)]，测试 with_path(temp)。
- Setup Wizard 存 localStorage brewping.setup.*三键，绝不自动安装。🚨 i18n sw* 键无点号才生成与 Mac 同名 LKey。

## 模型配置代理
- 两套体系：①转发路由表 model_providers.json ②CLI 原生配置（模型发现唯一来源）；只在②配→路由空→503。🚨 Codex 接管必须 wire_api="responses"。
- 🚨 预设端点按 agent 分派：provider_catalog 每条带 endpoints[AgentEndpoint]；/anthropic 只属 Claude Code；Codex=OpenAI Responses；OpenCode/pi=OpenAI 兼容。前端 resolvePresetEndpoint+applyPreset。⚠️ Windows 拉模型按顶层 /anthropic 匹配必失配（macOS 已修，待同批）。
- 特性开关 model-config-card.tsx 两 false，后端保留。

## 其他
- 上架：隐私政策 GitHub Pages；TEAM TGA82PM3DZ；不做国区。
