import com.android.build.gradle.LibraryExtension

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

// 🚨 :core 是手机端（:app）与手表端（:wear）共用的客户端逻辑层。
// 依赖方向：wear/app → core → HTTP。UI 组件一律不得进入本模块。
//
// 版本链与 :app 相同（AGP 8.10 支持的最高 API 正好是 36）：
//   compileSdk 36 → AGP ≥ 8.9 → Gradle ≥ 8.11.1 → JDK 17
// minSdk 取两端更低者（手机 26；Wear 30）——库模块必须 ≤ 消费方。
android {
    namespace = "com.brewping.core"
    compileSdk = 36

    defaultConfig {
        minSdk = 26
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    testOptions {
        unitTests {
            // 让 android.jar 中的方法（Log、ContextWrapper 等）返回默认值而非抛 "Stub!"，
            // 以便在纯 JVM 上测试 DesktopApiClient / PairingStore（与 :app 同一约定）。
            isReturnDefaultValues = true
        }
    }
}

dependencies {
    // api：:core 的公开签名里直接暴露（suspend / StateFlow / OkHttp 类型），
    // 消费方（:app / :wear）必须能看到，否则编译不过。
    api("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.1")
    api("com.squareup.okhttp3:okhttp:4.12.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.1")
    // 真实的 org.json 实现：android.jar 中的 org.json 在单元测试中不可用
    testImplementation("org.json:json:20240303")
}
