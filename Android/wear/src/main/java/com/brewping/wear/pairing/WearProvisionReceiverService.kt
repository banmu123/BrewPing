package com.brewping.wear.pairing

import android.util.Log
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService
import com.brewping.core.LocalePrefs
import com.brewping.wear.WearApp
import com.brewping.wear.data.WearProvisionStore
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import org.json.JSONObject

/**
 * Data Layer provisioning 接收端：手机把 host / port / token 下发给手表。
 *
 * payload（JSON，UTF-8）：
 * ```json
 * { "deviceId": "...", "deviceName": "...", "host": "192.168.1.10", "port": 8787,
 *   "token": "...", "langMode": "system|zh|en" }
 * ```
 *
 * 存储分级：token → PairingStore（Keystore 加密）；其余 → WearProvisionStore（普通 SP）。
 * 手机重新配对会覆盖旧配置（幂等）。语言偏好同步到 LocalePrefs（跟随手机端设置，
 * 不为语言单独设计通信协议）。
 */
class WearProvisionReceiverService : WearableListenerService() {

    override fun onMessageReceived(messageEvent: MessageEvent) {
        if (messageEvent.path != WearProvisionStore.MESSAGE_PATH) return
        val app = applicationContext as? WearApp ?: return

        runCatching {
            val json = JSONObject(String(messageEvent.data, Charsets.UTF_8))
            val deviceId = json.getString("deviceId")
            val token = json.getString("token")
            val host = json.getString("host")
            val port = json.getInt("port")
            require(deviceId.isNotEmpty() && token.isNotEmpty() && host.isNotEmpty() && port > 0)

            val deviceName = json.optString("deviceName", host)
            app.container.provisionStore.save(deviceId, deviceName, host, port)
            app.container.pairingStore.saveToken(deviceId, token)

            // 语言跟随手机端（可选字段；老版本手机端不传 → 保持现状）
            json.optString("langMode", "").takeIf { it.isNotEmpty() }?.let { raw ->
                LocalePrefs.setMode(applicationContext, LocalePrefs.LangMode.fromRaw(raw))
            }

            Log.i(TAG, "provisioned: $deviceName ($host:$port)")
            ProvisionBus.post()
        }.onFailure {
            Log.w(TAG, "provision message malformed: ${it.message}")
        }
    }

    companion object {
        private const val TAG = "BrewPingWearProvision"
    }
}

/** 轻量事件：配置到达 / 变更后通知 UI 立即刷新（不引入更多基础设施）。 */
object ProvisionBus {
    private val _events = MutableSharedFlow<Unit>(extraBufferCapacity = 4, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    val events: SharedFlow<Unit> = _events

    fun post() {
        _events.tryEmit(Unit)
    }
}
