package com.brewping.wear.data

import android.content.Context
import android.content.SharedPreferences
import com.brewping.core.model.DesktopDevice

/**
 * 手表端 provisioning 配置的持久化。
 *
 * 🚨 分级存储（任务硬性要求）：
 *  - `host` / `port` / `deviceId` / `deviceName` —— 非敏感 → 普通 SharedPreferences；
 *  - `token` —— **绝不**写这里，走 [com.brewping.core.store.PairingStore]
 *    （Android Keystore AES-256/GCM 加密，与手机端同一实现、同一密文格式）。
 *
 * App 重启后配置不丢失；手机重新配对会覆盖旧值（save 幂等）。
 */
class WearProvisionStore(context: Context) {

    /** 一次有效配置（不含 token —— token 只在 [com.brewping.core.store.PairingStore] 里）。 */
    data class Provisioned(
        val deviceId: String,
        val deviceName: String,
        val host: String,
        val port: Int,
    ) {
        /** 组装成 API 层使用的设备对象（ip 与 host 同值：局域网直连）。 */
        fun toDesktopDevice(): DesktopDevice = DesktopDevice(
            id = deviceId,
            name = deviceName,
            host = host,
            ip = host,
            port = port,
        )
    }

    private val prefs: SharedPreferences =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    val provisioned: Provisioned?
        get() {
            val id = prefs.getString(KEY_DEVICE_ID, null)?.takeIf { it.isNotEmpty() } ?: return null
            val host = prefs.getString(KEY_HOST, null)?.takeIf { it.isNotEmpty() } ?: return null
            val port = prefs.getInt(KEY_PORT, -1).takeIf { it > 0 } ?: return null
            return Provisioned(
                deviceId = id,
                deviceName = prefs.getString(KEY_DEVICE_NAME, host) ?: host,
                host = host,
                port = port,
            )
        }

    /** 是否配置过（含 token 是否存在由调用方用 PairingStore 校验）。 */
    val hasProvision: Boolean get() = provisioned != null

    fun save(deviceId: String, deviceName: String, host: String, port: Int) {
        prefs.edit()
            .putString(KEY_DEVICE_ID, deviceId)
            .putString(KEY_DEVICE_NAME, deviceName)
            .putString(KEY_HOST, host)
            .putInt(KEY_PORT, port)
            .apply()
    }

    /** 手机端重新配对 / 解绑时清空本地配置（token 由调用方 clearToken）。 */
    fun clear() {
        prefs.edit().clear().apply()
    }

    companion object {
        /** Data Layer 消息 path —— 单一来源是 :core 的 [com.brewping.core.provision.ProvisionProtocol]。 */
        const val MESSAGE_PATH = com.brewping.core.provision.ProvisionProtocol.MESSAGE_PATH

        private const val FILE = "brewping_wear_provision"
        private const val KEY_DEVICE_ID = "BrewPing.Wear.DeviceId"
        private const val KEY_DEVICE_NAME = "BrewPing.Wear.DeviceName"
        private const val KEY_HOST = "BrewPing.Wear.Host"
        private const val KEY_PORT = "BrewPing.Wear.Port"
    }
}
