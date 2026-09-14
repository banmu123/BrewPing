# BrewPing — 项目长期记忆

跨端工具：手机/Watch/Android 远程指挥电脑 AI Agent。`ios/`（主App+watchOS）、`Sources/`（Mac SwiftPM：`BrewPingCore`/`BrewPingDesktop`/CLI；`BrewPingwinDesktop`=Win Tauri2+axum+React）、`Android/`。

## 环境事实（本机 Windows）
- 🚨 命令回显常坏 → PowerShell `2>&1 | Out-File -Encoding utf8 落盘` 再 Read；读文件一律 Read/Grep/Glob。
- 🚨 Git Bash coreutils 全缺且 `cd` 坏、`npm` 解析到 WSL shim → 不 cd + 全绝对路径。npm：`node.exe C:/Users/czk/.workbuddy/binaries/node/versions/22.22.2-3/node_modules/npm/bin/npm-cli.js --prefix <项目> <cmd>`；tsc 同理 `node.exe node_modules/typescript/bin/tsc`。
- 🚨 长任务用 Bash `run_in_background=true`（`Start-Process`/`Start-Job` 被策略拒）。
- WinPS5.1 `Remove-Item` 无 `-LiteralPath` 用 `-Path`；`Set-Content -Encoding utf8` 写 BOM → 写配置用 `[System.IO.File]::WriteAllText($p,$t,(New-Object System.Text.UTF8Encoding $false))`。
- Android 构建需 JDK 17（本机 JAVA_HOME 是 JDK 25，Gradle 不认四段版本号）。

## 全局作用域（勿混）
模型 **per-Agent**／授权 **per-对话**（全局 safe|askAll|auto+对话覆盖）／Agent **per-对话**（创建时绑定）。

## 端口拓扑
`8787`=http_server(0.0.0.0)←排查入口；`15721`=model_proxy(127.0.0.1，503 属正常)。🚨 15721 与 cc-switch 冲突（两者默认都占用，启用前查占用）。

## 本机 cc-switch（排查模型配置参照）
- `~/.cc-switch/cc-switch.db`(SQLite，providers 复合主键 `(id,app_type)`；settings_config 含明文 Key 只 select 非敏感列)；`settings.json` 有 currentProvider*。
- 只在「激活」时把配置投影进 CLI 文件（`~/.codex/config.toml` 等）；「文件里有=当前生效」。
- 🚨 同机装 cc-switch + BrewPing 接管**必然互踩**：cc-switch 激活时按自己格式整体投影覆盖 BrewPing 写的段。

## iOS / Watch
- 只做 iPhone（TARGETED_DEVICE_FAMILY=1）；Bundle `com.brewping.ios(.watchkitapp)`；iOS 17.0。
- 🚨 新 Swift 文件登 pbxproj **四处**（BuildFile/FileReference/Group.children/Sources，grep -c ≥4）。
- 🚨 译文 `%@` 个数=实参数（多一个崩）；改完跑 `python3 ios/Scripts/check_localization.py`。
- i18n：`Text("字面量")` 靠 `.environment(\.locale)`；String 用 `L()`（Watch `LW`）；`Text(变量)` 必须 `LocalizedStringKey(变量)`。
- 局域网明文 http；鉴权 Bearer+Timestamp(±120s)+Nonce（GET 免 nonce）；token 存 Keychain。
- Demo 拦 `demo.brewping.local`；**改端点必同步 `DemoBackend.swift`**。
- 🚨 ModelStore 同步契约：响应带 configVersion；refresh 指纹没变 return 不动 state；`canSwitch`=`!models.isEmpty`；🔴 providerID+modelID 成对提交。

## Android
- 改名走 `DeviceStore.renameDevice`；网络失败 code=0 单独分支。空状态单卡片与 iOS 同构。
- 唯一出口 `DesktopApiClient.kt`；深链 singleTask+onNewIntent setIntent；无 NSD 权限。
- 已归档区块独立于 dirGroups；DELETE 无响应体不能复用 parseConversationMutation。
- 🚨 `values/strings.xml` 新增前先 grep 同名 key。

## macOS 桌面端（Sources/App + BrewPingDesktop）
- 🚨 `DesktopCommands.swift` 是 UI 唯一入口；UI 不得直碰 Store/Gate；执行类命令切后台队列。
- 单一执行路径 `ConversationCommandService`；`CommandRouter.shared` 全局唯一。
- i18n：`DesktopStrings.swift` 由 locales.ts 机械生成，改文案两端同批；主题/尺寸照 Latte 令牌。
- 🚨 NSTextView：必须 `scrollableTextView()`；高度钳制在 sizeThatFits；Enter 走 `textView(_:doCommandBy:)`。
- 改完必 `swift build --disable-sandbox`；本机无 Xcode 完整工具链，验证走 `./tools/verify-cli-config.sh`。

## Windows 桌面端（BrewPingwinDesktop）
- 🚨 tokio Mutex 不可重入；🚨 HTTP 错误体永远 JSON（query 参数用 Option<String> 手工解析）。
- ⚠️ 两处 `Command::new`（http_server.rs/lib.rs）同批改；⚠️ cargo test 不得链 tauri GUI（EventSink 模式）。
- ⚠️ 改 capabilities/*.json 后必 `cargo clean -p brewping-desktop`；重启走 PowerShell `npm run tauri dev`（带 `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--no-sandbox"`）。
- 鉴权 route_layer 全表；白名单仅 POST /api/pair + GET /api/status。
- 对话级语义：Agent 创建时绑定；模型=model_override 成对>Agent 偏好>active；授权=对话档位>全局。草稿手选不写全局默认。
- 偏好 `~/.brewping/*.json` 一文件一偏好；Stored 带 `#[serde(default)]`；测试 with_path(temp)。
- ### 🚨 serde 字段名契约（白屏事故）
  `rename_all=camelCase` 把 `base_url` 派生成 `baseUrl`，而 DTO 约定 **`baseURL`** → 前端 undefined → 白屏。正确：`#[serde(rename = "baseURL", default)]`。前端有 normalize* 兜底 + error-boundary.tsx。新增跨 IPC DTO 必核对 key 大小写。
- ### 🚨 同 commandId 双条目（2026-09-14 闪断 bug）
  转录里 user 与 assistant 条目**共用同一 commandId**（submit 单一写出口）。前端撤流式占位**只认 assistant/error**；若连 user 也算，busy 期间每 700ms 转录轮询会误删气泡 → 「内容闪没→思考中→内容再现」循环。
- ### 四条 TOML/JSON 基线（与 macOS 同源）
  Claude：只覆盖 env 且就地合并；Codex：`[model_providers.<key>]` name 必填、保留 id openai/ollama/lmstudio、不碰 auth.json；pi：defaultProvider+Model 成对、不碰 auth.json；OpenCode：唯一真相=opencode.json，深合并绝不重建根节点。
  基线：`cargo test --lib` 300 passed / 1 ignored。

## 模型配置代理（cc-switch 迁移）
- 链路 `model_provider_store`→`model_proxy(15721)`+`model_transform`+`cli_takeover`+`provider_catalog`。
- 🚨 **两套体系互不相通**：① 转发代理路由表 `~/.brewping/model_providers.json`；② CLI 原生配置（模型发现唯一来源）。只在②配却接管→路由表空→503。
- 🚨 Codex 接管必须 `wire_api="responses"`（新版废弃 chat，写入即拒载整份 config.toml）；代理缺 responses→anthropic 转换，待补。
- 🚨 npm 装 `@openai/codex` 可能半残（optionalDependency 静默跳过）→ uninstall 后整体重装；切勿单独装 `@openai/codex@<ver>-win32-x64`（会覆盖主包）。
- 🚨 **预设端点按 agent 分派**（2026-09-14 对齐 cc-switch 源码实证）：`provider_catalog.rs` 每条带 `endpoints: [AgentEndpoint{agent, base_url, wire_api, npm, pi_api}]` —— **`/anthropic` 只属于 Claude Code**；Codex 用 OpenAI Responses 端点（五家全原生支持，DeepSeek=裸域 `api.deepseek.com`、智谱=`/api/v1` 三端点分立）；OpenCode/pi 用 OpenAI 兼容端点（`@ai-sdk/openai-compatible` / `openai-completions`）。顶层 base_url/api_format 仍是转发代理语义（Anthropic）。前端 `resolvePresetEndpoint(entry, agentId)` 解析，四表单 applyPreset(c, ep)：codex 联动 wireApi=responses、opencode 联动 npm、pi 联动 api（协议字段无条件覆盖，名称/baseURL 只填没填过的）。护栏 TC-PC-12/13。`codex_provider_config.rs::DEFAULT_WIRE_API="chat"` 未改（存量行为变更，建议后续单独评估）。macOS 侧 `ProviderCatalog.swift`/`CLIProviderPanels.swift` 尚未同步。
- 🚨 特性开关（model-config-card.tsx 均 false）：`SHOW_FORWARD_PROXY_SECTION`=厂商卡片列表；`SHOW_TAKEOVER_UI`=全部接管 UI。后端保留，置 true 恢复。
- 预设下拉共用 `vendor-preset-select.tsx`（VendorPresetSelect + groupCatalogByCategory + resolvePresetEndpoint），agentId 必传。

## 授权确认
三档 safe/askAll/auto 作用域=全局；检测点=命令进 agent 前；超时默认拒绝（TTL 300s）；危险模式本地正则绝不信任 agent 自报。

## BOM / 编码
`strip_prefix('\u{feff}')`；不只 JSON：TOML/YAML 行首 BOM 会静默丢整段配置（两端均已修）。

## 已知坑
- 8787 被旧进程占→curl 静默打旧进程（先 Get-NetTCPConnection 核对）。
- canonicalize 出 `\\?\`→dunce::simplified；进程名 brewping-desktop。

## 上架
隐私政策在 GitHub Pages；TEAM TGA82PM3DZ；待重新 Archive；暂不做国区。
