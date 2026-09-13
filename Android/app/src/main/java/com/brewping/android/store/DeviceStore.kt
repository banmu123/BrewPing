package com.brewping.android.store

import android.content.Context
import android.content.SharedPreferences
import com.brewping.android.model.DeviceOSType
import com.brewping.android.model.ManagedDevice
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

/**
 * 管理多台设备的持久化存储 (matches iOS DeviceStore)
 */
class DeviceStore(private val context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences("brewping_devices", Context.MODE_PRIVATE)

    private val _devices = MutableStateFlow<List<ManagedDevice>>(emptyList())
    val devices: StateFlow<List<ManagedDevice>> = _devices.asStateFlow()

    private val _activeDeviceID = MutableStateFlow("")
    val activeDeviceID: StateFlow<String> = _activeDeviceID.asStateFlow()

    val activeDevice: ManagedDevice?
        get() = _devices.value.firstOrNull { it.id == _activeDeviceID.value }

    init {
        load()
        migrateIfNeeded()
    }

    // ─── CRUD ─────────────────────────────────────────────────────────────────

    fun addDevice(device: ManagedDevice) {
        _devices.value = _devices.value + device
        if (_devices.value.size == 1 || _activeDeviceID.value.isEmpty()) {
            _activeDeviceID.value = device.id
        }
        save()
    }

    fun updateDevice(device: ManagedDevice) {
        val idx = _devices.value.indexOfFirst { it.id == device.id }
        if (idx < 0) return
        val list = _devices.value.toMutableList()
        list[idx] = device
        _devices.value = list
        save()
    }

    /**
     * 改名/换 id（配对后设备 id 以桌面端身份为准）。
     *
     * 必须按**旧 id** 定位条目：[updateDevice] 按条目自身 id 查找，而改名后 id 已变，
     * 永远匹配不到（静默失败）——曾导致 token 存在新键、请求却按旧 id 取，
     * 配对成功后依然 401、循环提示"需要重新配对"。
     */
    fun renameDevice(oldId: String, renamed: ManagedDevice) {
        val idx = _devices.value.indexOfFirst { it.id == oldId }
        if (idx < 0) return
        val list = _devices.value.toMutableList()
        list[idx] = renamed
        _devices.value = list
        if (_activeDeviceID.value == oldId) {
            _activeDeviceID.value = renamed.id
        }
        save()
    }

    fun removeDevice(id: String) {
        _devices.value = _devices.value.filter { it.id != id }
        if (_activeDeviceID.value == id) {
            _activeDeviceID.value = _devices.value.firstOrNull()?.id ?: ""
        }
        save()
    }

    fun setActive(id: String) {
        if (_devices.value.none { it.id == id }) return
        _activeDeviceID.value = id
        prefs.edit().putString(KEY_ACTIVE, id).apply()
    }

    // ─── Persistence ─────────────────────────────────────────────────────────

    private fun save() {
        val arr = JSONArray()
        for (d in _devices.value) {
            arr.put(JSONObject().apply {
                put("id", d.id)
                put("name", d.name)
                put("host", d.host)
                put("port", d.port)
                put("osType", d.osType.name)
            })
        }
        prefs.edit()
            .putString(KEY_DEVICES, arr.toString())
            .putString(KEY_ACTIVE, _activeDeviceID.value)
            .apply()
    }

    private fun load() {
        val raw = prefs.getString(KEY_DEVICES, null)
        if (raw != null) {
            try {
                val arr = JSONArray(raw)
                val list = mutableListOf<ManagedDevice>()
                for (i in 0 until arr.length()) {
                    val obj = arr.getJSONObject(i)
                    list.add(
                        ManagedDevice(
                            id = obj.getString("id"),
                            name = obj.getString("name"),
                            host = obj.getString("host"),
                            port = obj.getString("port"),
                            osType = try {
                                DeviceOSType.valueOf(obj.getString("osType"))
                            } catch (_: Exception) {
                                DeviceOSType.Mac
                            },
                        )
                    )
                }
                _devices.value = list
            } catch (_: Exception) {
                _devices.value = emptyList()
            }
        }
        _activeDeviceID.value = prefs.getString(KEY_ACTIVE, "") ?: ""
        // 回退到第一个
        if (_activeDeviceID.value.isNotEmpty() &&
            _devices.value.none { it.id == _activeDeviceID.value }
        ) {
            _activeDeviceID.value = _devices.value.firstOrNull()?.id ?: ""
        }
    }

    /// 首次启动：把旧的单设备配置迁移过来（从 brewping_prefs 文件读取）。
    ///
    /// 迁移是**一次性动作**：完成后立即清掉旧配置键。否则用户删光设备后，
    /// 每次冷启动（设备列表为空）都会把旧配置重新注册成一台 Mac 设备 ——
    /// 看起来就像"删了的设备被自动复活"，且永远无法通过删除摆脱。
    private fun migrateIfNeeded() {
        if (_devices.value.isNotEmpty()) {
            // 已有设备（新版数据在用）：顺手清掉可能残留的旧配置，防日后复活
            clearLegacySingleDeviceConfig()
            return
        }
        val oldPrefs = context.getSharedPreferences("brewping_prefs", Context.MODE_PRIVATE)
        val host = oldPrefs.getString(KEY_OLD_MAC, null)
            ?: return
        val port = oldPrefs.getString(KEY_OLD_PORT, "8787") ?: "8787"
        if (host.isNotEmpty()) {
            val name = if (host.endsWith(".local")) host.dropLast(6) else "Mac"
            addDevice(ManagedDevice.new(name = name, host = host, port = port, osType = DeviceOSType.Mac))
        }
        clearLegacySingleDeviceConfig()
    }

    private fun clearLegacySingleDeviceConfig() {
        context.getSharedPreferences("brewping_prefs", Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_OLD_MAC)
            .remove(KEY_OLD_PORT)
            .apply()
    }

    companion object {
        private const val KEY_DEVICES = "BrewPing.Devices"
        private const val KEY_ACTIVE = "BrewPing.ActiveDeviceID"
        private const val KEY_OLD_MAC = "brewping.macAddress"
        private const val KEY_OLD_PORT = "brewping.port"
    }
}
