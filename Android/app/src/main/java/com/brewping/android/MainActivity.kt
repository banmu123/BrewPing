package com.brewping.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.viewmodel.compose.viewModel
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

        val app = application as BrewPingApp

        setContent {
            BrewPingTheme {
                val viewModel: HomeViewModel = viewModel(
                    factory = HomeViewModel.Factory(
                        app.repository,
                        app.deviceStore,
                        CommandReceiver(),
                        app.conversationStore,
                        app.modelStore,
                        app.applicationContext,
                    )
                )
                HomeScreen(viewModel = viewModel)
            }
        }
    }
}
