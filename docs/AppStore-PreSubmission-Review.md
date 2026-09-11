# BrewPing iOS — App Store 上架前审核报告（Pre-Submission Review）

- 审核视角：Apple App Review 审核员 + iOS 工程师 + 合规顾问
- 审核对象：`ios/`（iPhone 主 App + Watch 伴侣 App）
- 审核方式：静态审查工程配置、Info.plist、权限声明、UI 状态机、网络与安全实现、元数据与文档
- 判定口径：✅ 安全 ｜ ⚠️ 有风险（建议先修） ｜ ❌ 高风险（大概率被拒）

---

## 0. 总体结论

**❌ 当前状态不建议提交。** 按现状提交，最可能的拒绝理由集中在 **Guideline 2.1（App Completeness）**，其次是 **5.1.2（隐私清单缺失）** 与 **设备族/方向声明不一致**。

工程本身**不是**"套壳 / 网页包装 / 单个按钮"——它有一套完整的原生实现（Bonjour 发现 → 设备管理 → Agent 探测 → 会话生命周期 → 命令提交与轮询 → 结果渲染 → Watch 语音链路）。真正的风险不在"功能太少"，而&#x5728;**"审核员拿不到 Mac，就打不开任何功能"**：这是审核流程上的死结，而不是产品价值问题。

风险汇总：

| #  | 审核维度                 | 对应准则              | 判定             |
| -- | -------------------- | ----------------- | -------------- |
| 1  | 最小功能性                | 4.2               | ⚠️ 有风险（中等，可辩护） |
| 2  | App 完整性 / 可测性        | 2.1               | ❌ 高风险          |
| 3  | 权限文案                 | 5.1.1             | ✅ 安全           |
| 4  | 隐私清单 / 隐私政策          | 5.1.2             | ❌ 高风险          |
| 5  | 数据收集与追踪              | 5.1.2             | ✅ 安全           |
| 6  | 导出合规（加密）             | App Store Connect | ⚠️ 有风险         |
| 7  | 设备族 / 屏幕方向（iPhone 独占） | 2.1、4.x           | ✅ 安全           |
| 8  | 商标与第三方品牌             | 5.2.1 / 2.3       | ⚠️ 有风险         |
| 9  | 安全（鉴权 + 明文传输）与 2.5.2 | 2.5.2 / 安全审查      | ⚠️ 有风险         |
| 10 | 元数据准确性（定位 vs 实际能力）   | 2.3               | ⚠️ 有风险         |
| 11 | Watch 伴侣 App 权限      | 5.1.1             | ✅ 安全           |
| 12 | 第三方 SDK / ATT        | 5.1.2             | ✅ 安全           |

### 提交前必须解决（P0）

1. **无 Mac 时的"死界面"**：没有引导、没有"需要配套 Mac 端"的说明、主按钮点了没反应 → 2.1
2. **审核员无法测试**：需要 Demo 模式 + 审核备注 → 2.1
3. **缺 `PrivacyInfo.xcprivacy`**，但代码使用 `UserDefaults` → 5.1.2
4. **App 内无隐私政策入口** → 5.1.2
5. **第三方品牌名直用**（OpenCode / Claude / Codex / Aider）→ 5.2.1

---

## 1. Minimum Functionality（Guideline 4.2）

### 判定：⚠️ 有风险（中等）

### 逐条核查

| 审核员会问的问题         | 结论             | 依据                                                                                                              |
| ---------------- | -------------- | --------------------------------------------------------------------------------------------------------------- |
| 功能过于简单？          | ❌ 不成立          | 有设备 CRUD + 持久化、Bonjour 自动发现与解析、Agent 探测/切换、Session 启停、命令提交 + 状态机轮询、结果/原始输出渲染、Watch 语音识别链路                       |
| 只是一个远程控制按钮？      | ❌ 不成立          | 9 个源文件、~70KB 原生代码；`CommandSubmitter` 是有完整阶段机（idle/sending/delivered/working/completed/completedRaw/failed）的提交引擎 |
| 只是网页包装？          | ❌ 不成立          | 无 WebView、无远程 H5；纯 SwiftUI                                                                                      |
| 只是简单客户端？         | ⚠️ 部分成立        | 核心价值 100% 依赖另一台设备上的另一个 App                                                                                      |
| 依赖外部设备后自身几乎没有功能？ | ⚠️ **这是真实风险点** | 没有 Mac 在线时，App 可操作项接近 0（见第 2 节）                                                                                 |
| 功能价值不足？          | ⚠️ 需靠审核备注说清    | 定位是"开发者远程操控自己 Mac 上的编码 Agent"，属于**远程控制/终端类**，同类已获批（Blink、Termius），但需要在备注里明确"仅控制用户自己的设备"                         |

### 结论说明

4.2 的判罚核心是"**是否提供了持久的娱乐或实用价值**"。BrewPing 属于实用工具类，且有 Watch 语音这条差异化原生能力，**本身站得住**。真正会被审核员写进拒绝信的是："该 App 需要额外硬件与配套软件，且未提供可供测试的路径" —— 这会被归到 2.1，但也会在 4.2 上留下印象分。

### 修改建议

1. **强化"本机可独立完成"的能力**（提升 4.2 抗辩力）：
   - 增加「最近一次会话/结果历史」本地缓存，离线也能查看；
   - 增加「命令模板 / 常用指令」本地管理（不依赖 Mac）；
   - 增加「连接诊断」（本机发起 ping/端口探测、给出可读诊断结论）。
2. **审核备注里把 4.2 正面论证写死**：原生 SwiftUI + watchOS 伴侣 App + 语音识别 + Bonjour 发现，并说明这是"用户自有设备的远程控制客户端"，非代理/中转服务。
3. **不要**在元数据里暗示"可以在任意地方控制任意电脑"，避免被读成可被滥用的远程控制工具。

---

## 2. App Completeness（Guideline 2.1）—— 本次最大风险

### 判定：❌ 高风险

### 审核员首次打开实录（无 Mac 在线 / 无设备 / 无 Agent）

代码路径：`ContentView.swift`

| 界面区域                                 | 审核员看到什么                                                    | 问题                   |
| ------------------------------------ | ---------------------------------------------------------- | -------------------- |
| 设备 Tab 栏（`deviceTabBar`，L163-188）    | **只有一个 "+" 圆形图标**，没有任何文字、没有空状态提示                           | ❌ 不知道要干什么            |
| AI Agents（`agentListCard`，L328-370）  | "Connect to detect agents."                                | ⚠️ 有文案，但没说"要连什么、怎么连" |
| Active Agent（`sessionCard`，L374-417） | "OpenCode" + 红点 + "Offline" + 一个绿色 **"Start Session"** 大按钮 | ❌ **点了完全没反应**        |
| Message（L98-113）                     | 输入框与 Send 均 disabled                                       | ⚠️ 可接受，但无解释          |
| Result（`resultView`，L470-476）        | "No message sent yet."                                     | ✅ 可接受                |

### 关键缺陷 1：主按钮静默失效（最容易被判定"功能不完整"）

```swift
// ContentView.swift L422-448 —— 无设备时该按钮并未被 disabled
.disabled(lifecycleBusy || sessionState == .starting || sessionState == .stopping)

// ContentView.swift L711-716 —— 点击后 guard 直接 return，无任何反馈
private func newSession() {
    guard let url = baseURL?.appendingPathComponent("api/session/start") else { return }
```

无设备时 `baseURL == nil` → 直接 return → **不改变状态、不弹提示、不记录日志**。审核员会得到一个"点了没用"的按钮，这是 2.1 的典型判罚证据。

### 关键缺陷 2：App 从未告诉用户"需要配套 Mac 端"

全 App 检索 `privacy|help|about|support|docs.` → 无任何帮助页、无任何说明。审核员在界面上看不到"BrewPing 需要你在 Mac 上运行 BrewPing Desktop"这句话。

### 关键缺陷 3：审核员无法完成任何一次成功路径

- 需要：一台 Mac + 运行 Desktop Receiver + 装好 Agent CLI + 处于同一局域网
- 审核员：一台 iPhone + Simulator，**永远无法走通**


### 修改建议（P0，按优先级）

1. **补齐首次启动引导（Onboarding）**
   - 无设备时，Form 顶部显示一个 `Section` 引导卡片，文案示例：
     > **Get started**
     >
     > 1. Install **BrewPing Desktop** on your Mac（附下载链接）
     > 2. Run it and keep it on the same Wi‑Fi
     > 3. Tap **Auto Discover** below, or enter your Mac's IP
   - 设备 Tab 栏空状态：把 "+" 换成 `Label("Add device", systemImage: "plus.circle.fill")`，让空态自解释。
2. **修掉静默失效的按钮**
   - 无设备时 `actionButton` 直接 `.disabled(true)`，或点击后 `sessionMessage = "No Mac connected. Add a device first."`；
   - 有设备但离线时，给出可读失败原因（现在 `refreshStatus()` 的 `catch` 只把 `online = false`，**没有把错误呈现给用户**，L628-643）。
3. **增加内置 Demo 模式（审核可测性，强烈建议）**
   - 在 Add Device 表单里加一行隐藏/显式入口：`Add Demo Device`，host 填 `demo://local`；
   - 命中 demo 时，所有 `api/*` 请求由本地 Mock 返回（status/agents/session/message 各一条固定响应），
   - 让审核员在**没有任何硬件**的情况下走完：添加设备 → 看到 Agent 列表 → Start Session → 发送命令 → 看到 Working → 看到 Completed 结果。
   - 这一条同时解决 2.1、4.2 与"依赖外部设备"三个问题，性价比最高。
4. **补错误态与退出路径**：现有实现没有死循环 Loading（✅ 这点是好的），但要在所有 `guard ... else { return }` 处补至少一条用户可见反馈。
5. **App 内加「Help / About」页**：放使用说明 + 隐私政策链接 + 支持邮箱。审核员找不到这些会追问。

---

## 3. 隐私权限文案（Guideline 5.1.1）

### 判定：✅ 安全

| 权限           | 声明位置                                                       | 文案                                                                                                  | 评价                                                                                                                             |
| ------------ | ---------------------------------------------------------- | --------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| 本地网络         | `ios/BrewPing/Info.plist` `NSLocalNetworkUsageDescription` | "BrewPing sends messages to your Mac Agent on the local network."                                   | ✅ 合规且说明了用途                                                                                                                     |
| Bonjour 服务类型 | `NSBonjourServices = [_brewping._tcp]`                     | —                                                                                                   | ✅ 与 `BonjourDiscovery.swift` 的 `NWBrowser(for: .bonjour(type: "_brewping._tcp"))` 及 `NetService(type: "_brewping._tcp.")` 完全一致 |
| 语音识别（iOS）    | `NSSpeechRecognitionUsageDescription`                      | "BrewPing uses speech recognition to transcribe the voice commands you send from your Apple Watch." | ✅ 准确。iOS 端用 `SFSpeechURLRecognitionRequest` 识别**音频文件**（L346），不采集麦克风，因此**不需要** `NSMicrophoneUsageDescription` —— 这一点是对的，不要误加    |
| 麦克风（Watch）   | `ios/Watch/Info.plist` `NSMicrophoneUsageDescription`      | "BrewPing uses the microphone to turn your voice into commands for your coding agent."              | ✅ 准确                                                                                                                           |
| 语音识别（Watch）  | `Watch/Info.plist` `NSSpeechRecognitionUsageDescription`   | —                                                                                                   | ✅ 已在                                                                                                                           |

### 注意事项

- Watch 端使用 `AVAudioRecorder` 且**未**使用 `WKExtendedRuntimeSession`（已确认）→ 仅在用户主动进入录音界面时采集，**无需** `UIBackgroundModes` 说明。这是正确的做法，保持现状。
- iOS 端 `WatchAudioPlayback`（`WatchConnectivityManager.swift` L525+）会把 Watch 录到的音频在本机回放，且已有"仅在 App 前台时出声"的约束（L130、L148）→ 合规，但建议在隐私政策里写明"语音仅用于本机转写与回放，不上传第三方"。

---

## 4. 隐私清单与数据合规（Guideline 5.1.2）

### 判定：❌ 高风险


### 4.1 缺 `PrivacyInfo.xcprivacy`

工程内检索 `*.xcprivacy` → **不存在**。但代码明确使用了**必填理由 API（Required Reason API）**：

```swift
// ios/BrewPing/DeviceStore.swift L12-13、L72-79
private let storageKey = "BrewPing.Devices"
private let activeKey = "BrewPing.ActiveDeviceID"
UserDefaults.standard.set(data, forKey: storageKey)
UserDefaults.standard.set(id, forKey: activeKey)
```

`UserDefaults` 属于 `NSPrivacyAccessedAPICategoryUserDefaults`，**必须**在隐私清单中声明理由（合法理由之一：`CA92.1` —— 仅访问 App 自身的数据）。缺失会导致 App Store Connect 上传后出现 ITMS 警告，并在人工审核阶段被要求补交。

**修复：新建 `ios/BrewPing/PrivacyInfo.xcprivacy` 并加入主 Target（Watch Target 同样需要，因为 `WatchSessionManager.swift` 也用 UserDefaults）：**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key>
    <false/>
    <key>NSPrivacyTrackingDomains</key>
    <array/>
    <key>NSPrivacyCollectedDataTypes</key>
    <array/>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>CA92.1</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
```

### 4.2 App 内没有隐私政策入口

全 App 检索 `privacy|policy` → 无命中。App Store 要求**每个 App 都必须提供隐私政策 URL**（App Store Connect 字段），建议同时在 App 内可点达（Help/About 页）。

### 4.3 数据收集与追踪 —— ✅ 安全

- 工程内**无任何第三方依赖**（无 `Package.resolved` / `Podfile` / `Cartfile`）
- 无 Firebase / Amplitude / Mixpanel / AppsFlyer / Adjust 等 SDK（已检索确认）
- 无 `ASIdentifierManager` / `advertisingIdentifier` → **不需要 ATT 弹窗，App Privacy 可全部勾"不收集数据"**
- 唯一出网行为：向**用户自己输入的局域网地址**发 HTTP 请求，数据不落第三方

### 4.4 App Privacy（App Store Connect 问卷）填报建议

| 数据类型            | 是否收集     | 理由                          |
| --------------- | -------- | --------------------------- |
| 联系信息 / 标识符 / 位置 | 否        | 无账号、无埋点                     |
| 用户内容（命令文本、语音）   | 建议填"不收集" | 仅在本机与用户自有 Mac 之间传输，开发者不接收   |
| 诊断              | 否        | 无崩溃上报 SDK                   |
| 追踪              | 否        | `NSPrivacyTracking = false` |

---

## 5. 导出合规（Encryption / Export Compliance）

### 判定：⚠️ 有风险

- 工程内检索 `CryptoKit|CommonCrypto|AES|SecKey|encrypt` → **无自定义加密实现**
- 通信为局域网明文 HTTP（`ManagedDevice.baseURL` 硬编码 `http://`）
- 若仅使用系统提供的 HTTPS/TLS 与豁免算法，可声明为豁免

**问题**：`Info.plist` 未包含 `ITSAppUsesNonExemptEncryption`，每次提交都会在 App Store Connect 被追问，答错会阻塞审核。

**修复**：在两个 `Info.plist` 增加：

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

> 注意：若后续加入自研加密 / 自建中继隧道的端到端加密，需要改为自分类（self-classification）或申请 CCATS。纯局域网明文 + 系统 TLS 属豁免范围。

---

## 6. 设备族 / 屏幕方向（Guideline 2.1、4.x）

### 判定：✅ 安全（iPhone 独占）

事实：

```
ios/BrewPing.xcodeproj/project.pbxproj
  TARGETED_DEVICE_FAMILY = 1            ← 仅 iPhone
ios/BrewPing/Info.plist
  UISupportedInterfaceOrientations = [UIInterfaceOrientationPortrait]   ← 仅竖屏
```

App 定位是 iPhone 上的遥控器（Watch 为伴侣端），设备族只声明 iPhone。
因此 App Store Connect 不需要额外的设备截图，也不存在"声明了未适配的设备族"
这类 2.1 问题。Watch target 为 `TARGETED_DEVICE_FAMILY = 4`，属正常配置。

---

## 7. 商标与元数据（Guideline 5.2.1 / 2.3）

### 判定：⚠️ 有风险

事实：App 界面与 README 直接使用第三方品牌名：

```
ios/BrewPing/WatchConnectivityManager.swift L18-20
  ["id": "opencode",  "name": "OpenCode"],
  ["id": "claude-code","name": "Claude"],
  ["id": "codex",     "name": "Codex"]
ios/BrewPing/ContentView.swift L62-63、L587-588、L608-609 …（多处 "OpenCode" 默认值）
README.md L7、L53-56、L80-86（OpenCode / Claude Code / Codex CLI / Aider）
```

风险：Apple 5.2.1 要求不得在未经授权时使用他人商标；App 名称、副标题、截图、描述里出现 "Claude"/"Codex" 等会被审核员核对授权。

### 修复建议

1. **App 名称 / 副标题 / 关键词里绝不出现第三方商标**（当前 App 名 BrewPing 是安全的，保持）。
2. App 描述改用中性表述：
   - ❌ "Control Claude Code, Codex and Aider from your iPhone"
   - ✅ "Monitor and control **your own** coding‑agent sessions running on your Mac. Works with popular CLI coding agents."
3. 界面内展示 Agent 名称属于"兼容性说明"，可保留，但建议补一行免责：
   > Agent names are trademarks of their respective owners. BrewPing is not affiliated with or endorsed by them.
4. README 里的安装命令（`curl -fsSL https://get.opencode.ai | sh`）**不要**出现在 App 内或截图里。

### 元数据准确性（2.3）

- 当前定位文案为 "monitor and control coding-agent sessions running on their own Mac from iPhone"，但**iOS 端并未实现任何 relay / 公网连接**（检索 `relay|wss://|https://|websocket` → 无命中），实际只能**同一局域网**使用。
- **不要**在描述里写 "from anywhere / 随时随地"。要么把定位收窄为 "on the same Wi‑Fi"，要么实现中继（那会是另一个大工程，且需 HTTPS + 鉴权）。

---

## 8. 安全与 Guideline 2.5.2

### 判定：⚠️ 有风险

### 8.1 命令通道无任何鉴权（重点）

检索 `Sources/App/HTTPAPI.swift`、`HTTPServer.swift`、iOS 全部源文件 → **没有任何 token / 密码 / 签名 / 配对机制**。通道为局域网明文 HTTP（`http://host:port`）。

后果：

- 同一 Wi‑Fi 下任何设备都可以向 Mac 的 `8787` 端口 POST `/api/message`，**在用户 Mac 上执行命令**；
- 审核员虽然不会做渗透测试，但"远程执行命令 + 无鉴权"组合，容易被读成"可被滥用的远程控制工具"，在 2.5.2 / 安全审查环节被追问。

**修复（P1，强烈建议随首发一起做）**

1. 首次配对：Mac 端生成 6 位配对码，iPhone 端输入后换取长期 `pairingToken`（Keychain 存储）；
2. 所有 `api/*` 请求带 `Authorization: Bearer <token>`，Mac 端校验；
3. 请求体加 `timestamp + nonce` 防重放；
4. 把 token 存入 **Keychain**（不要用 `UserDefaults`——顺便减少一个隐私清单条目）。

### 8.2 Guideline 2.5.2 边界说明

2.5.2 禁止 App 自身下载并执行会改变功能的代码。BrewPing 的**执行发生在用户自己的 Mac 上**，iPhone 只发送文本，不在 iOS 沙箱内下载/执行任何代码 → **不构成 2.5.2 违规**，与已获批的 SSH/终端类 App 同类。但需要在审核备注中明确这一点，否则容易被误读。

---


## 9. 其他发现（低风险，但建议一并处理）

| 项            | 现状                                                                                                                                                                    | 建议                                                                                                             |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| 版本号          | `CFBundleShortVersionString = 0.1`，`CFBundleVersion = 1`                                                                                                              | 首发建议用 `1.0.0`；`CFBundleVersion` 必须单调递增                                                                         |
| Bundle ID    | `local.brewping.app`                                                                                                                                                  | 技术上可行，但需在开发者账号下注册；建议换成自有反向域名（如 `com.<yourdomain>.brewping`），避免审核端对 `local.` 产生歧义                               |
| Watch 兼容性    | `WKCompanionAppBundleIdentifier = local.brewping.app`                                                                                                                 | 与主 App 一致 ✅；改 Bundle ID 时务必同步                                                                                  |
| 构建产物过期       | `ios/build-device/Debug-iphoneos/BrewPing.app/Info.plist` **缺** `NSBonjourServices`、`NSSpeechRecognitionUsageDescription`、`CFBundleIconName`；Watch 构建产物**缺**麦克风/语音权限键 | 提交前必须重新 Archive；并把 `build/`、`build-device/` 加入 `.gitignore`，防止旧产物误导                                            |
| 日志           | 53 处 `print()`，其中包含用户命令原文（`CommandReceiver.swift` L51、L58、`CommandSubmitter.swift` L122）                                                                              | 命令内容属用户内容，建议降级为 `#if DEBUG` 或改用 `OSLog` 并设 `privacy: .private`                                                 |
| 轮询           | `ContentView.task`（L133-136）每 5 秒无限轮询 `api/status`，只要视图存活就一直跑                                                                                                         | 建议随 `scenePhase` 暂停/恢复，减少后台耗电与审核侧"资源使用"质疑                                                                      |
| 已废弃 API      | `NavigationView`（iOS 16 起废弃）、`.onChange(of:)` 单参数闭包（iOS 17 起废弃）                                                                                                       | 改为 `NavigationStack` + 双参数 `onChange`；同时可顺带把 deployment target 提到 iOS 17                                       |
| Bundle 版本一致性 | iPhone `CFBundleShortVersionString = 0.1`，Watch 同为 `0.1`                                                                                                              | 保持一致 ✅                                                                                                         |
| 语言           | `CFBundleDevelopmentRegion = en`，但 UI 文案全英文、注释中文                                                                                                                      | UI 已全英文 ✅；如需上中国区建议后续做本地化（非阻塞）                                                                                  |
| 崩溃历史         | 曾有 `BrewPingDesktop` 在 `App.init()` 断言崩溃（macOS 端，2026-09-08）                                                                                                          | 与 iOS 审核无关，但说明初始化路径存在过风险，iOS 侧 `BrewPingApp.init()` 里做 `CommandSubmitter.bootstrap()` 同理：确保不在 init 阶段触碰尚未就绪的单例 |

---

## 10. 提交前修复清单（本轮已全部落地）

> 状态：**代码层面已全部完成**，并在本机通过「iOS + Watch 双 target 编译」与「Demo 链路运行时验证」。
> 下方「手动收尾」是只能在 Xcode / App Store Connect 里做的事。

### P0 — 不修必被拒

- [x] 无设备时的空状态引导卡片 + 说明"需要 Mac 端"
      → `ContentView.emptyStateCard`（4 步引导 + 两个按钮），设备栏空态也换成带文字的 `Add Device`
- [x] `Start Session` 在无设备时不得静默失效
      → `actionButton` 无设备时 `.disabled(true)` 且文案改为 `Add a device first`；`newSession()/stopSession()` 兜一层 `sessionMessage`
- [x] 增加 **Demo 模式**，让审核员零硬件走通完整链路
      → 新增 `DemoBackend` + `DemoURLProtocol`（`URLProtocol` 拦截 `demo.brewping.local`）；
        入口有两处：空态卡片的 `Try Demo Mode`、Add Device 表单里的 `Add Demo Device`
- [x] 新增 `PrivacyInfo.xcprivacy`
      → 主 App 声明 `NSPrivacyAccessedAPICategoryUserDefaults / CA92.1`；
        Watch 声明 `NSPrivacyAccessedAPICategoryFileTimestamp / C617.1`（录音残留清理读了 creationDate）
- [x] 隐私政策 URL（App Store Connect + App 内可点达）
      → 新增 `HelpView`（右上角 `?` 进入），内含 Privacy Policy / 支持邮箱 / 免责声明 / 版本号
- [x] `TARGETED_DEVICE_FAMILY` 改为 `1`
      → `project.pbxproj` Debug/Release 均已改为 `1`；部署目标提升至 iOS 17.0
- [x] 元数据与界面去除第三方商标的"背书感"表述，补免责声明
      → Agent 列表底部加 `BrewPingConfig.trademarkDisclaimer`；README 改写定位并新增商标免责章节
- [x] 重新 Archive
      → `build-device/` 已加入 `.gitignore`（旧产物缺权限键，不参与任何判断）。Archive 步骤见下方

### P1 — 强烈建议随首发

- [x] 命令通道加配对 + `Bearer token` + nonce 防重放，token 存 Keychain
      → Mac 端新增 `PairingStore`：6 位一次性配对码（10 分钟）换长期 token，
        token 落 `~/.brewping/pairing.json`（0600）；`HTTPServer` 解析全部请求头；
        `HTTPAPI.handle` 对除 `/api/pair`、`GET /api/status` 外的一切接口做鉴权，
        写操作额外校验 `X-BrewPing-Timestamp`（±120s）与 `X-BrewPing-Nonce`（不可重用）
      → iOS 端新增 `KeychainStore` + `DeviceAuth` + `BrewPingHTTP`，统一出口拼鉴权头
- [x] `ITSAppUsesNonExemptEncryption = false`
      → 主 App 与 Watch 两个 `Info.plist` 均已加入（无自研加密，仅系统随机数）
- [x] 元数据收窄为"同一局域网"
      → README 与 Help 页均明确"同一局域网、不提供公网中继"
- [x] App 内 `Help / About` 页
      → `HelpView.swift`：使用说明 / 配对步骤 / Demo 说明 / 隐私政策 / 支持邮箱 / 商标免责 / 版本

### P2 — 质量优化

- [x] `NavigationView` → `NavigationStack`；`.onChange` 改双参数
      → 主 App 与 Watch 全部替换（因此部署目标提升到 iOS 17 / 依赖 watchOS 10+）
- [x] `print()` 收敛为 `OSLog` 且隐私标记
      → 新增 `BrewPingLog`（主 App）与 `WatchLog`（Watch）；
        命令原文、语音转写、文件名、主机名一律 `privacy: .private`
- [x] 状态轮询随 `scenePhase` 暂停
      → `ContentView.runStatusLoop()` + `.task(id: scenePhase)`：进后台立即停，回前台立刻刷新
- [x] Bundle ID 规范化；`build*` 目录加 `.gitignore`
      → `com.brewping.ios` / `com.brewping.ios.watchkitapp`；`.gitignore` 加 `build*/`、`ios/build*/`
- [x] 版本号 `1.0.0`
      → 两个 `Info.plist` 与 `MARKETING_VERSION` 均已改为 `1.0.0`

### 追加：App 内中英切换（已上线版本的功能增强）

界面原先只有英文。现支持在 App 内选「跟随系统 / 简体中文 / English」，**切换后立即生效、无需重启、无需改系统语言**；Apple Watch 端跟随 iPhone 的选择。

- [x] `LanguageManager`（iOS）/ `WatchLanguageManager`（Watch）
      → 两条通道：① SwiftUI `Text("字面量")` 靠根视图 `.environment(\.locale, ...)`；
        ② String 上下文（状态变量、格式化、拼接）靠全局 `L(_:_:)` / `LW(_:_:)` 读 `.lproj` bundle 快照
- [x] 中英文案表
      → `BrewPing/{en,zh-Hans}.lproj/Localizable.strings`、`Watch/{en,zh-Hans}.lproj/Localizable.strings`；
        key 统一用英文原文；`knownRegions` 已加 `"zh-Hans"`
- [x] 入口：Help & About 页顶部「Language / 语言」`Picker`
- [x] Watch 语言由 iPhone 经 WCSession `applicationContext` 的 `"language"` 键同步

> **否定过的方案（勿再尝试）**：`object_setClass(Bundle.main, ...)` 覆盖 `localizedString(forKey:value:table:)`
> 对 SwiftUI **完全无效**（中文能显示只是因为系统语言恰好是中文）。已删除该实现与 `ObjectiveC` 依赖。

**验证**：模拟器实测「系统中文 + App 内选 English → 全英文」「跟随系统 → 全中文」，Help 页与主界面均正确；
Demo 链路（`/api/status`、`/api/agents` 均 200）与状态轮询（~5.6s/次）不受影响。

#### 追加修复：本地化引入的启动崩溃 `EXC_BAD_ACCESS (code=1, address=0x1)`

- [x] **根因**：`ContentView.swift` 未配对卡片（`notPairedCard`）的
      `Text("Open \(macAppName) on \(device.host), reveal its pairing code, then enter the code for this device.")`
      是 SwiftUI `LocalizedStringKey`（**2 个插值**），而 `zh-Hans.lproj` 的译文写成了
      `"在 %@（%@）上打开 %@，显示配对码后在此设备上输入。"`（**3 个 `%@`**）。
      SwiftUI 按中文译文去取第 3 个实参 → 读到不存在的值 → 崩溃。
      触发条件很低：**有设备但尚未配对**（首次添加 Mac、或重装 App 后）即进入该卡片。
- [x] **修法**：译文占位符**个数必须与代码插值数相等**，且**顺序不可调换**（SwiftUI 按出现顺序填充，不要用 `%2$@` 重排）。
      中文语序与英文不同时改措辞——本条改为 `"打开 %@（位于 %@），显示配对码后在此设备上输入。"`。
- [x] **防呆**：新增 `ios/Scripts/check_localization.py`，检查 ① 同一 key 在 en/zh 的 `%@` 个数不一致；
      ② 代码插值数 < 译文占位符数；③ 某 key 只在一侧。退出码 1 = 有会崩的问题。
      **每次改完 `Localizable.strings` 都应运行**——此类崩溃常藏在低频分支（未配对、网络错误），手动点 UI 难以覆盖。
- [x] **实测**：中文 + 未配对设备 → 卡片正常渲染、进程存活、无崩溃日志；英文同场景正常；中文 + Demo 设备回归正常。

> 这类崩溃的定位难点：崩溃点与本地化毫无字面关联（栈顶常是 SwiftUI 内部帧），
> 但本质是 `String(format:)` 实参不足。看到 `address=0x1` 且近期动过本地化，优先查占位符个数。

**另需在 App Store Connect 手动做**：若希望商店页也显示中文，在
「App 信息 → 本地化」中新增「简体中文」，并把 App 名称/副标题/描述/关键词填上中文版本（这一步不影响 App 内切换，不填则商店页仍只显示英文）。

---

## 11. 手动收尾（必须在 Xcode / App Store Connect 完成）

### 11.1 先替换这几处占位值

| 位置 | 当前占位值 | 说明 |
| --- | --- | --- |
| `ios/BrewPing/BrewPingConfig.swift` → `privacyPolicyURLString` | `https://brewping.app/privacy` | **必须换成公网可访问的真实地址**，App Store Connect 的 Privacy Policy URL 填同一个 |
| `ios/BrewPing/BrewPingConfig.swift` → `supportEmail` | `support@brewping.app` | 审核员联系用 |
| `project.pbxproj` → `PRODUCT_BUNDLE_IDENTIFIER` | `com.brewping.ios`（含 `.watchkitapp`） | 我按 `com.<你的域名>.brewping` 规则取的占位值。若你的域名不同，**改这里 + `Watch/Info.plist` 的 `WKCompanionAppBundleIdentifier`**，并同步改 `BrewPingLog`/`WatchLog` 的 `subsystem` |
| `DEVELOPMENT_TEAM` | `TGA82PM3DZ` | 若不是你的 Team ID 需替换 |

### 11.2 重新 Archive（必须重做，不能用 `build-device/` 里的旧产物）

```bash
# 1) 确认命令行工具指向 Xcode（本机当前指向 CommandLineTools，直接跑 xcodebuild 会报错）
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

# 2) 打开工程 → 选择 Any iOS Device (arm64)
open ios/BrewPing.xcodeproj

# 3) Product → Archive → Distribute App → App Store Connect → Upload
```

Archive 完成后，用下面两条命令自查产物是否补齐了旧产物缺的键：

```bash
plutil -p <App.xcarchive>/Products/Applications/BrewPing.app/Info.plist \
  | grep -E "NSBonjourServices|NSSpeechRecognitionUsageDescription|CFBundleIconName|ITSAppUsesNonExemptEncryption"
unzip -l <导出的 xcarchive>/Products/Applications/BrewPing.app/PrivacyInfo.xcprivacy
```

### 11.3 上传前跑一遍配对链路（真机）

1. Mac 端运行 `BrewPing Desktop` → 菜单栏点 **Show Pairing Code**；
2. iPhone 端 `Add Device` → 填 Host / Port + 6 位配对码 → Add；
3. 观察：设备卡片上的 `key.slash` 小锁消失，状态点变绿；
4. 反例验证：故意填错配对码 → 应看到 `Pairing failed` 且设备不会被标记为已配对。

### 11.4 审核备注（替换附录 A 的 Demo 路径描述）

Demo 入口已改为空状态卡片上的 **Try Demo Mode**（或 `Add Device` → `Add Demo Device`）。
另外必须告诉审核员：**真实设备需要先在 Mac 端取 6 位配对码**，否则会看到 "Not paired"。

## 附录 A：审核备注模板（App Review Notes，英文，可直接粘贴）

```
BrewPing is a remote monitor/controller for coding-agent sessions running on the
user's OWN Mac. The iPhone app is a client; the Mac app is a separate receiver.

HOW TO TEST WITHOUT HARDWARE (Demo Mode):
1. Launch BrewPing. The first screen explains that a companion Mac app is required.
2. Tap "Try Demo Mode" on that card (or "+" in the device bar → "Add Demo Device").
3. The app now shows a simulated Mac with an agent list (OpenCode / Claude Code / Codex CLI).
4. Tap "Start Session", type a command, tap "Send".
5. You will see: Sending → Delivered → Working → Completed with a result.

PAIRING (for a real Mac): the Mac menu bar app shows a 6-digit pairing code
(Button: "Show Pairing Code"). Enter it in Add Device. Without a code the device
is stored as "not paired" and every command is rejected with 401.

WHAT THE APP DOES (native, no WebView):
- Bonjour (_brewping._tcp) discovery of the user's Mac on the same Wi-Fi
- Device management, agent detection, session start/stop
- Command submission with a polling state machine
- watchOS companion app with speech-to-text command input

NOTES FOR REVIEWERS:
- The app only connects to devices on the local network that the user configured.
- No account, no analytics, no tracking, no third-party SDKs.
- No code is downloaded or executed on iOS. Commands are sent as plain text to the
  user's own Mac, which the user installed and controls.
- Agent product names are used only to indicate compatibility. BrewPing is not
  affiliated with or endorsed by their vendors.
- Privacy Policy: <YOUR_URL>
- Support: <YOUR_EMAIL>
```

## 附录 B：本报告的事实来源

- `ios/BrewPing/Info.plist`、`ios/Watch/Info.plist`
- `ios/BrewPing.xcodeproj/project.pbxproj`（L317-436：部署目标、设备族、Bundle ID）
- `ios/BrewPing/ContentView.swift`（空状态、按钮状态机、网络层）
- `ios/BrewPing/CommandReceiver.swift`（命令提交引擎）
- `ios/BrewPing/DeviceStore.swift`（UserDefaults 使用）
- `ios/BrewPing/BonjourDiscovery.swift`（Bonjour 服务类型）
- `ios/BrewPing/WatchConnectivityManager.swift`、`ios/Watch/*.swift`（语音/麦克风/录音回放）
- `ios/build-device/**/Info.plist`（对比构建产物与源码的差异）
- `README.md`（产品定位与第三方品牌引用）
