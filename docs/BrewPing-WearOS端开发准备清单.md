# BrewPing Wear OS 端开发准备清单

> **范围**：在现有 Android 端（`Android/`，单模块 `:app`）旁新增 Wear OS 手表端。
> **目标平台**：Wear OS 6 = **API 36**（Android 16，代号 Baklava）；Wear OS 6.1 = API 36.1。
> **当前基线**：compileSdk / targetSdk 36、minSdk 26、Kotlin 2.1.0、AGP 8.10.0、Gradle 8.14、JDK 17、Compose BOM 2025.04.00。
> **桌面端协议**：局域网明文 HTTP + `Authorization: Bearer <token>` + `X-BrewPing-Timestamp` / `X-BrewPing-Nonce`（120s 防重放窗口）—— **桌面端无需任何改动**。

---

## 0. 结论速览

准备分三层，缺一层都开不了工：

| 层 | 内容 | 性质 |
|---|---|---|
| **装** | 较新的 Android Studio + Wear OS 6 系统镜像 + Wear 模拟器 AVD（+ 建议一块实体表） | 环境，约半小时 |
| **定** | ① 通信架构（中继 vs 直连）② v1 功能范围 | 决策，必须先拍板 |
| **改** | 抽 `:core` 共用库模块 → 新建 `:wear` 模块 → 依赖 → Manifest | 工程，`:core` 抽取是**硬前置** |

另有一条本次清点才浮现的工作项（见 [第 4 节](#4-新增工作项执行状态尚未进-http)）：**桌面端的执行状态没有进 HTTP 响应**，客户端拿不到「是否卡住」。

---

## 1. 环境准备

### 1.1 需要新增

| # | 事项 | 具体做法 | 备注 |
|---|---|---|---|
| 1 | **Android Studio 较新版** | 用最新发布版 / 预览版 | Wear OS 6 的镜像只出现在 SDK Manager 的 **Android 16.0 ("Baklava")** 条目下，旧版看不到该镜像 |
| 2 | **Wear OS 6 系统镜像** | SDK Manager → **SDK Platforms** → 展开 `Android 16.0 ("Baklava")` → 勾选 Wear OS 6.0 的 **ARM64 v8a** 或 **Intel x86_64** 镜像 | SDK 包名形如 `system-images;android-36;android-wear;<arch>` |
| 3 | **Wear 模拟器 AVD** | Device Manager → Create device → **Category 选 `Wear OS`**（不要选 Phone）→ 选刚装的 Wear OS 6 镜像 | 官方镜像已预装 Play 商店 / Play 服务 / 语音识别服务 |
| 4 | **实体表（可选但强烈建议）** | Wear OS 3+（API 30+）任意一块（Pixel Watch / Galaxy Watch） | 模拟器测不出真实性能与蓝牙行为；开 ADB over Wi-Fi 或经手机调试 |

### 1.2 已就绪 —— 无需准备

手机端升级到 API 36 时，表端要的东西已经一并到位：

- Gradle **8.14**、AGP **8.10.0**、Kotlin **2.1.0**、JDK **17**
- SDK `platforms;android-36`、`build-tools;36.0.0`
- 版本链约束（改一项必须往下核对）：`targetSdk 36 → compileSdk 36 → AGP ≥ 8.9（8.10 支持的最高 API 正好是 36）→ Gradle ≥ 8.11.1 → JDK 17`
- 局域网 HTTP、配对 token 体系、对话 / Agent / 模型 / 审批等**全部 HTTP 接口**

---

## 2. 开工前必须拍板的两个决策

### 2.1 通信架构：手表的数据走哪条路

| | ① 经手机中继 | ② 直连桌面（推荐） |
|---|---|---|
| 链路 | 手表 → 手机（Wearable Data Layer）→ 桌面 | 手机**一次性**下发 `host/port/token` → 手表自己发 HTTP |
| 手表是否需要 Wi-Fi | 不需要 | 需要 |
| 手机是否必须在场 | 必须（蓝牙范围内） | 仅首次配置需要 |
| 客户端代码复用 | 中继协议要为每个接口单独搭一套 | 抽 `:core` 后**直接复用 `DesktopApiClient`** |
| 新增依赖 | `com.google.android.gms:play-services-wearable` | 无（仅一次性用 Data Layer 传凭据） |
| 配对体验 | 手机已配对，手表零配置 | 手表拿现成 token，零配置 |
| 改动量 | 手机端要加 `WearableListenerService` + 请求/响应协议 | 集中在手表端 |

**建议**：走 **②**。凭据只在下发时经 Data Layer 走一次，之后手表与桌面直连。若手表拿不到 Wi-Fi，再把 ① 作为兜底路径加进来。

### 2.2 v1 功能范围

建议先做三件（手表最适配的场景），其余放第二步：

1. **看状态** —— 指定对话的当前执行状态与最后一段输出；
2. **审批** —— 危险命令的批准 / 拒绝（`GET /api/approvals` + `POST /api/approvals/:id`；挂起请求超时即拒，正适合「抬手批一下」）；
3. **发指令** —— 语音口述为主（表盘输入法体验差）。

→ 第二步再考虑：切 Agent / 模型、多设备切换、对话置顶归档。

---

## 3. 工程改造步骤（按顺序执行）

### 步骤 1 —— 抽 `:core` 库模块（硬前置）

当前所有客户端逻辑都在 `:app` 单模块内，**手表模块无法直接复用**。需先抽出 `Android/core/`（`com.android.library`），把下列内容迁过去（建议一并迁走对应的 `src/test`，单测跟着代码走）：

| 目录 / 文件 | 说明 |
|---|---|
| `api/DesktopApiClient.kt` | 唯一 HTTP 出口 |
| `model/` | `Conversation.kt`、`Device.kt`、`ManagedDevice.kt`、`PairingDeepLink.kt` |
| `repository/DesktopRepository.kt` | 数据聚合层 |
| `store/` | `PairingStore.kt`（含 Android Keystore AES-256/GCM 令牌加密）、`DeviceStore.kt`、`ConversationStore.kt`、`ModelStore.kt` |
| `discovery/DesktopDiscoveryManager.kt` | NSD / mDNS 局域网发现 |
| `BrewPingConfig.kt` | 隐私政策 URL、支持邮箱（两端共用） |
| `LocalePrefs.kt` | 语言偏好 |

**留在 `:app` 不动**：`MainActivity.kt`、`BrewPingApp.kt`、`ui/**`（手机版界面与 `HomeViewModel`）。
（原列表中的 `CommandReceiver.kt` 死桩已于 2026-09-24 删除，不再是 `:app` 的组成部分。）

> ⚠️ 迁移时必须保持 `PairingStore` 的 4 个公开方法签名不变（`token` / `isPaired` / `saveToken` / `clearToken`），并保留「明文 SharedPreferences 透明迁移（无 `v1:` 前缀 → 重新加密）」逻辑，否则老用户会掉配对。

### 步骤 2 —— 注册并新建 `:wear` 模块

```kotlin
// Android/settings.gradle.kts
include(":app")
include(":core")   // 新增
include(":wear")   // 新增
```

新模块 `Android/wear/build.gradle.kts`：

```kotlin
android {
    namespace = "com.brewping.wear"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.brewping.android"   // 与手机一致（Play 多 APK 要求同包名）
        minSdk = 30                              // Wear OS 3.0 起；Compose for Wear OS 支持 API 30+
        targetSdk = 36
        versionCode = 3600001                    // 与手机版本号区间不得重叠
        versionName = "0.1.0"
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }
}
dependencies { implementation(project(":core")) }
```

### 步骤 3 —— Wear 依赖

| 用途 | 构件 |
|---|---|
| Wear Material 3 组件 | `androidx.wear.compose:compose-material3` |
| 基础与列表（`ScalingLazyColumn` 等） | `androidx.wear.compose:compose-foundation` |
| 导航（SwipeDismissableNavHost） | `androidx.wear.compose:compose-navigation` |
| 语音输入 / RemoteInput | `androidx.wear:wear`、`androidx.wear:wear-input` |
| Tiles（把「待审批」做成一瞥卡片，可选） | `androidx.wear.tiles`（含 protolayout） |
| 仅中继方案需要 | `com.google.android.gms:play-services-wearable` |

🚨 **两个坑**：

- **不要引手机版 `androidx.compose.material3`** —— 它和 Wear 版各有自己的 `MaterialTheme`，混用会出现颜色 / 字体不一致。非 Wear 的 Compose 基础构件（`compose.ui`、`compose.runtime`）仍可共用手机端的 `compose-bom`。
- **Wear Compose 的版本独立于手机端的 `compose-bom:2025.04.00`**，需在 `:wear` 模块内显式钉版本。参考：稳定线 **1.6.2**（2026-09-09 发布），RC 线 1.7.0-rc01。落地时以 Android Studio 的依赖补全为准。

### 步骤 4 —— Manifest 清单项

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- 必须是 <manifest> 的直接子元素，且 required 不能写 false -->
    <uses-feature android:name="android.hardware.type.watch" android:required="true" />

    <!-- 网络：与手机端保持一致 -->
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
    <uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />

    <application android:name=".WearApp"
                 android:usesCleartextTraffic="true">  <!-- 局域网明文 http -->
        <meta-data android:name="com.google.android.wearable.standalone" android:value="true" />
        <!-- … -->
    </application>
</manifest>
```

🚨 `required` 若写成 `false`，会产出「手机 + 手表共用同一个 APK」的形态，**Play 不支持该配置**。

### 步骤 5 —— 配对方式改造（手表没有摄像头）

手机端的配对入口是 QR 扫码（`zxing` + CameraX + `QrScanScreen.kt`），表端**用不了**。表端只能：

- 手输 6 位配对码（走数字键盘组件），或
- 语音念配对码，或
- **推荐**：由手机经 Data Layer 直接把 `host / port / token` 下发，手表零配置（即 2.1 的 ② 方案）。

---

## 4. 新增工作项：执行状态尚未进 HTTP

**背景**：2026-09-21 并入的 `Sources/App/ConversationRun.swift` 建立了单一执行状态机，九个阶段：

```
idle / submitting / queued / thinking / streaming / stopping / completed / failed / stalled
```

绑定 `commandId + conversationId`，阈值集中在 `RunTiming`（首字 8s、stalled 30s、停止确认 10s、UI 合并 100ms）。

**清点结论**：`ConversationRun` 目前**仅被 Mac 桌面端（`Sources/BrewPingDesktop/DesktopAppState.swift`）使用**；`Sources/App/HTTPAPI.swift` 与 `Sources/Protocol/` 均未引用它 → **该状态没有序列化进任何 HTTP 响应**。也就是说：手机端和未来的手表端**都拿不到**「正在思考 / 正在流式 / 已卡住」这类服务端信号。

**两条路**：

| | (a) 客户端自行推断 | (b) 状态进 HTTP（推荐） |
|---|---|---|
| 做法 | 按「最后一次输出时间」猜 | 把 run 阶段加入 `/api/message/:id` 或对话级接口 |
| 效果 | 弱 —— 正是桌面端刚消灭掉的体验 | 三端一致，一次开发共同受益 |
| 影响面 | 仅表端 | 需同步手机端（建议一起做） |

→ **建议与 2.1 的架构决策一并拍板**。若选 (b)，v1 的「看状态」才真正成立。

---

## 5. 功能面对齐参考：`ios/Watch/`

iOS 手表端已有同一需求在 watchOS 上的完整解法，Wear 版可逐项对齐：

| watchOS 侧文件 | 职责 | Wear OS 对应做法 |
|---|---|---|
| `WatchConversationViews.swift` | 会话浏览与详情 | Wear Compose 的 `ScalingLazyColumn` + `SwipeDismissableNavHost` |
| `VoiceCommandView.swift` + `WatchAudioRecorder.swift` | 语音口述指令 | `androidx.wear:wear-input` / 系统语音识别 |
| `WatchSessionManager.swift` | 与手机的中继通道 | Wearable Data Layer（`MessageClient` / `ChannelClient`） |
| `WatchTheme.swift` | 主题与令牌 | 复刻 Latte 令牌到 Wear Material 主题 |
| `WatchLocalized.swift` + `WatchLanguageManager.swift` | 中英文案与语言切换 | `:wear` 的 `values/` + `values-zh/`（**key 集合必须与手机端一致**） |
| 手机侧 `WatchConnectivityManager.swift` | 手机端中继 | 手机侧 `WearableListenerService`（仅中继方案需要） |

---

## 6. 发布与商店

- Wear APK 与手机 APK 在**同一个 Play 应用条目下分别上传**：**包名与签名一致**，但 **versionCode 不得重叠**。Google 建议前两位放 targetSdk，例如 `36xxx`。
- 商店需要**单独的 Wear 形态截屏**（与手机截图分开提交）。
- 用中继方案时两端都需 Google Play services（Wear OS 官方镜像已内置）。
- 发布资产仍走 GitHub Release 的既有约定（Mac 三个 DMG 变体 + Windows setup.exe/msi）；Wear 端走 Play，不进 GitHub Release。

---

## 7. 未来风险：API 37 的本地网络权限

Google Play 自 **2027-08-31** 起要求面向 API 37+，而 **API 37 = 本地网络默认封闭**，需要运行时权限 `ACCESS_LOCAL_NETWORK`（属 `NEARBY_DEVICES` 权限组）：

- 受影响：**NSD / mDNS 发现、局域网明文 HTTP、`.local` 解析、OkHttp 全部请求**；
- 表端若是直连方案，**必然踩到**这个坑；
- 新写一个端时直接按「声明 + 运行时请求 + 拒绝后降级为手动填 IP」实现，比事后补便宜得多；
- ⚠️ **只改版本号会让发现功能整体失效** —— 手机端与表端是同一个坑。

---

## 8. 验收检查表

**环境**
- [ ] Android Studio 可看到 `Android 16.0 ("Baklava")` 下的 Wear OS 6.0 镜像
- [ ] Wear 模拟器 AVD 可启动并进入应用栅格
- [ ] （可选）实体表可通过 ADB 连上

**工程**
- [ ] `:core` 抽出后 `:app` 编译与单测全绿（166 个用例不回退）
- [ ] `settings.gradle.kts` 含 `:app` / `:core` / `:wear`
- [ ] `:wear` 模块 `assembleDebug` 通过
- [ ] Manifest 含 `android.hardware.type.watch`（`required="true"`）与 `standalone`
- [ ] 未引入手机版 `androidx.compose.material3`

**功能（v1）**
- [ ] 表端拿到 `host/port/token` 并能 `GET /api/status`
- [ ] 能列出对话并查看最后一段输出
- [ ] 能批准 / 拒绝一条待审批请求
- [ ] 能语音发出一条指令并在对话中看到结果
- [ ] 中英文案 key 集合与手机端一致

**发布**
- [ ] Wear APK 的 versionCode 与手机不重叠
- [ ] 已准备 Wear 形态截屏

---

## 附：相关文件索引

| 位置 | 内容 |
|---|---|
| `Android/settings.gradle.kts` | 模块注册（当前仅 `:app`） |
| `Android/build.gradle.kts` | AGP / Kotlin 版本与**版本链绑定说明** |
| `Android/app/build.gradle.kts` | 手机端构建配置（API 36 说明与依赖清单） |
| `Android/app/src/main/AndroidManifest.xml` | 权限与深链契约（`brewping://pair?...`） |
| `Android/app/src/main/java/com/brewping/android/` | 客户端源码（`:core` 抽取来源） |
| `Sources/App/ConversationRun.swift` | 九个执行阶段与 `RunTiming` 阈值 |
| `Sources/App/HTTPAPI.swift` | HTTP 路由（当前**未**暴露执行阶段） |
| `ios/Watch/` | watchOS 端参考实现 |
| `docs/BrewPing-iOS端结构与模块划分.md` | iOS 端布局与状态流 |
