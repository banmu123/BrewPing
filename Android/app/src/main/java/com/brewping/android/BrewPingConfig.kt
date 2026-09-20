package com.brewping.android

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build

/**
 * 上架相关的对外常量集中在这里，方便统一替换。
 *
 * ⚠️ 与 iOS `ios/BrewPing/BrewPingConfig.swift` 一一对应：改一处必须同批改另一端，
 * 否则两端对外口径（隐私政策地址、支持邮箱、免责声明）会漂移。
 */
object BrewPingConfig {

    /**
     * 隐私政策地址（Google Play 的隐私政策字段填同一个）。
     * 托管在 GitHub Pages（源文件 `docs/privacy.html`），公网可访问，无需自建服务器。
     */
    const val PRIVACY_POLICY_URL = "https://banmu123.github.io/BrewPing/privacy.html"

    /** 支持邮箱。 */
    const val SUPPORT_EMAIL = "czkbanmu@163.com"

    /** 桌面端产品名。App 内说明文案统一引用它，避免各写各的。 */
    const val DESKTOP_APP_NAME = "BrewPing Desktop"

    /**
     * 展示用版本号，取自 `build.gradle.kts` 的 `versionName`。
     *
     * 刻意不用 `BuildConfig`：AGP 8 起 `buildConfig` 默认关闭，读 `PackageManager`
     * 更稳，也不必为了一个版本号去改构建配置。
     */
    fun displayVersion(context: Context): String = runCatching {
        val pm = context.packageManager
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageInfo(context.packageName, 0)
        }
        info.versionName
    }.getOrNull().orEmpty().ifEmpty { "1.0.0" }
}
