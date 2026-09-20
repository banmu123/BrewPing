plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.brewping.android"

    // 🚨 compileSdk / targetSdk = 36（Android 16），别再按 API 35 的老教程改回去。
    // Google Play 自 2026-08-31 起要求新 App 与所有更新必须面向 API 36+，否则无法提交。
    // 版本链是**绑定**的，改一项必须往下核对（根 build.gradle.kts 里有完整说明）：
    //   targetSdk 36 → compileSdk 36 → AGP ≥ 8.9.0 → Gradle ≥ 8.11.1 → JDK 17 → platforms;android-36
    compileSdk = 36

    defaultConfig {
        applicationId = "com.brewping.android"
        minSdk = 26
        // 36 同时启用 Android 16 的两项强制行为，本项目均已满足，无需额外代码：
        //  1) 边到边（windowOptOutEdgeToEdgeEnforcement 被停用）—— MainActivity 已调 enableEdgeToEdge()
        //  2) 预测性返回（android:enableOnBackInvokedCallback 默认 true，onBackPressed/KEYCODE_BACK 不再派发）
        //     —— HomeScreen:171 用的是 compose BackHandler（走 OnBackPressedDispatcher），属受支持路径
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables {
            useSupportLibrary = true
        }
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

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }

    testOptions {
        unitTests {
            // 让 android.jar 中的方法（Log、ContextWrapper 等）返回默认值而非抛 "Stub!" 异常，
            // 以便在纯 JVM 上测试 ApiClient / DeviceStore。
            isReturnDefaultValues = true
        }
    }
}

dependencies {
    // Compose BOM
    val composeBom = platform("androidx.compose:compose-bom:2025.04.00")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    // Compose
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")

    // Activity & Lifecycle
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.9.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.0")

    // Core
    implementation("androidx.core:core-ktx:1.16.0")

    // OkHttp
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // QR 扫码（配对码）：zxing 纯 Java 解码 + CameraX 取景
    implementation("com.google.zxing:core:3.5.3")
    val camerax = "1.4.2"
    implementation("androidx.camera:camera-core:$camerax")
    implementation("androidx.camera:camera-camera2:$camerax")
    implementation("androidx.camera:camera-lifecycle:$camerax")
    implementation("androidx.camera:camera-view:$camerax")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.1")

    // Testing
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.1")
    testImplementation("org.mockito:mockito-core:5.10.0")
    // 真实的 org.json 实现：android.jar 中的 org.json 在单元测试中不可用
    testImplementation("org.json:json:20240303")

    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.5.1")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")

    // Debug
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
