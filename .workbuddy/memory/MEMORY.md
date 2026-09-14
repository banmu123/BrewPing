# BrewPing — 项目长期记忆

跨端工具：iPhone/Watch/Android 远程指挥电脑 AI Agent。目录：`ios/`（主 App+watchOS）、`Sources/`（Mac SwiftPM：`BrewPingCore`/`BrewPingDesktop`/CLI；`BrewPingwinDesktop`=Win Tauri2+axum+React）、`Android/`、`design/`。

## 环境事实（本机 Windows）
- 🚨 命令回显常坏 → `2>&1 | Out-File -Encoding utf8 落盘` 再 Read。Git Bash coreutils 全缺 → 走 PowerShell。
- 🚨 WinPS5.1 `Remove-Item` **无 `-LiteralPath`**（绑定失败被静默吞、`$?` 仍真）→ 用 `-Path`；`ForEach-Object` 内别用 `2>$null`。
- 🚨 WinPS5.1 `Set-Content -Encoding utf8` **写 BOM** → 改配置一律 `[System.IO.File]::WriteAllText($p,$t,(New-Object System.Text.UTF8Encoding $false))`。
- 改测试必跑 `cargo test`（check 不编 test）；gradle→JDK17 `D:/study/java/devlop/jdk17`。

## 全局作用域（勿混）
模型 **per-Agent**／授权 **per-对话**（全局 `safe|askAll|auto`+对话覆盖）／Agent **per-对话**（创建时绑定）。

## Android
🚨 改名走 `DeviceStore.renameDevice`；🚨 网络失败 `code=0` 单独分支；🚨 `msg()` fallback 用 `String.format`。配对码一次一用；401→RePairNotice；404/501 静默降级。空状态=单卡片（☕+标题+说明+主按钮+脚注），与 iOS 同构，改动同步两端。

## iOS / Watch
- 只做 iPhone：`TARGETED_DEVICE_FAMILY=1`、仅竖屏；Bundle `com.brewping.ios(.watchkitapp)`，iOS 17.0。
- 🚨 新 Swift 文件登 pbxproj **四处**（BuildFile/FileReference/Group.children/target Sources，`grep -c ≥4`）。
- 🚨 译文 `%@` 个数=实参数（多一个崩）；改完必跑 `python3 ios/Scripts/check_localization.py`。
- i18n：`Text("字面量")` 靠 `.environment(\.locale)`；String 用 `L()`（Watch `LW`）；`Text(变量)` 必须 `LocalizedStringKey(变量)`。
- 局域网明文 http，无 ATS 例外；鉴权 Bearer+`X-BrewPing-Timestamp`(±120s)+`X-BrewPing-Nonce`（GET 免 nonce）；token 存 Keychain `deviceToken.<id>`。
- 配对码 `brewping://pair?host=&port=&deviceId=&name=&osType=&code=`，走系统相机或内置 `QRScannerView`。
- Demo `DemoURLProtocol` 拦 `demo.brewping.local`；**改端点必同步 `DemoBackend.swift`**；query 显式传 `url.query`。

## macOS 桌面端
- `Window(id:"main")`+`MenuBarExtra`；不自绘窗口按钮；`preferredColorScheme(.light)`。
- 🚨 `Sources/App/DesktopCommands.swift` 是 UI **唯一入口**（=Win tauri command）；UI 不得直碰 `ConversationStore`/`ApprovalGate`；执行类命令切后台队列。
- 单一执行路径 `ConversationCommandService`；`CommandRouter.shared` 全局唯一。`SubmitSuccess.conversationID`（非 sessionID）。
- i18n：`DesktopStrings.swift` 由 `src/i18n/locales.ts` 机械生成 → **改文案两端同批**；主题 `LatteTheme.swift` 照搬 `app.css` `:root`；尺寸用 `LatteMetrics`。主区宽度靠 `EnvironmentValues.viewportWidth`（唯一 GeometryReader 在 `DesktopRootView`）。
- 🚨 NSTextView：必须 `scrollableTextView()`；高度钳制放 `sizeThatFits`+外壳 `.fixedSize(vertical:true)`；Enter 走 `textView(_:doCommandBy:)`。
- 改完必 `swift build --disable-sandbox`。

## Windows 桌面端
- 🚨 tokio `Mutex` 不可重入：持锁时不得再调同锁 async 方法 → 先块作用域释放。
- 🚨 HTTP 错误体**永远 JSON** → query 参数声明 `Option<String>` 手工解析。
- ⚠️ 两处 `Command::new`（`http_server.rs` 手机端／`lib.rs` 桌面端）同批改。
- ⚠️ `cargo test` 不得链 tauri GUI → 用 `EventSink = Arc<dyn Fn(&str,Value)>`。
- ⚠️ 改 `capabilities/*.json` 后必 `cargo clean -p brewping-desktop`。
- ⚠️ 重启走 PowerShell `npm run tauri dev`（直跑 release exe 是旧 dist）；Git Bash 的 npm 是 WSL 版；带 `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--no-sandbox"`。
- 鉴权 `route_layer` 全表；白名单仅 `POST /api/pair`+`GET /api/status`。多对话：`conversation_store`/`command_runner`(唯一执行+状态写入)/`conversation_api`。
- 偏好 `~/.brewping/*.json` 一文件一偏好；`Stored` 带 `#[serde(default)]`；测试 `with_path(temp)`。同文件多 Edit 不能并行；Rust2021 无 let-chains。

## 端口拓扑（🚨 易排查错）
`8787`=`http_server`（绑 `0.0.0.0`）← **排查入口**；`15721`=`model_proxy`（绑 `127.0.0.1`，得 503 属正常）。`start_server` 有 +1/+2/+3 回落。
- 🚨 **15721 与 cc-switch 冲突**（本机实测）：`cc-switch` 默认也 LISTEN `127.0.0.1:15721`，且它把 `ANTHROPIC_BASE_URL` 写成该地址。两者**不能同时启用自有代理** → 启用前必须查占用（`lsof -nP -iTCP:15721 -sTCP:LISTEN`），要么换端口要么显式互斥提示。Phase 1 的 UI 只显示"启用"、绑不上不报错。

## 本机 cc-switch（排查模型配置时的重要参照）
- 目录 `~/.cc-switch/`：`cc-switch.db`(SQLite, ~7MB, 持续在写)、`settings.json`(含 `currentProviderClaude`/`currentProviderCodex`)、`backups/`、`logs/`。
- `providers` 表**复合主键 `(id, app_type)`**；关键列 `app_type`/`name`/`settings_config`/`category`/`is_current`/`in_failover_queue`/`provider_type`。`app_type` 实测取值：`claude`/`claude-desktop`/`codex`/`gemini`/`opencode`。
- 🚨 **`settings_config` 含明文 API Key** → 排查只 `select` 非敏感列，绝不 dump 整表。
- **cc-switch 只在"激活"时把配置投影进 CLI 文件**（`~/.claude/settings.json` / `~/.codex/config.toml` / `~/.config/opencode/opencode.json`）。所以「CLI 文件里有 = 当前生效的厂商」，**库里有但未激活的厂商在 CLI 文件里看不到**（例：本机 codex 存了 OpenCode Go / Xiaomi MiMo，但 `currentProviderCodex=codex-official` → config.toml 里没有 `[model_providers]`）。
- 只读打开方式：`sqlite3 "file:$HOME/.cc-switch/cc-switch.db?mode=ro" "select ..."`。

## 模型配置代理（cc-switch 迁移）
- 链路 `model_provider_store` → `model_proxy(:15721)`+`model_transform`(Anthropic⇄OpenAI+SSE)+`cli_takeover`+`provider_catalog`。
- Key 安全：明文 Key 绝不回传（掩码；upsert 空/掩码=保留旧）；CLI 只写占位 `brewping-proxy`。接管支持 claude_code/codex/pi。
- 归属路由 provider 带 `agent_id`，`current_by_agent` 分槽（专属→通用→None），base_url 加 `/claude` `/codex` `/pi` 别名。预设目录 kimi/deepseek/zhipu/xiaomi/minimax+custom。i18n `mp.*` 与 DesktopStrings 同批。

## 厂商原生配置写入（四模块同构，对标 cc-switch）✅ 两端已实现（macOS 2026-09-14 补齐）
> 与 `cli_takeover`（指本地代理的占位配置）**并存**：这套写用户自定义厂商真地址真 Key。cc-switch 是 `match app_type` 分派+每 CLI 专属模块，**非通用实现**。
> **通用模板**：每 agent 一 service+双入口（真路径／`*_at(path)` 测试隔离）+key 校验+Tauri 命令+前端表单（i18n `cl.*`/`cx.*`/`pi.*`/`oc.*`），面板只在对应 tab 渲染。命令面 `get/save/delete_(claude|codex|pi|opencode)_provider`（codex/pi 另有 `activate_*`）。
> UI 上就是各 tab 里那个「**xxx 厂商 · <文件名>**」区块，**只在对应 Agent tab 下渲染**。

- 🚨 **macOS 侧文件对照（Sources/App/）**：`CLIConfigSupport.swift`（BOM/JSON 读写/锁）→ `MiniTOML.swift` → `ClaudeProviderConfig.swift` / `CodexProviderConfig.swift` / `PiProviderConfig.swift` / `OpenCodeProviderConfig.swift`；命令面 `DesktopCLIProviderCommands.swift`；UI `Sources/BrewPingDesktop/CLIProviderPanels.swift`（4 面板 + 4 表单）。
- 🚨 **Claude 必须 `env` 段就地合并、绝不重建** —— 重建会清掉 `DISABLE_TELEMETRY` / `API_TIMEOUT_MS` / `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`。写前剥 cc-switch 元字段（`api_format`/`apiFormat`/`openrouter_compat_mode`/`openrouterCompatMode`）。**三档语义：空串 = 删除该键**，所以 UI 必须把三档都提交（未用的传空串）。删除 = 摘 `ANTHROPIC_*` 键（含三档 ±`_NAME`），env 摘空则移除整个 `env` 键。
- 🚨 **Swift 没有 `toml_edit` 等价库** → codex 的 `config.toml` 用自写的 `MiniTOML`（**按行编辑**：解析出顶层标量 + 各 `[table]` 块行号，只替换/插入/删除目标行，注释/空行/其它表/`[[array]]` 原样保留）。**有意差异**：不额外输出显式的 `[model_providers]` 父表头（语义等价，输出更干净）。
- 🚨 **macOS 侧读 provider id 必须剥 `model_providers.` 前缀**（踩过：只取前缀匹配的表名会让 id 变成 `model_providers.my-deepseek`，后续按 id 查表全落空）。
- ⚠️ **本端修好的两处 Windows 疏漏**：① pi 的 temp+rename 会重置文件权限 → 先对齐临时文件权限再替换；② opencode 保存时"替换整个节点"会丢掉前端不编辑的 `options.headers` → 显式保留。
- ⚠️ **Windows 存量 bug（本端未复刻）**：`CodexProviderEntry` / `PiProviderEntry` 的 `base_url` 走 serde camelCase 出 `baseUrl`，而前端 TS 读 `baseURL` → Codex/pi 面板的 baseURL 显示为空（opencode 因有显式 `rename` 无此问题）。用户截图里 Codex 卡片那行的 `–` 就是它。
- ⚠️ **Windows 存量 bug（两端同源）**：codex 解析器无 `model_provider` 时伪造名为 `custom` 的厂商（`AgentConfigDiscovery.swift:215` / `agent_config.rs:348`）。**尚未修**。
- 验证：`./tools/verify-cli-config.sh`（99 项断言，**本机可跑** —— 只有 CLT 时 XCTest/swift-testing 都不可用，故用独立 swiftc harness）；`Tests/BrewPingCoreTests` 留待有 Xcode 的机器跑 `swift test`。

- 🚨 **Claude** `claude_config.rs`→`~/.claude/settings.json`：只覆盖 `env` 段且必须**就地合并而非重建**（重建会清掉用户 `DISABLE_TELEMETRY` 等）；三档 `ANTHROPIC_DEFAULT_{SONNET,OPUS,HAIKU}_MODEL`(+`_NAME`) 留空不写。单例。
- 🚨 **Codex** `codex_provider_config.rs`→`~/.codex/config.toml`：`[model_providers.<key>]` 的 `name` **必填**；保留 id `openai`/`ollama`/`lmstudio` 不可覆盖（大小写精确）。**绝不碰 auth.json**。
- 🚨 **pi** `pi_config.rs`→`~/.pi/agent/models.json`+`settings.json`：defaultProvider+defaultModel **必须成对**；`providers` 非对象=报错；**key 不可改名**。**绝不碰 auth.json**。
- 🚨 **OpenCode** `opencode_config.rs`→`~/.config/opencode/opencode.json`（`%APPDATA%` 回落）：
  - 唯一真相=该文件（无二次存储）；**深合并铁律**：读全文→只把 `provider` 归一化成对象→`provider[id]=cfg`→写回，**绝不重建根节点**（`mcp`/`$schema`/`theme`/`model` 必须保留）。
  - key `^[a-z0-9]+(-[a-z0-9]+)*$`；`slugify` 派生；根非对象报错。
  - 🚨 `parse_opencode` 遇 UTF-8 BOM **静默失败**返回空 providers（待修：入口 `trim_start_matches('\u{feff}')`）。
- 基线：`cargo test --lib` **293 passed / 1 ignored**。

## 配置指纹失效（方案 B）
- 后端：`agent_config.rs::AgentProviders.config_version` = 各配置源 `mtime_nanos:size` 用 `|` 连接、缺文件记 `-`；`discover()` 出口统一注入。**两端都要返回 `configVersion`**：Windows `handle_agent_models`(HTTP) + `get_agent_models`(Tauri)；**macOS `HTTPAPI.agentModelsResponse`**（配 `AgentConfigDiscovery.configVersion(agentId:)`，本机无 Swift 工具链故未编译）。
- 桌面端 `App.tsx` 两道保险：① `models.configVersion` 变化→`refreshModels`；② 设置页关闭沿→`refreshModels`。**盲区**：停在设置页内不动不会当场更新（`App.tsx` 的 `models` 与卡片的 `ocInfo` 是两个独立 state）。
- 🚨 **iOS `ModelCatalog`（2026-09-14 已修）**：`ModelsResponse` 加 `configVersion`；新增 `loadedConfigVersion` 记**最近一次成功响应**的指纹；`refresh()` **照发探测请求**（指纹只能从响应里拿，本地无从判断）→ 指纹没变就 `return` **不动 state**（防每 5s 重绘闪列表），变了才应用。`canSwitch` 由 `count > 1` 放宽为 **`!models.isEmpty`**。
- 🚨 **模型选择两条落地路径**（`ModelStore.select`）：**有 conversationID → 对话级覆盖**（`PATCH /api/conversations/<id>`）；**无 → Agent 全局默认**（`POST /api/agents/models/default`）。与 `ConversationDetailView.selectModel` 的草稿/既有分支语义一致。`providerID` 必须与 `modelID` 成对。⚠️ `ModelPickerView` 是**死代码**（无引用），实际在用 `ConversationDetailView` 的内嵌 Picker。
- 🚨 **BOM 必须剥**（两端均已修）：Windows `agent_config::read_text` + macOS `AgentConfigDiscovery.readText`，用 `strip_prefix('\u{feff}')`（**不是** `trim_start_matches`，BOM 只允许在文件最前）。🚨 **不只 JSON 受影响**：Apple 的 `JSONSerialization` 容忍 BOM，但 **codex TOML / aider YAML 按行 + `hasPrefix` 解析，行首 BOM 会让整段配置被静默丢掉**。

## 已知坑
- 端口 8787 被旧进程占 → curl 静默打旧进程（先 `Get-NetTCPConnection -State Listen` 核对 pid）。
- canonicalize 出 `\\?\` → `dunce::simplified`；App 进程名连字符 `brewping-desktop`。

## 上架
隐私政策在 GitHub Pages；TEAM `TGA82PM3DZ`；待重新 Archive；暂不做国区。
