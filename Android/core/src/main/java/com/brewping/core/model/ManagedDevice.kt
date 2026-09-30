package com.brewping.core.model

import com.brewping.core.demo.DemoBackend

/**
 * 设备 OS 类型 (matches iOS DeviceOSType)
 */
enum class DeviceOSType(val label: String) {
    Mac("Mac"),
    Windows("Win"),
    Linux("Linux"),
    ;

    companion object {
        fun fromRaw(raw: String): DeviceOSType = when (raw.lowercase()) {
            "mac", "macos", "darwin" -> Mac
            "windows", "win" -> Windows
            "linux" -> Linux
            else -> Mac
        }
    }
}

/**
 * 一台被管理的电脑 (matches iOS ManagedDevice)
 */
data class ManagedDevice(
    val id: String,
    val name: String,
    val host: String,
    val port: String,
    val osType: DeviceOSType = DeviceOSType.Mac,
) {
    val displayName: String
        get() = "${osType.label} $name"

    /**
     * 是否为内置 Demo 设备（对齐 iOS `ManagedDevice.isDemo`）。
     *
     * 用主机名**派生**判定，而不是新增一个存储字段：旧版本已写进
     * `SharedPreferences` 的 JSON 里没有这个键，加一个非可选字段会让反序列化失败、
     * 把用户设备列表整个清空。
     */
    val isDemo: Boolean
        get() = host.trim().equals(DemoBackend.HOST, ignoreCase = true)

    fun baseUrl(): String? {
        val h = host.trim()
        val p = port.trim()
        if (h.isEmpty() || p.isEmpty()) return null
        return "http://$h:$p"
    }

    companion object {
        fun new(
            name: String = "",
            host: String = "",
            port: String = "8787",
            osType: DeviceOSType = DeviceOSType.Mac,
        ): ManagedDevice = ManagedDevice(
            id = java.util.UUID.randomUUID().toString().take(8).lowercase(),
            name = name,
            host = host,
            port = port,
            osType = osType,
        )
    }
}
