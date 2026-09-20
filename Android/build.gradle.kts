// 🚨 升级工具链前先读这段 —— 这几项版本是**互相绑定**的，不能单独动：
//
//   targetSdk = 36（Play 自 2026-08-31 的硬性要求）
//     └─ 要求 compileSdk = 36
//          └─ 要求 Android Gradle Plugin ≥ 8.9.0
//               └─ 要求 Gradle ≥ 8.11.1、JDK 17、SDK Build-Tools ≥ 35.0.0
//
// **AGP 8.10 支持的最高 API 级别正好是 API 36**（见 AGP 8.10.0 release notes 的 Compatibility 一节）。
// 也就是说当前是「刚好够用」的状态：要升到 API 37（Android 17）必须**同时**升 AGP。
// 反过来，若要把 AGP 升到 8.11+，请一并复核 Gradle / JDK 是否满足新版要求。
//
// 另：API 37 起本地网络访问需要 ACCESS_LOCAL_NETWORK 运行时权限（详见 Android/README.md），
// 那时本项目的 NSD 发现与局域网 HTTP 都要做权限适配 —— 不只是改版本号。
plugins {
    id("com.android.application") version "8.10.0" apply false
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.1.0" apply false
}
