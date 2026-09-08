package com.brewping.android.model

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
