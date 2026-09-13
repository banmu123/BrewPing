package com.brewping.android

import android.app.Application
import android.content.Context
import com.brewping.android.api.DesktopApiClient
import com.brewping.android.discovery.DesktopDiscoveryManager
import com.brewping.android.repository.DesktopRepository
import com.brewping.android.store.ConversationStore
import com.brewping.android.store.DeviceStore
import com.brewping.android.store.ModelStore
import com.brewping.android.store.PairingStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/**
 * Application class — provides singleton instances of Discovery, API, Repository, and DeviceStore.
 */
class BrewPingApp : Application() {

    // 应用内语言（system/zh/en）：Application 层也 wrap，Store 层的
    // getString 才能拿到目标语言的资源（与 Activity 同一语言）。
    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(LocalePrefs.wrap(base))
    }

    lateinit var discoveryManager: DesktopDiscoveryManager
        private set

    lateinit var apiClient: DesktopApiClient
        private set

    lateinit var repository: DesktopRepository
        private set

    lateinit var deviceStore: DeviceStore
        private set

    lateinit var conversationStore: ConversationStore
        private set

    lateinit var modelStore: ModelStore
        private set

    lateinit var pairingStore: PairingStore
        private set

    override fun onCreate() {
        super.onCreate()
        instance = this

        deviceStore = DeviceStore(this)
        discoveryManager = DesktopDiscoveryManager(this)
        pairingStore = PairingStore(this)
        apiClient = DesktopApiClient(pairingStore)
        repository = DesktopRepository(discoveryManager, apiClient)
        conversationStore = ConversationStore(apiClient)
        modelStore = ModelStore(apiClient, CoroutineScope(SupervisorJob() + Dispatchers.Main), this)
    }

    companion object {
        lateinit var instance: BrewPingApp
            private set
    }
}
