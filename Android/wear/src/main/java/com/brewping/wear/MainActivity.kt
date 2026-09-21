package com.brewping.wear

import android.content.Context
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.brewping.core.LocalePrefs
import com.brewping.wear.ui.WearApp
import com.brewping.wear.ui.WearViewModel

class MainActivity : ComponentActivity() {

    /**
     * 语言：优先用 provisioning 同步的手机端偏好（LocalePrefs，:core 共用实现）；
     * 没有配置过 → 跟随系统（LocalePrefs.wrap 对 system 模式原样返回）。
     */
    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(LocalePrefs.wrap(newBase))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val container = (application as WearApp).container

        val factory = viewModelFactory {
            initializer {
                WearViewModel(
                    repository = container.repository,
                    provisionStore = container.provisionStore,
                    pairingStore = container.pairingStore,
                )
            }
        }

        // 🚨 `by viewModel()` 委托只能在 @Composable 上下文用 —— 放进 setContent 里。
        setContent {
            val vm: WearViewModel = viewModel(factory = factory)
            WearApp(viewModel = vm)
        }
    }
}
