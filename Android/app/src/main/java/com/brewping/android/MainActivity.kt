package com.brewping.android

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.viewmodel.compose.viewModel
import com.brewping.core.model.PairingDeepLink
import com.brewping.core.LocalePrefs
import com.brewping.android.ui.HomeScreen
import com.brewping.android.ui.HomeViewModel
import com.brewping.android.ui.theme.BrewPingTheme

class MainActivity : ComponentActivity() {

    // App 内语言切换：与 Application 同步 wrap， recreate() 后立即生效
    override fun attachBaseContext(newBase: android.content.Context) {
        super.attachBaseContext(LocalePrefs.wrap(newBase))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        // 冷启动：系统相机扫桌面二维码 → 带着 brewping:// 数据拉起 App。
        // 只做"解析 + 存进 pendingAction"，HomeScreen 消费后自动配对。
        PairingDeepLink.handle(intent?.data?.toString())

        val app = application as BrewPingApp

        setContent {
            BrewPingTheme {
                val viewModel: HomeViewModel = viewModel(
                    factory = HomeViewModel.Factory(
                        app.repository,
                        app.deviceStore,
                        app.conversationStore,
                        app.modelStore,
                        app.applicationContext,
                    )
                )
                HomeScreen(viewModel = viewModel)
            }
        }
    }

    // 热路径：App 已在前台/后台时再扫一张码。
    // launchMode=singleTask（见 AndroidManifest）保证走这里而不是叠新实例，
    // 因此必须覆写 onNewIntent 并 setIntent，否则第二次扫码会被丢掉（iOS `.onOpenURL` 同职）。
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        PairingDeepLink.handle(intent.data?.toString())
    }
}
