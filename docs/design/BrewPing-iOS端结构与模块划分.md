# BrewPing iOS 端整体结构与模块划分

> **一句话定位**：BrewPing 的 iOS 端是**纯客户端** —— 一台 iPhone 主 App + 一个 Apple Watch App，
> 经局域网直连桌面端（Mac / Windows）的 HTTP 服务，全程**无自建服务器、无云端依赖**。
> 本文档整理其整体结构、模块划分与主要功能，并逐处标注与已整理文档（Lody 规格两份 + BrewPing Windows 落地方案）
> 的**对应与差异**，突出 iOS 特有要点。

- **依据代码库**：`D:\work\BrewPing\BrewPing\ios`（只读取证，未改动任何源码）
- **参照的已整理文档**：
  - `docs/BrewPing-获取文件夹-Windows落地方案.md`（下称 **[Win 方案]**，已落地实施）
  - `D:\study\lody\Lody\Lody\.workbuddy\outputs\Lody-本地项目添加-本地与局域网规格.md`（下称 **[Lody 规格]**）
  - `D:\study\lody\Lody\Lody\.workbuddy\outputs\Lody-Windows桌面端界面样式规范.md`（下称 **[Lody 样式]**）
- **硬约束**：本文档与后续 iOS 改动**不得影响 BrewPing 已实现功能**（边界清单见 §6）

---

## 0. 一页速览

| 项目 | 结论 |
| --- | --- |
| iOS 端形态 | SwiftUI 主 App（`ios/BrewPing`）+ watchOS App（`ios/Watch`），同一 Xcode 工程（`ios/BrewPing.xcodeproj`） |
| 架构模式 | MVVM：`@StateObject` Store（单例为主）+ SwiftUI 视图；**命令引擎与界面生命周期解耦**（§3.4） |
| 网络出口 | **唯一**：`BrewPingHTTP`（鉴权头集中拼装 + DemoURLProtocol 注入）；新增功能禁止绕过 |
| 文件系统 | iPhone 端**零本地文件系统访问**，一切目录数据来自主机 API（服务端驱动自绘列表，非 `.fileImporter`） |
| 凭据存储 | Keychain（`AfterFirstUnlock`，后台 WCSession 唤醒也能读）；设备列表在 UserDefaults |
| 目录浏览状态 | **已实现**（`FolderBrowserStore/View`），契约与 [Win 方案] §3 逐字段对齐；**当前仅 Windows 主机可服务**（Mac 端未实现该 API，见 §4.3 平台覆盖表） |
| Demo 模式 | 已覆盖大部分端点；**`/api/folders*` 与 `/api/agents/workdir` 尚未覆盖**（现状，见 §4.3） |
| 本地化 | en + zh-Hans 双语，`L()` + `LanguageManager` Bundle 重定向 + `.id` 强制重建；Watch 端同款 |
| 最大单文件 | `ContentView.swift`（约 1500 行，7 个 MARK 分区）—— 文档 §6 明确"新功能不再往里加" |

---

## 1. 总体架构：一台 iPhone + 一块手表，直连局域网桌面端

```
┌─────────────────────────┐   WCSession（sendMessage / transferFile）
│  Apple Watch App        │◄──────────────────────────────────────────┐
│  语音录入 → 音频文件排队    │        回传结果 / 状态 / 语言 / 设备清单      │
└─────────────────────────┘                                            │
                                                        ┌──────────────┴──────────────┐
┌─────────────────────────┐   Bonjour (_brewping._tcp)   │      iPhone 主 App           │
│  桌面端（Mac / Windows）  │◄────────────────────────────►│  BonjourDiscovery → 发现     │
│  HTTP API（axum / Swift） │◄──── HTTP + Bearer/TS/Nonce ─►│  CommandSubmitter → 提交轮询  │
│  /api/status /message    │                               │  FolderBrowserStore → 浏览    │
│  /folders /agents/workdir│                               └─────────────────────────────┘
└─────────────────────────┘
        配对：POST /api/pair（6 位码换长期 token）+ brewping://pair 深链 + QR 扫码
```

与 Lody 的第一个结构差异就在这张图上：**[Lody 规格] 的四阶段链路里，阶段 A（daemon 注册）与阶段 B（机器可见性）在 BrewPing 里不存在**——"配对完成 = 机器可见"，机器列表是 `DeviceStore` 里的本地设备表，不需要云端可见性归并、presence 心跳或 flock 文档。

---

## 2. 模块划分

### 2.1 分层总表

| 层 | 文件（`ios/BrewPing/`） | 核心类型 | 职责 |
| --- | --- | --- | --- |
| **入口** | `BrewPingApp.swift` | `BrewPingApp` | 进程级 bootstrap：`CommandSubmitter.bootstrap()`（WCSession 后台唤醒要求）+ `LanguageManager` + `.onOpenURL` 深链挂接 |
| **设备与发现** | `ManagedDevice.swift` | `ManagedDevice` / `DeviceOSType` | 设备模型；`osType` 解析（mac/windows/linux，**缺失回落 `.mac`** 保老版本兼容） |
| | `DeviceStore.swift` | `DeviceStore` | 多设备 CRUD + 活跃设备；UserDefaults 持久化；旧单设备配置迁移；删除设备同步清 Keychain token |
| | `BonjourDiscovery.swift` | `BonjourDiscovery` | `NWBrowser` 浏览 `_brewping._tcp`（8 秒）→ `NetService` 逐实例解析（4 秒超时）→ 优先 IPv4 字面量；TXT `platform` 读主机类型 |
| **网络层** | `BrewPingHTTP.swift` | `BrewPingHTTP` / `DeviceAuth` / `PairingResponse` | 唯一网络出口：鉴权三头（`Bearer` + `X-BrewPing-Timestamp` + `X-BrewPing-Nonce`）集中拼装；`URLComponents` 重载处理含空格/中文/`#` 的 query；401 统一判定 |
| | `KeychainStore.swift` | `KeychainStore` | 极简 Keychain 封装（配对 token 专用；`AfterFirstUnlock` 可访问性） |
| **命令引擎** | `CommandReceiver.swift` | `CommandReceiver` / `CommandSubmitter` / `CommandPhase` | 非 UI 通道命令统一入口 → POST `/api/message` → 1s 轮询 `/api/message/{id}` → 审批插叙；**与 SwiftUI 生命周期解耦**（§3.4） |
| **功能模块** | `ModelCatalog.swift` | `ModelStore` / `ModelOption` | 模型列表拉取（providers→models 扁平化）与切换 |
| | `ApprovalModeStore.swift` | `ApprovalModeStore` | 授权档位读写（`/api/approvals/mode`，auto/confirm/safe） |
| | `FolderBrowserStore.swift` | `FolderBrowserStore` / `BrowseRoots` / `BrowseEntry` | **目录浏览状态机**（§3.5，对应 [Win 方案] §3 契约） |
| **UI 层** | `ContentView.swift` | `ContentView` + 各分区视图 | 主界面（约 1500 行）：状态卡、Agent 列表、会话管理、消息与结果、设备 Tab、添加/编辑设备 Sheet、QR 扫码 |
| | `FolderBrowserView.swift` | `FolderBrowserView` | 目录浏览页（5 态渲染，服务端驱动列表） |
| | `ApprovalRequestView.swift` / `QRScannerView.swift` / `HelpView.swift` | — | 审批弹窗 / 相机扫码（AVFoundation）/ 帮助 |
| **支撑** | `BrewPingConfig.swift` / `BrewPingLog.swift` / `LanguageManager.swift` | — | 上架常量（隐私政策/免责声明）/ 分类日志（net/discovery/command/demo，正文一律 `.private`）/ 双语切换 |
| **Demo** | `DemoBackend.swift` / `DemoURLProtocol.swift` | `DemoBackend` | 审核员零硬件走通全链路：`DemoURLProtocol` 挂在会话 `protocolClasses[0]`，对调用方透明 |
| **Watch 桥** | `WatchConnectivityManager.swift` | `WatchConnectivityManager` / `WatchAudioPlayback` | WCSession delegate + iPhone 侧语音转写（SFSpeechRecognizer）+ 结果回传 + 代手表切 Agent/模型 |

### 2.2 Watch 端（`ios/Watch/`）

| 文件 | 职责 |
| --- | --- |
| `ContentView.swift` | 表盘主界面：设备/Agent/模型三组左右滑动切换 + 连接状态 + 语音入口 |
| `WatchSessionManager.swift` | WCSession delegate；设备/Agent/模型状态镜像自 iPhone；文本命令 `sendMessage` |
| `VoiceCommandView.swift` / `WatchAudioRecorder.swift` | 按住录音 → `transferFile` 排队投递音频（iPhone 不在前台也能发） |
| `WatchLanguageManager.swift` / `WatchLocalized.swift` / `WatchLog.swift` | 与 iPhone 同款双语机制（iPhone 推送语言偏好过来） |

---

## 3. 主要功能说明

### 3.1 配对与设备管理

- **三条配对入口**：① 手动输入 host/port/6 位码；② 相机扫码（`QRScannerView`）；③ 桌面端深链 `brewping://pair?host=&port=&deviceId=&osType=&code=&name=`（`PairingURLHandler`）。
- **【对应 Lody】** 等价于 [Lody 规格] 阶段 A+B 的全部产出（machineId + 可达地址 + 归属），但**塌缩成"换一个长期 token"**：`POST /api/pair` → token 进 Keychain（`deviceToken.<deviceId>`）。
- **【iOS 特有】** 深链处理采用 `pendingAction` 两段式：`App.onOpenURL`（系统最早的入口）存下动作 → `ContentView.onChange` 消费后 `consume()`。注释明确这是为了同时覆盖冷启动（视图尚未 onAppear）与热路径。
- 设备删除时**同步清 Keychain token**（`DeviceStore.removeDevice`），否则 Mac 侧轮换后旧 token 永远失效。

### 3.2 发现与连接

- `BonjourDiscovery`：NWBrowser 给出的只有服务实例名，必须 `NetService` 解析出地址才能连（注释明示）；取 IPv4 字面量优先、mDNS 主机名兜底。
- TXT 记录 `platform` → `DeviceOSType.parse`（接受 `mac/macos/darwin/windows/win32/linux` 两套命名）——**【对应 Win 方案 §3.1】** 这正是 Windows 端 `platform` 取值陷阱的消费端防御：两端命名不同也解析得了。

### 3.3 状态、Agent 与会话管理

- 轮询 `GET /api/status`（在线/主机名/会话）与 `GET /api/agents`（安装列表/版本/默认 Agent/workdir）。
- 会话启停 `POST /api/session/start|stop`；切默认 Agent `POST /api/agents/default`。
- **【iOS 特有·关键防御】** 当前 Agent id 以 `/api/status` 的 `defaultAgent` 为准，**不用** `session.agent`（注释：Windows 桌面端切默认 Agent 会把会话置空，读 `session.agent` 永远拿到旧值）。老服务端无该字段时逐级回退。

### 3.4 命令提交与审批（核心链路）

```
文本输入(iPhone) ─┐
Watch 文本 sendMessage ─┤→ CommandReceiver（唯一入口）
Watch 语音 transferFile ─┘        │ onCommand（bootstrap 期挂接，不走 SwiftUI）
                                  ▼
                        CommandSubmitter.submit
                        POST /api/message {text}
                                  │
              ┌───────────────────┴────────────────────┐
              │ status == "pending_approval"            │ commandId
              ▼                                          ▼
   ApprovalRequestView 弹窗                    轮询 GET /api/message/{id}
   approve / deny / always_approve             （1s 间隔，连续 10 次失败才判死）
   POST /api/approvals/{id}                          │
              │                                      ▼
              └──────────────────────────► completed / completed_with_raw / failed
                                           fromWatch 的结果经 WCSession 回传手表
```

- **【iOS 特有·本项目最重要的教训】** 提交引擎必须是**进程级单例**并在 `App.init()` bootstrap：WCSession 可在 App 后台、界面未创建时唤醒进程投递手表数据，那种路径不经过任何 SwiftUI 生命周期，挂在 `ContentView.onChange` 上的提交逻辑"永远不触发、命令被静默丢弃"（源码注释原文记录了这个 bug 现象）。
- **【对应 Win 方案】** `CommandStatusResponse.failureReason` 已消费——Windows 端新增的 `invalid_workdir` 预检失败码会经此字段透出（无需 iOS 改动）。
- 授权档位三态（auto/confirm/safe）由 `ApprovalModeStore` 管理；**缺席不表态**：用户关掉确认弹窗不自动 deny，命令留 Mac 端挂起等服务端超时兜底。

### 3.5 目录浏览与工作目录（对应 [Win 方案]，已实现）

- `FolderBrowserStore`：5 态状态机 `idle / loadingRoots / browsing / empty / permissionDenied / failed`（注释标注"方案 §4.10 的 5 态"，即 [Win 方案] 的 iOS 侧章节）。
- 流程：`GET /api/folders/roots`（10s）→ 落到 `homeDir` → `GET /api/folders?path=&hidden=`（10s）→ 翻页用服务端 `nextCursor`（offset 字符串，客户端只回传不解析）+ 追加去重。
- **【契约对齐】** 三个数据结构注释首行就是 *"与 Windows 端 folder_browser.rs 的 JSON 契约逐字段对齐"*：`platform` / `pathSeparator` / `homeDir` / `drives`；`BrowseEntry` 的 `isSymlink` / `hidden` / `hints.git` / `error:"unreadable"`；`truncated` + `nextCursor`。
- **【对应 Lody】** [Lody 规格] §6.5 的效果清单逐条落地：只列目录、隐藏开关（切换即重拉当前目录）、手动路径输入 Enter 提交、`unreadable` 置灰不可点（`enter()` 直接 return）、面包屑上级（盘符根 `parentPath = nil` 不动）。
- **【iOS 特有】**
  - **绝不能用 `.fileImporter` / `UIDocumentPickerViewController`**（注释两次强调）——那浏览的是 iPhone/iCloud 的文件系统，与主机毫无关系；iOS 沙盒下也没有别的选择。
  - 服务端错误码 → 文案映射：`permission-denied` / `unc-not-allowed` / `path-outside-allowlist` / `path-invalid` / `does not support workdir`。
  - `supportsWorkdir(agentID:)` 提前拦掉 `opencode`（服务端是 stub，发请求必失败）。
  - 设定工作目录 `POST /api/agents/workdir {agentId, path}`（15s 超时，POST 带 nonce 由 `BrewPingHTTP` 自动附加）。
  - 404/501 → **优雅降级为"主机不支持"文案**，不是报错（见 §4.3）。

### 3.6 模型切换（`ModelCatalog`）

- `GET /api/agents/<id>/models` 返回 Provider→Models 两层嵌套，Store 扁平化为 `ModelOption`；`POST /api/agents/models/default` 切换。
- 注释明确**数据来源唯一**（Mac 端 `AgentConfigDiscovery` 读各 Agent 真实配置文件），iOS 只做展示与选择、不新增配置源——与 [Lody 规格] "App 不落库配置"的分层精神一致。

### 3.7 Demo 模式（App Store 审核链路）

- `DemoURLProtocol` 插在共享会话 `protocolClasses[0]`，对调用方完全透明；`DemoBackend` 用 switch 模拟了 status/agents/session/message/approvals/agents/default/switch/models 等端点。
- **【差异标注】** Demo 后端**尚未实现** `/api/folders*` 与 `/api/agents/workdir`（grep 为空）——Demo 设备上目录浏览入口会走 404 → "主机不支持" 文案。这是现状（不是缺陷），补齐时按 §6 的接入模式做。

### 3.8 Watch 语音链路

- Watch 端 `AVAudioRecorder` 录音 → `transferFile` 排队投递 → iPhone `WatchConnectivityManager` 收文件 → **iPhone 侧** `SFSpeechRecognizer` 转写（Watch 不做语音识别，省算力且复用 iPhone 的权限/模型）→ `CommandReceiver` → `CommandSubmitter`（`fromWatch: true`）→ 结果回传手表。
- 本地化偏好、设备/Agent/模型清单均由 iPhone 推送，Watch 不独立持久化。

---

## 4. 与已整理内容的对应与差异

### 4.1 与 [Win 方案] 的对应（同一条功能链的两端）

| [Win 方案] 内容 | iOS 端落点 | 状态 |
| --- | --- | --- |
| §3.1 `GET /api/folders/roots` 契约 | `BrowseRoots`（字段注释逐条对应） | ✅ 已对齐 |
| §3.2 `GET /api/folders`（path/limit/cursor/hidden） | `browse()` / `loadMore()`；`limit` 由服务端默认值承担，iOS 未显式传 | ✅ |
| §3.3 `POST /api/agents/workdir` | `setWorkdir()` | ✅ |
| §3.4 `/api/agents` 增补 `workdir` 字段 | `AgentEntry.workdir: String?`（Optional，与 `ManagedDevice.isDemo` 的 Codable 兼容教训一致） | ✅ |
| §3.5 错误码映射表 | `workdirErrorMessage()` / `serverErrorCode()` | ✅ |
| §4.10 "iOS 侧（仅提示）" | 即 `FolderBrowserStore/View` 本体 | ✅ 已落地 |
| §5.1-5.9 Windows 特有难点 | iOS **无需关心**（路径只是不透明字符串；但 UI 必须用 `pathSeparator`，不可假设 `/`） | — |

### 4.2 与 [Lody 规格] 的对应

| Lody 阶段 | BrewPing iOS 对应 |
| --- | --- |
| A. daemon 注册 | 无；配对即注册 |
| B. 机器可见性归并（云端 + flock） | 无；`DeviceStore.devices` 本地表 |
| C. 目录浏览（list-roots / browse-dir RPC） | `FolderBrowserStore`，但传输从 Loro RPC 换成 **REST over LAN**，服务器语义从"中继"变成"文件系统所有者本体" |
| D. 添加/落库（flock 行 + CRDT） | 塌缩为主机端一个 JSON 键（`workdir_prefs.rs`）；iOS 只发 `POST`，不落任何本地库 |
| 传输平面路由（local/cloud） | 不存在——只有一个局域网平面；**等价物是"永远 plane = local"** |

### 4.3 平台覆盖现状（iOS 消费端视角）⚠️ 最重要的一张表

| 端点 | Windows 端（axum，已落地 [Win 方案]） | Mac 端（`Sources/App` Swift） | DemoBackend |
| --- | --- | --- | --- |
| `GET /api/folders/roots` | ✅ `folder_api.rs` | ❌ **未实现**（grep `folders` 为空） | ❌ |
| `GET /api/folders` | ✅ | ❌ | ❌ |
| `POST /api/agents/workdir` | ✅（含 `invalid_workdir` 预检） | ❌ | ❌ |
| `/api/agents` 含 `workdir` 字段 | ✅ | ❌（macOS Agent 无 workdir 概念，cwd 取进程目录） | ❌ |

**推论**：iOS 的目录浏览功能**目前只对 Windows 主机生效**。Mac 主机上打开浏览页会命中 404 → `FolderBrowserStore` 显示"This host doesn't support folder browsing. Update the desktop app."——这是设计好的优雅降级，不是 bug。若要补 Mac 端实现，iOS 端**零改动**（契约已对齐），这正是当初把 iOS 做成"服务端驱动 + 404 降级"的原因。

### 4.4 与 [Lody 样式] 的差异（界面风格）

| 维度 | Lody 桌面端 | BrewPing iOS |
| --- | --- | --- |
| 样式体系 | Tailwind v4 + HSL 令牌 + shadcn/cva | **纯系统原生** SwiftUI 组件（Form/List/Section/ContentUnavailableView），无自建设计令牌 |
| 空态/错误态 | 自绘（ContentUnavailableView 语义的对应物需自建） | `ContentUnavailableView` + `ProgressView`，系统即规范 |
| 主题来源 | VS Code 主题别名重映射 | 跟随系统深浅色，`Color.green/.secondary` 等语义色 |
| 共同点 | 目录浏览 5 态、`unreadable` 置灰、路径不翻译、分页游标语义 | 逐条一致（交互语义跨平台对齐，视觉各自原生） |

---

## 5. iOS 特有要点（复刻/迁移时最容易踩的 10 条）

1. **后台唤醒优先于界面**：一切 Watch 触发的逻辑必须在 `App.init()` bootstrap，绝不依赖 SwiftUI 生命周期（`CommandReceiver.swift:42-46` 注释记录了完整故障现象）。
2. **Keychain 可访问性必须 `AfterFirstUnlock`**：后台唤醒时设备是锁屏的，`WhenUnlocked` 读不到 token。
3. **query 必须走 `URLComponents`**：Windows 路径含空格/中文/`#`/`&`，`URL(string:)` 字符串拼接会返回 nil 或把 `#` 当 fragment 截断——这是为目录浏览新增的重载（`BrewPingHTTP.request(device:path:queryItems:)`）。
4. **路径是不透明字符串**：不解析、不假设分隔符，显示时用服务端 `pathSeparator`；长路径 `truncationMode(.head)` 保末段。
5. **`DeviceOSType.parse` 缺失一律回落 `.mac`**：保证老版本桌面端（深链/mDNS 不带 platform）不丢设备。
6. **Codable 字段加 Optional**：`ManagedDevice.isDemo` 用主机名判定而非存储字段、`AgentEntry.workdir` 可选——都是"老数据无此键则 decode 崩、用户设备列表被清空"的教训（注释明文）。
7. **日志隐私分级**：命令正文、路径、设备名一律 `.private`，Release 被系统抹除；错误信息走 `failureMessage()` 的用户可读映射而非 `localizedDescription` 直出。
8. **本地网络权限**：`NSBonjourServices` 必须显式声明 `_brewping._tcp`（否则 iOS 14+ Bonjour 静默失败）；ATS 用 `NSAllowsLocalNetworking` 放行局域网 HTTP；相机权限文案绑定"只用于扫码"。
9. **本地化机制**：`L()` + `LanguageManager` 重定向 `Bundle.main`（在 init 完成，避免闪一帧系统语言）+ `.id(language.current)` 强制重建整棵树；**数据（路径/版本号/主机名）不翻译**；三元表达式两边都要显式 `LocalizedStringKey`（注释记录的坑）。
10. **隐私清单**：主 App 声明 `UserDefaults / CA92.1`、Watch 声明 `FileTimestamp / C617.1`——新增 Required Reason API 时同步更新 `PrivacyInfo.xcprivacy`。

---

## 6. 「不能影响已实现功能」的边界

### 6.1 不动区（现状已验证可用，改动需回归）

| 已实现功能 | 依赖链 | 回归验证点 |
| --- | --- | --- |
| 配对（扫码/深链/手输） | `PairingURLHandler` → `DeviceStore` → `DeviceAuth`(Keychain) | 冷启动深链、删除设备后 token 清理 |
| Bonjour 发现 | `BonjourDiscovery`（8s 浏览 + 4s 解析） | Win/Mac 双主机广播均能出现且 osType 正确 |
| 命令提交与轮询 | `CommandSubmitter`（含审批插叙、10 连败熔断） | 前台/后台/锁屏三种发起路径 |
| Watch 语音 | `transferFile` → 转写 → 提交 → 回传 | iPhone 不在前台时手表仍能收到结果 |
| 模型/Agent/授权切换 | `ModelStore` / `ApprovalModeStore` | 老服务端（无 defaultAgent 字段）回退路径 |
| 目录浏览（对 Windows 主机） | `FolderBrowserStore/View` ↔ `folder_api.rs` | 分页、隐藏开关、置灰、错误码文案 |
| Demo 模式 | `DemoURLProtocol` 全覆盖既有端点 | 审核路径零硬件走通 |
| 双语切换 | `LanguageManager` + 两份 `.strings` | `Scripts/check_localization.py` 校验 |

### 6.2 新功能接入模式（遵守现状约定，即不会破坏既有功能）

1. **网络一律走 `BrewPingHTTP`**：新端点加到该文件或用其既有重载；禁止新建 URLSession（会绕开 Demo 注入与鉴权头）。
2. **新状态用独立 Store 文件**（如 `FolderBrowserStore` 的先例），**不再往 `ContentView.swift` 加**（已约 1500 行）；接入选 `NavigationLink` / `sheet`，视图放独立文件。
3. **服务端驱动**：任何"主机上的数据"（目录、模型、Agent 列表）都由 API 返回，客户端不猜、不缓存结构假设；老主机无该端点 → 404/501 优雅降级文案（照 `FolderBrowserStore` 先例）。
4. **Demo 同步**：新端点若要在审核链路可用，需在 `DemoBackend` 加同构分支（现状 folders 未覆盖，补齐时照既有端点写法）。
5. **Codable 新字段一律 Optional**（§5 第 6 条）。
6. **本地化**：新文案进 en + zh-Hans 两份 `.strings`，跑 `check_localization.py`；主机数据不加翻译。
7. **平台能力声明**：新用到的系统权限/Required Reason API 同步更新 `Info.plist` 与 `PrivacyInfo.xcprivacy`（两个 target 各自维护）。

---

## 7. 关键文件索引（`ios/` 下）

| 文件 | 行数级 | 说明 |
| --- | --- | --- |
| `BrewPing/ContentView.swift` | ~1500 | 主界面全部视图与网络调用（MARK 七分区：首启/设备Tab/添加设备/AgentList/SessionCard/Message/Result/StateReset/Polling/Networking/Lifecycle/Send） |
| `BrewPing/CommandReceiver.swift` | ~390 | `CommandReceiver` + `CommandSubmitter` + 全部 API 响应模型 |
| `BrewPing/WatchConnectivityManager.swift` | ~690 | WCSession + 语音转写 + 回传 + 代切 Agent/模型 |
| `BrewPing/FolderBrowserStore.swift` | ~350 | 目录浏览状态机（契约注释对齐 folder_browser.rs） |
| `BrewPing/FolderBrowserView.swift` | ~300 | 目录浏览页 UI |
| `BrewPing/BrewPingHTTP.swift` | ~135 | 唯一网络出口 + DeviceAuth |
| `BrewPing/BonjourDiscovery.swift` | ~176 | Bonjour 浏览与解析 |
| `BrewPing/DeviceStore.swift` / `ManagedDevice.swift` / `KeychainStore.swift` | 小 | 设备模型/存储/凭据 |
| `BrewPing/DemoBackend.swift` / `DemoURLProtocol.swift` | — | Demo 模拟后端 |
| `BrewPing/ModelCatalog.swift` / `ApprovalModeStore.swift` / `PairingURLHandler.swift` / `LanguageManager.swift` / `BrewPingConfig.swift` / `BrewPingLog.swift` | 小 | 各功能模块 |
| `Watch/ContentView.swift` / `WatchSessionManager.swift` / `VoiceCommandView.swift` / `WatchAudioRecorder.swift` | — | watchOS App |
| `BrewPing.xcodeproj/project.pbxproj` | — | 工程（iPhone + Watch 双 target） |
| `BrewPing/Scripts/check_localization.py` | — | 本地化完整性校验脚本 |

> 构建：需 macOS + Xcode（Windows 工作机上只能做静态审查；`ios/build-device/` 下是历史 Debug 产物）。
