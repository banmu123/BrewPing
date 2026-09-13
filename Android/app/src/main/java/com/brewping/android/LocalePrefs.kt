package com.brewping.android

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.content.res.Configuration
import java.util.Locale

// ─── App 内语言切换（对齐 iOS LangMode system/zh/en）──────────────────────────
//
// iOS 语义：跟随系统 / 中文 / 英文，App 内切换立即生效，不依赖系统语言。
// Android 实现：偏好存 SharedPreferences（与 DeviceStore 同一套落盘习惯），
// Application / Activity 在 attachBaseContext 里用 LocalePrefs.wrap 包一层
// Context —— 之后 Compose 的 stringResource 与 Store 层的 getString 都会
// 拿到目标语言的资源。切换后调用 activity.recreate() 即时生效。

object LocalePrefs {

    enum class LangMode(val raw: String) {
        System("system"), Zh("zh"), En("en");

        companion object {
            fun fromRaw(raw: String?): LangMode =
                entries.firstOrNull { it.raw == raw } ?: System
        }
    }

    private const val FILE = "brewping.settings"
    private const val KEY = "brewping.langMode"

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun mode(context: Context): LangMode =
        LangMode.fromRaw(prefs(context).getString(KEY, LangMode.System.raw))

    fun setMode(context: Context, mode: LangMode) {
        prefs(context).edit().putString(KEY, mode.raw).apply()
    }

    /**
     * 把 [context] 的语言配置覆盖为当前 LangMode。
     * 在 Application 与 MainActivity 的 attachBaseContext 中调用；
     * System 模式原样返回（跟随系统）。
     */
    fun wrap(context: Context): Context {
        val mode = mode(context)
        if (mode == LangMode.System) return context
        val locale = Locale(mode.raw)
        Locale.setDefault(locale)
        val config = Configuration(context.resources.configuration)
        config.setLocale(locale)
        config.setLayoutDirection(locale)
        return context.createConfigurationContext(config)
    }
}
