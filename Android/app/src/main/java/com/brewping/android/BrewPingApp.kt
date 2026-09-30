package com.brewping.android

import android.app.Application
import android.content.Context
import com.brewping.core.api.DesktopApiClient
import com.brewping.core.demo.DemoBackend
import com.brewping.core.demo.DemoInterceptor
import com.brewping.core.demo.DemoStrings
import com.brewping.android.discovery.DesktopDiscoveryManager
import com.brewping.android.repository.DesktopRepository
import com.brewping.android.store.ConversationStore
import com.brewping.android.store.DeviceStore
import com.brewping.android.store.ModelStore
import com.brewping.core.store.PairingStore
import com.brewping.core.LocalePrefs
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
        // Demo 拦截器挂在这里：发往 `demo.brewping.local` 的请求被短路成模拟响应，
        // 真实设备完全不受影响，全部 API 调用点也无需感知（对齐 iOS 把
        // DemoURLProtocol 挂进 URLSession 的做法）。
        apiClient = DesktopApiClient(pairingStore, DemoInterceptor(DemoBackend(demoStrings())))
        repository = DesktopRepository(discoveryManager, apiClient)
        conversationStore = ConversationStore(apiClient, this)
        modelStore = ModelStore(apiClient, CoroutineScope(SupervisorJob() + Dispatchers.Main), this)
    }

    /**
     * Demo 后端的文案。
     *
     * 放在 `:app` 而不是 `:core`：`:core` 是手机端 / 手表端共用的纯逻辑库，不带资源；
     * 由消费方从自己的 `strings.xml` 构造后注入，这样 Demo 文案跟随应用内语言切换，
     * 且中英 key 集合与其它文案一起维护（对齐 iOS 把 Demo 文案放进 Localizable.strings）。
     */
    private fun demoStrings() = DemoStrings(
        hostLabel = getString(R.string.demo_host_label),
        commandResponse = getString(R.string.demo_command_response),
        commandFailed = getString(R.string.demo_command_failed),
        conversationTitleBound = getString(R.string.demo_conversation_title_bound),
        conversationTitleUnbound = getString(R.string.demo_conversation_title_unbound),
        systemPromptBound = getString(R.string.demo_system_prompt_bound),
        systemPromptUnbound = getString(R.string.demo_system_prompt_unbound),
        replyBound = getString(R.string.demo_reply_bound),
        replyUnbound = getString(R.string.demo_reply_unbound),
    )

    companion object {
        lateinit var instance: BrewPingApp
            private set
    }
}