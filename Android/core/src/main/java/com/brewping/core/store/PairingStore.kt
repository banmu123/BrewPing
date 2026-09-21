package com.brewping.core.store

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 配对令牌存储（契约对齐 iOS `DeviceAuth` / `KeychainStore`）：
 * 每台设备一个长期 token，配对码换取后持久化，卸载 App 才会丢失。
 *
 * Windows / Mac 桌面端的鉴权矩阵：
 *  - 所有请求（除 `GET /api/status`、`POST /api/pair`）都要 `Authorization: Bearer <token>`；
 *  - 写操作（非 GET）额外要 `X-BrewPing-Timestamp`（±120s）+ `X-BrewPing-Nonce`（一次性）。
 *
 * ## 存储方式
 *
 * 密文存 SharedPreferences，密钥由 **Android Keystore** 持有（AES-256/GCM，密钥不出安全硬件）。
 * 选 Keystore 而不是 `EncryptedSharedPreferences` 的原因：后者要新增 AndroidX 依赖，
 * 而这里只需要「加密一个短字符串」，用平台自带 API 就够 —— **零新依赖**。
 *
 * 存量兼容：旧版本写的是**明文**，读取时透明迁移（读出来 → 加密回写），用户无需重新配对。
 */
class PairingStore(context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    /** 取设备的长期 token；未配对（或解不开）返回 null。 */
    fun token(deviceId: String): String? {
        val raw = prefs.getString(KEY_PREFIX + deviceId, null)?.takeIf { it.isNotEmpty() }
            ?: return null

        decrypt(raw)?.let { return it }

        if (raw.startsWith(ENCRYPTED_PREFIX)) {
            // 有加密前缀却解不开：密钥已随旧设备丢失（例如换机后从云端备份恢复）。
            // 无解，只能重新配对 —— 返回 null，让上层走既有的「需要重新配对」路径。
            return null
        }

        // 旧版本写入的明文令牌 → 透明迁移（原样返回，同时加密回写）
        saveToken(deviceId, raw)
        return raw
    }

    fun isPaired(deviceId: String): Boolean = token(deviceId) != null

    fun saveToken(deviceId: String, token: String) {
        // 加密失败（Keystore 异常）时退回明文：与改造前行为一致，至少不阻断配对。
        // 正常设备上不会走到这里。
        val stored = encrypt(token) ?: token
        prefs.edit().putString(KEY_PREFIX + deviceId, stored).apply()
    }

    /** 解除配对（设备删除 / 换机器时调用）。 */
    fun clearToken(deviceId: String) {
        prefs.edit().remove(KEY_PREFIX + deviceId).apply()
    }

    // ─── Keystore 加解密 ──────────────────────────────────────────────────────

    private fun secretKey(): SecretKey? = try {
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (ks.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.secretKey
            ?: generateKey()
    } catch (t: Throwable) {
        null
    }

    private fun generateKey(): SecretKey {
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    /** → `v1:<b64(iv)>:<b64(ciphertext)>`；失败返回 null。 */
    private fun encrypt(plain: String): String? = try {
        val key = secretKey() ?: error("keystore unavailable")
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key)
        // GCM 的 iv 由 Cipher 随机生成（12 字节），随密文一起存
        val payload = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        ENCRYPTED_PREFIX +
            Base64.encodeToString(cipher.iv, Base64.NO_WRAP) +
            ":" +
            Base64.encodeToString(payload, Base64.NO_WRAP)
    } catch (t: Throwable) {
        null
    }

    /** 只处理带前缀的密文；明文（旧数据）一律返回 null，由调用方判定。 */
    private fun decrypt(stored: String): String? {
        if (!stored.startsWith(ENCRYPTED_PREFIX)) return null
        return try {
            val body = stored.substring(ENCRYPTED_PREFIX.length)
            val sep = body.indexOf(':')
            if (sep <= 0) return null
            val iv = Base64.decode(body.substring(0, sep), Base64.NO_WRAP)
            val payload = Base64.decode(body.substring(sep + 1), Base64.NO_WRAP)
            val key = secretKey() ?: return null
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))
            String(cipher.doFinal(payload), Charsets.UTF_8)
        } catch (t: Throwable) {
            null
        }
    }

    companion object {
        private const val FILE = "brewping_pairing"
        private const val KEY_PREFIX = "BrewPing.Token."

        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "brewping.pairing.token.v1"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
        /** 密文标记：既是版本号，也是「这段是密文」的判据（旧数据没有它，视为明文）。 */
        private const val ENCRYPTED_PREFIX = "v1:"
    }
}
