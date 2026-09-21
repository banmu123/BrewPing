package com.brewping.wear

import android.app.Application
import android.content.Context
import com.brewping.core.LocalePrefs
import com.brewping.core.api.DesktopApiClient
import com.brewping.core.store.PairingStore
import com.brewping.core.transport.BrewPingTransport
import com.brewping.core.transport.DirectHttpTransport
import com.brewping.wear.data.WearProvisionStore
import com.brewping.wear.data.WearRepository

class WearApp : Application() {

    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
    }
}

/**
 * 手工依赖容器（Wear 端不引 DI 框架）。
 *
 * 依赖方向：UI → ViewModel → [WearRepository] → [BrewPingTransport] → [DesktopApiClient] → HTTP。
 * token 存储统一走 [PairingStore]（Keystore AES-256/GCM，与手机端同一套实现）。
 */
class AppContainer(context: Context) {
    val pairingStore = PairingStore(context)
    val provisionStore = WearProvisionStore(context)
    private val api = DesktopApiClient(pairingStore)
    private val transport: BrewPingTransport = DirectHttpTransport(api)
    val repository = WearRepository(transport)
}
