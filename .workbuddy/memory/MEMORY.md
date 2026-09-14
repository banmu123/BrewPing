# BrewPing — 项目长期记忆

跨端工具：iPhone / Apple Watch / Android 远程指挥电脑 AI Agent。`ios/`、`Sources/`(Mac SwiftPM)、`Sources/BrewPingwinDesktop`(Windows Tauri 2+axum+React)、`Android/`。

## 环境事实（本机 Windows）
- Mac 端改动静态核查即可，`swift build` 因宿主 env 崩溃无法本机验证。
- 🚨 会话里 PowerShell/bash 回显通道会坏 → 统一 `2>&1 | Out-File -Encoding utf8 落盘` 再 Read；一切走 PowerShell。
- cargo check 不编 test → 改测试必跑 cargo test。gradle 加 `-Dorg.gradle.java.home=D:/study/java/devlop/jdk17`。

## 三端消息链路
- POST /api/message 命中门卫 → 200 `{status:"pending_approval",...}`；无会话自动建对话；命令串行。

## Android 硬规则
- 🚨 改名走 `DeviceStore.renameDevice`；🚨 网络失败 code=0 单独分支；🚨 msg() fallback 必须 `String.format`。配对码一次一用；401 → RePairNotice；404/501 静默降级。

## iOS / Watch 硬规则
- 🚨 新 Swift 文件登记 pbxproj 四处（grep -c ≥4）；🚨 译文 %@ 个数=实参数，跑 `check_localization.py`。
- `Text("字面量")` 靠 `.environment(\.locale)`；String 用 `L()`；`Text(变量)` 必须 `LocalizedStringKey(变量)`。只做 iPhone；Demo 端点同步 DemoBackend.swift；鉴权 Bearer+timestamp+nonce。

## 授权 / 模型作用域
- 授权 safe/askAll/auto 全局 + 对话级覆盖；检测点=进 agent 前；pending TTL 300s。
- 模型数据源只用 `GET /api/agents/<id>/models` + `POST /api/agents/models/default`；模型 per-Agent、授权 per-对话、Agent per-对话。Watch：切 Agent 先同步本地权威值再推送；轮询 5s。

## macOS 桌面端
- DesktopCommands.swift 是 UI 唯一入口；单一执行路径 ConversationCommandService；CommandRouter.shared 唯一。
- i18n：DesktopStrings.swift 由 locales.ts 机械生成（LKey enum + zh/en 三处同批）。
- 🚨 NSTextView 必须 `scrollableTextView()`；高度钳制放 sizeThatFits；Enter 走 `textView(_:doCommandBy:)`。

## Windows 桌面端
- 🚨 tokio::sync::Mutex 不可重入：持锁期间绝不能再调同锁 async 方法 → 先块作用域释放锁再调。
- HTTP 错误体永远 JSON；query 用 Option<String> 手工解析；⚠️ 两处 Command::new 同批改；⚠️ cargo test 不得链 tauri GUI（EventSink）；⚠️ 改 capabilities 后 cargo clean -p brewping-desktop；⚠️ 重启走 `npm run tauri dev`（PowerShell，先清 1420 残留 vite）。
- 鉴权 route_layer 全表；白名单 POST /api/pair + GET /api/status；GET 免 nonce。
- 多对话：conversation_store + command_runner + conversation_api；偏好 ~/.brewping/*.json 一文件一偏好；Stored 带 #[serde(default)]；测试 with_path(temp)。
- 同一文件多个 Edit 不能并行；Rust 2021 无 let-chains；记录型 map 用 entry() 别用 get()；测试轮询要等全部收尾步骤完成（防 await 间隙假阳性）。

## 模型配置代理（cc-switch 迁移）
- 链路：model_provider_store(CRUD+current+failover) → model_proxy(127.0.0.1:15721) + model_transform(Anthropic⇄OpenAI+SSE) + cli_takeover + provider_catalog(预设)。
- Key 安全：明文 Key 绝不回传（ProviderView 掩码；upsert 空/掩码=保留旧）；CLI 只写占位 brewping-proxy，真实 Key 代理注入；掩码字符 `•`。
- CLI 接入动态列表：ALL_KINDS → items[{id,name,installed,supported,active,...}]；仅 claude_code/codex 支持；扩展新 CLI 三步（枚举→分支→实现）。enable 自动拉起代理。
- 预设目录（一期 6 条，方案见 D:/study/ccswitch/cc-switch预设供应商能力-迁移至BrewPingWin方案.md）：kimi/deepseek/zhipu/xiaomi/minimax 全走 Anthropic 端点（零转换）+ custom；列模型走 models_url（OpenAI 端点，Anthropic 协议无 GET /models）；applyVendor 回填 model + isFullUrl=false；fetch_provider_models 失败回落静态 models；测试禁推广参数（aff=）。
- Agent 模型区块 + 表单高级选项（拉模型 chips / 映射说明 / 端点预览）；refresh 用 Promise.allSettled；i18n mp.* zh/en + DesktopStrings.swift 同批。

## 已知坑
- 端口 8787 被旧进程占 → curl 静默打旧进程；canonicalize 出 \\?\ → dunce::simplified；App 进程名连字符 brewping-desktop。

## 上架
- 隐私政策 banmu123.github.io/BrewPing/privacy.html；TEAM TGA82PM3DZ；待办：重新 Archive；暂不做国区。
