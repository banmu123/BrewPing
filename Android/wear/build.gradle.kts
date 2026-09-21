plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// 🚨 Wear OS 手表端（v1：状态 / 审批 / 语音发指令）。
//
// 版本链与 :app 相同：compileSdk / targetSdk 36（Wear OS 6 = API 36，Android 16）。
// ⚠️ AGP 8.10 支持的最高 API 正好是 36 —— 要升 API 37 必须**先升 AGP**，
//    且手机端（:app）与手表端必须同批升（见根 build.gradle.kts 的版本链说明）。
//
// applicationId 与手机端**一致**（Google Play 多 APK 要求同包名同签名）；
// versionCode 区间独立（36xxxxx），绝不与手机端重叠。
// minSdk 30 = Wear OS 3.0（Compose for Wear OS 支持的最低 API）。
android {
    namespace = "com.brewping.wear"

    compileSdk = 36

    defaultConfig {
        applicationId = "com.brewping.android"
        minSdk = 30
        targetSdk = 36
        versionCode = 3600001
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }
}

dependencies {
    implementation(project(":core"))

    // ─── Wear Compose（版本独立于手机端 compose-bom，必须显式钉）──────────────
    // 稳定线 1.6.2（2026-09-09）。🚨 不要引手机版 androidx.compose.material3 ——
    // 它与 Wear 版各有自己的 MaterialTheme，混用会主题串台。
    val wearCompose = "1.6.2"
    implementation("androidx.wear.compose:compose-material3:$wearCompose")
    implementation("androidx.wear.compose:compose-foundation:$wearCompose")
    implementation("androidx.wear.compose:compose-navigation:$wearCompose")

    // Wear 基础库 + 系统语音输入（RemoteInput / RecognizerIntent 辅助）
    implementation("androidx.wear:wear:1.3.0")
    implementation("androidx.wear:wear-input:1.2.0-beta01")

    // Data Layer provisioning（手机 → 手表下发 host/port/token）
    implementation("com.google.android.gms:play-services-wearable:18.2.0")

    // 普通Compose 基础构件沿用手机端 BOM（ui / runtime / compiler 不换 Wear 版）
    val composeBom = platform("androidx.compose:compose-bom:2025.04.00")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")

    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.9.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.0")
    implementation("androidx.core:core-ktx:1.16.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.1")

    // UI 预览 / 调试
    debugImplementation("androidx.compose.ui:ui-tooling")
}
