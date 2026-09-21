package com.brewping.android.provisioning

import android.content.Context
import android.util.Log
import com.google.android.gms.wearable.Wearable
import com.brewping.core.LocalePrefs
import com.brewping.core.model.ManagedDevice
import com.brewping.core.provision.ProvisionProtocol
import org.json.JSONObject

/**
 * Wear provisioning 发送方（手机端，v1 最小实现）：
 * 把**当前激活设备**的 host / port / token 经 Wearable Data Layer 下发给所有已连接的手表节点。
 *
 * - 触发点：配对成功后、激活设备切换 / 冷启动时（HomeViewModel 两处钩子，幂等）；
 * - 没有手表连接 → 静默跳过（不报错、不打扰手机端用户）；
 * - 发送失败只打日志：手表端有 "Waiting for phone" 状态，用户重开手机 App 即会重发；
 * - 不做复杂的双向同步协议（任务 §9）。
 *
 * ⚠️ token 属敏感数据：手表端接收后必须经 PairingStore（Keystore）加密存储；
 *    本类只负责传输，不做任何持久化。
 */
object WearProvisionSender {

    private const val TAG = "BrewPingWearProvision"

    fun sendToWatch(context: Context?, device: ManagedDevice, token: String) {
        if (context == null) return
        if (token.isEmpty()) return
        val host = device.host.trim()
        val port = device.port.trim().toIntOrNull() ?: return
        if (host.isEmpty() || port <= 0) return

        val appContext = context.applicationContext
        val payload = JSONObject().apply {
            put("deviceId", device.id)
            put("deviceName", device.name)
            put("host", host)
            put("port", port)
            put("token", token)
            // 语言偏好跟随手机端（手表端首次进入跟随系统，配置后跟随手机）
            put("langMode", LocalePrefs.mode(appContext).raw)
        }
        val data = payload.toString().toByteArray(Charsets.UTF_8)

        Wearable.getNodeClient(appContext).connectedNodes
            .addOnSuccessListener { nodes ->
                if (nodes.isEmpty()) {
                    Log.i(TAG, "no wear nodes connected; skip provision")
                    return@addOnSuccessListener
                }
                val messageClient = Wearable.getMessageClient(appContext)
                nodes.forEach { node ->
                    messageClient
                        .sendMessage(node.id, ProvisionProtocol.MESSAGE_PATH, data)
                        .addOnSuccessListener {
                            Log.i(TAG, "provisioned watch node: ${node.displayName}")
                        }
                        .addOnFailureListener {
                            Log.w(TAG, "provision to ${node.displayName} failed: ${it.message}")
                        }
                }
            }
            .addOnFailureListener { Log.w(TAG, "get connected nodes failed: ${it.message}") }
    }
}
