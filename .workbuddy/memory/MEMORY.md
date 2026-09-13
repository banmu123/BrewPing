# BrewPing — 项目长期记忆

跨端工具：iPhone / Apple Watch / Android 远程指挥电脑上的 AI Agent。
`ios/`(SwiftUI 主 App+Watch)、`Sources/`(Mac 端 SwiftPM: BrewPingCore/BrewPingDesktop/App)、`Sources/BrewPingwinDesktop`(Windows, Tauri 2+axum+React)、`Android/`(Compose)。

## 环境事实（本机 Windows）

- Windows Swift 工具链**编不了 macOS 目标**（`no such module 'Darwin'`）→ Mac 端改动只能静态核查，真验证要上 Mac。
- Git Bash 缺 coreutils、`rm` shim 损坏；PowerShell 无输出回显。工作模式：Bash 跑命令 + `> 落盘` + Read 读；删文件用 Python `os.remove`。
- cargo check 不编 `#[cfg(test)]` → 改测试后必跑 `cargo test > log 2>&1`。
- **命令行 gradle 必须 `-Dorg.gradle.java.home=D:/study/java/devlop/jdk17`**（JDK 17.0.20.1）——JAVA_HOME 的 JDK 25.0.4.1 与 Gradle 8.14 不兼容（报错只有版本号）。Android Studio 内用 JBR 不受影响。
- `~/.gradle` 陈旧锁（journal-1.lock 拒绝访问）：`gradlew --stop` + Python `os.remove`。gradle-wrapper.jar 曾缺失，Gitee `mirrors/gradle` v8.14.0 补。

## 三端消息链路契约（2026-09-13 统一）

- **POST /api/message**：命中授权门卫 → 200 + `{status:"pending_approval", approval:{id,text,reasons}}`，**无 commandId**。客户端必须识别（iOS CommandSubmitter / Android CommandPhase.PendingApproval）。
- **GET /api/message/{id}**：未知 commandId → **404 终态**（桌面重启清队列），三端立即收敛不重试。
- **无会话自动建对话**：resolve 三层回落 `显式对话 → active → 默认Agent新建`；pending 记住归属对话；deny 落转录（"Command denied by user."）。
- **POST /api/conversations**：响应含 `submitStatus` + `commandId`/`approval`；门卫判定在 submit 前。命令执行串行（Windows exec_lock ≈ macOS headlessQueue）。
- **转录条目**统一带 `id`（msg_ 前缀）；Windows append 后发 `conversations-changed` 事件；pump_pipe 只投完整 UTF-8 前缀（防中文切 U+FFFD）。

## Android 配对/设备约定（2026-09-13 排查沉淀）

- **🚨 设备 id 改名必须 `DeviceStore.renameDevice(oldId, renamed)`**（按旧 id 定位 + 迁移 activeDeviceID）。`updateDevice` 按**条目自身 id** 查找——改名后 id 已变永远匹配不到、**静默失败** → token 键与设备 id 错位 → 请求不带 Bearer → 401 → "需要重新配对"卡片死循环（曾致配对成功却收不到对话）。pairWithCode 把设备 id 改为桌面端身份 `result.deviceId`，token 键 = 同值。
- **配对码一次一用**（Windows `exchange()` 成功即作废）：iOS 扫过的码 Android 再扫必 401；删手机端设备不复活桌面码，须桌面端重新生成；桌面端配对窗在码被消费后 UI 不自动刷新（显示旧二维码）。失败提示用 `pairing_code_exhausted` 文案（en/zh）。
- **二维码 `PairPayload` 必须解析 `osType`**（桌面端固定写 `osType=windows`，iOS 有处理）；扫码新建设备/表单预填都要带 osType，否则回落默认 Mac（"幽灵 Mac"）。扫码新建前按 host+port 与已有设备**去重复用**（token 曾因此分裂到两条设备）。
- **`DeviceStore.migrateIfNeeded` 一次性**：迁移后清旧键（brewping_prefs 的 macAddress/port）——否则用户删光设备后每次冷启动自动复活一台 Mac（旧配置硬编码 osType=Mac）。
- **401 语义对齐 iOS**：`ConversationsResult.unauthorized` → 列表页 RePairNotice 卡 + 重新配对入口（HomeScreen 接 showPairFor）。404/501 → unsupported 静默降级。
- 空态引导：附近发现设备（discovered 非空）时隐藏"添加第一台电脑"EmptyStateCard；查不到才显示。
- Android NSD 正确读 TXT platform；`DeviceOSType.fromRaw` else 回落 Mac（改默认值要三思）。

## iOS / Watch 硬规则

- **🚨 新增 Swift 文件登记 `project.pbxproj` 四处**（BuildFile/FileReference/Group/Sources）；验：`grep -c 文件名 ≥ 4`。
- **🚨 译文 `%@` 个数=实参个数**，多一个必崩；改完跑 `python3 ios/Scripts/check_localization.py`。
- 本地化：`Text("字面量")` 靠 `.environment(\.locale,…)`；String 用 `L()`（Watch `LW`）；`Text(变量)` 必须 `Text(LocalizedStringKey(变量))`。
- 只做 iPhone（TARGETED_DEVICE_FAMILY=1）；Watch 语言随 WCSession；鉴权 Bearer+timestamp(±120s)+nonce，iOS token 在 Keychain。
- Demo 模式：`DemoURLProtocol` 拦 `demo.brewping.local`；新增端点同步 `DemoBackend.swift` switch。

## 授权 / 模型 作用域（别搞混）

- 授权三档 safe/askAll/**全局**（~/.brewping/approval.json）+ **对话级档位覆盖**；检测点=进入 agent 前；pending TTL 300s。
- 模型数据源只用 `GET /api/agents/<id>/models` + `POST /api/agents/models/default`。模型 per-Agent、授权 per-对话、Agent per-对话。
- Watch：切 Agent 先同步本地权威值再推送；`applyContext` 带 pendingAgentSwitch 保护；状态轮询 5s。

## macOS 桌面端

- **宪法**：`Sources/App/DesktopCommands.swift` 是桌面 UI 唯一入口；UI 不得直碰 Store/Gate 内部；执行类命令切后台队列。
- 单一执行路径 `ConversationCommandService`；`CommandRouter.shared` 唯一实例。
- i18n：`DesktopStrings.swift` 由 `locales.ts` 机械生成，改文案两端同批。主题令牌 LatteTheme←app.css。
- 🚨 NSTextView 包装必须 `scrollableTextView()`；高度钳制放 `sizeThatFits`；Enter 走 `textView(_:doCommandBy:)`。

## Windows 桌面端

- HTTP 错误体永远 JSON；query 参数用 `Option<String>` 手工解析。
- **⚠️ 两处 `Command::new`**（http_server / lib.rs）执行改动同批改两处。
- **⚠️ cargo test 不得链 tauri GUI**（EventSink 模式）；**⚠️ 改 capabilities/*.json 后 `cargo clean -p brewping-desktop`**；**⚠️ 重启必须 `npm run tauri dev`**（PowerShell + --no-sandbox）。
- 鉴权 route_layer 全表；白名单仅 POST /api/pair + GET /api/status；GET 免 nonce。token 单例落 ~/.brewping/pairing.json（文件重置即全部旧 token 失效）。
- 多对话：conversation_store + command_runner + conversation_api；HTTP /api/status 无 activeConversationId 属正常。
- workdir 安全：UNC realpath 前拒、白名单 realpath 后、盘符 GetLogicalDrives。

## 已知坑（高频）

- 端口 8787 被旧打包进程占 → curl 静默打旧进程，"新路由 404"。
- URLSession 把 httpBody 转 httpBodyStream，URLProtocol 读体要 fallback。
- scenePhase 起停轮询用 `!isInBackground`；本机 osascript 无辅助访问权限。
- Windows：canonicalize 出 \\?\ → dunce::simplified；隐藏=点号+FILE_ATTRIBUTE_HIDDEN。

## 上架 / 文档

- 隐私政策 `https://banmu123.github.io/BrewPing/privacy.html`；supportEmail czkbanmu@163.com；TEAM TGA82PM3DZ；**待办：最新代码重新 Archive**。
- 国区上架需备案——用户决定暂不做国区（2026-09-13）。
- 文档：docs/AppStore-PreSubmission-Review.md、docs/BrewPing-Windows端多对话管理实现方案.md。
