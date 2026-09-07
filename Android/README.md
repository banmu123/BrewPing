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
├── model/          — Device, AgentInfo, DesktopStatus
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

## Minimum SDK

- **minSdk:** 26 (Android 8.0)
- **targetSdk:** 34 (Android 14)

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
