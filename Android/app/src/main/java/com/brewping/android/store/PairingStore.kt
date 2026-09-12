package com.brewping.android.store

import android.content.Context
import android.content.SharedPreferences

/**
 * 配对令牌存储（契约对齐 iOS `DeviceAuth`）：
 * 每台设备一个长期 token，配对码换取后持久化，卸载 App 才会丢失。
 *
 * Windows / Mac 桌面端的鉴权矩阵：
 *  - 所有请求（除 `GET /api/status`、`POST /api/pair`）都要 `Authorization: Bearer <token>`；
 *  - 写操作（非 GET）额外要 `X-BrewPing-Timestamp`（±120s）+ `X-BrewPing-Nonce`（一次性）。
 */
class PairingStore(context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences("brewping_pairing", Context.MODE_PRIVATE)

    /** 取设备的长期 token；未配对返回 null。 */
    fun token(deviceId: String): String? =
        prefs.getString(KEY_PREFIX + deviceId, null)?.takeIf { it.isNotEmpty() }

    fun isPaired(deviceId: String): Boolean = token(deviceId) != null

    fun saveToken(deviceId: String, token: String) {
        prefs.edit().putString(KEY_PREFIX + deviceId, token).apply()
    }

    /** 解除配对（设备删除 / 换机器时调用）。 */
    fun clearToken(deviceId: String) {
        prefs.edit().remove(KEY_PREFIX + deviceId).apply()
    }

    companion object {
        private const val KEY_PREFIX = "BrewPing.Token."
    }
}
