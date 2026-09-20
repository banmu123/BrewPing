# BrewPing Android

Android phone app for BrewPing — discovers BrewPing Desktop on the local network via mDNS.

## Architecture

```
UI (Compose)
  ↓
ViewModel (StateFlow)
  ↓
Repository
  ↓
DiscoveryManager (NSD/mDNS)  ←→  DesktopApiClient (OkHttp)
```

### Package structure

```
com.brewping.android/
├── model/          — Device, AgentEntry, DesktopStatus, CommandPhase, SessionState
├── discovery/      — DesktopDiscoveryManager (NSD)
├── api/            — DesktopApiClient (OkHttp HTTP)
├── repository/     — DesktopRepository (coordinates discovery + API)
├── ui/
│   ├── HomeViewModel.kt
│   ├── HomeScreen.kt
│   └── theme/      — Color, Theme, Type
├── BrewPingApp.kt  — Application (singleton providers)
└── MainActivity.kt — Entry point
```

## Build

```bash
# From Android directory
./gradlew assembleDebug

# Or open in Android Studio and run
```

## SDK 配置

- **minSdk:** 26 (Android 8.0)
- **compileSdk:** 36 (Android 16)
- **targetSdk:** 36 (Android 16)

> **为什么是 36：** Google Play 自 **2026-08-31** 起要求新 App 与所有更新必须面向
> Android 16（API 36）或更高版本，否则无法提交。不要再按 API 35 的旧写法配置。
>
> **这几个版本是绑定的**，动一项就要往下全部核对：

| 依赖 | 要求 | 本项目 |
|---|---|---|
| `targetSdk` | 36（Play 要求） | 36 |
| `compileSdk` | 必须 ≥ `targetSdk` | 36 |
| Android Gradle Plugin | ≥ 8.9.0（AGP 8.10 支持的最高 API 级别正好是 36） | 8.10.0 |
| Gradle | ≥ 8.11.1（AGP 8.10 的下限） | 8.14 |
| JDK | 17（AGP 8.10 的下限） | CI 用 Temurin 17 |
| SDK Platform | `platforms;android-36` | 见下 |

**本机需要安装的 SDK 组件**（Android Studio → Settings → SDK Manager）：

- SDK Platforms 页 → 勾选 **Android 16 (API 36)**
- SDK Tools 页 → **Android SDK Build-Tools 36.x**

若本机 `JAVA_HOME` 指向 JDK 17 以上的版本，构建时请临时指定 JDK 17，例如：

```bash
JAVA_HOME=/path/to/jdk17 ./gradlew assembleDebug
```

> ⚠️ **下一个里程碑（API 37 / Android 17）：** Android 17 引入 `ACCESS_LOCAL_NETWORK`
> 运行时权限，本地网络默认对应用**封闭** —— 届时本项目依赖的 **NSD/mDNS 发现**、
> **局域网 HTTP**、乃至 **`.local` 域名解析**都会被拦截（`NsdManager`、OkHttp 等一并受影响）。
> Play 将在 **2027-08-31** 强制 API 37。等到升 targetSdk 37 时，必须：在 manifest 声明
> `ACCESS_LOCAL_NETWORK`、在运行时请求（属 `NEARBY_DEVICES` 权限组）、并处理拒绝/撤销后的
> 降级 UX（回退到手动 IP 连接）。**光改版本号会导致发现功能整体失效。**

## Key design decisions

- **NSD discovery** for `_brewping._tcp` — platform-native, no third-party dependencies
- **StateFlow** for reactive UI updates
- **Repository pattern** coordinates discovery + API polling
- **Model classes** are platform-agnostic — don't assume macOS or any specific Desktop OS
- TXT records (version, agent, platform, deviceId, deviceName) are read when available

## Testing on real device

1. Enable Developer Options on the Android phone
2. Connect phone and Mac to the **same Wi-Fi network**
3. Start BrewPing Desktop on Mac
4. Install and launch the Android app
5. The app should automatically discover the Desktop and show its status

> **Note:** Android Emulator uses a virtual network and cannot discover real mDNS services. Use a physical device for discovery testing.
