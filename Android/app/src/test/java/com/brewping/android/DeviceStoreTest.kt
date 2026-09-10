package com.brewping.android

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import com.brewping.android.model.DeviceOSType
import com.brewping.android.model.ManagedDevice
import com.brewping.android.store.DeviceStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 多设备存储单元测试：CRUD、持久化往返、旧配置迁移与脏数据容错。
 * 使用内存版 SharedPreferences 替身，不依赖 Robolectric。
 */
class DeviceStoreTest {

    // ─── CRUD ─────────────────────────────────────────────────────────────────

    // TC-DS-01  首个设备自动成为活动设备
    @Test
    fun `first device becomes active automatically`() {
        val store = DeviceStore(FakeContext())
        val a = ManagedDevice.new(name = "A", host = "10.0.0.1")

        store.addDevice(a)

        assertEquals(1, store.devices.value.size)
        assertEquals(a.id, store.activeDeviceID.value)
        assertEquals(a.id, store.activeDevice?.id)
    }

    // TC-DS-02  追加设备不得抢占已有活动设备
    @Test
    fun `adding more devices keeps current active device`() {
        val store = DeviceStore(FakeContext())
        val a = ManagedDevice.new(name = "A", host = "10.0.0.1")
        val b = ManagedDevice.new(name = "B", host = "10.0.0.2")

        store.addDevice(a)
        store.addDevice(b)

        assertEquals(2, store.devices.value.size)
        assertEquals(a.id, store.activeDeviceID.value)
    }

    // TC-DS-03  边界：切换到不存在的设备必须被拒绝
    @Test
    fun `setActive ignores unknown device id`() {
        val store = DeviceStore(FakeContext())
        val a = ManagedDevice.new(name = "A", host = "10.0.0.1")
        store.addDevice(a)

        store.setActive("does-not-exist")

        assertEquals(a.id, store.activeDeviceID.value)
    }

    // TC-DS-04  边界：删除活动设备后自动回退到剩余的第一个
    @Test
    fun `removing active device falls back to first remaining`() {
        val store = DeviceStore(FakeContext())
        val a = ManagedDevice.new(name = "A", host = "10.0.0.1")
        val b = ManagedDevice.new(name = "B", host = "10.0.0.2")
        store.addDevice(a)
        store.addDevice(b)

        store.removeDevice(a.id)

        assertEquals(1, store.devices.value.size)
        assertEquals(b.id, store.activeDeviceID.value)
    }

    // TC-DS-05  边界：移除最后一个设备后活动 ID 清空
    @Test
    fun `removing last device clears active id`() {
        val store = DeviceStore(FakeContext())
        val a = ManagedDevice.new(name = "A", host = "10.0.0.1")
        store.addDevice(a)

        store.removeDevice(a.id)

        assertTrue(store.devices.value.isEmpty())
        assertEquals("", store.activeDeviceID.value)
        assertNull(store.activeDevice)
    }

    // TC-DS-06  边界：更新不存在的设备不得产生副作用
    @Test
    fun `update unknown device is a no-op`() {
        val store = DeviceStore(FakeContext())
        val a = ManagedDevice.new(name = "A", host = "10.0.0.1")
        store.addDevice(a)

        store.updateDevice(ManagedDevice.new(name = "Ghost", host = "9.9.9.9"))

        assertEquals(1, store.devices.value.size)
        assertEquals("A", store.devices.value[0].name)
    }

    // TC-DS-07  更新已有设备按 id 原地替换
    @Test
    fun `update existing device replaces in place`() {
        val store = DeviceStore(FakeContext())
        val a = ManagedDevice.new(name = "A", host = "10.0.0.1", port = "8787")
        store.addDevice(a)

        store.updateDevice(a.copy(name = "A2", host = "10.0.0.99", port = "9000", osType = DeviceOSType.Windows))

        assertEquals(1, store.devices.value.size)
        assertEquals("A2", store.devices.value[0].name)
        assertEquals("10.0.0.99", store.devices.value[0].host)
        assertEquals(DeviceOSType.Windows, store.devices.value[0].osType)
    }

    // ─── 持久化 ───────────────────────────────────────────────────────────────

    // TC-DS-08  持久化往返：重建实例后设备与活动 ID 必须还原
    @Test
    fun `devices survive a store recreation`() {
        val context = FakeContext()
        val a = ManagedDevice.new(name = "A", host = "10.0.0.1", port = "8787")
        val b = ManagedDevice.new(name = "B", host = "10.0.0.2", port = "9000", osType = DeviceOSType.Linux)
        run {
            val store = DeviceStore(context)
            store.addDevice(a)
            store.addDevice(b)
            store.setActive(b.id)
        }

        val reloaded = DeviceStore(context)

        assertEquals(2, reloaded.devices.value.size)
        assertEquals(b.id, reloaded.activeDeviceID.value)
        val restored = reloaded.devices.value.first { it.id == b.id }
        assertEquals("B", restored.name)
        assertEquals("9000", restored.port)
        assertEquals(DeviceOSType.Linux, restored.osType)
    }

    // TC-DS-09  边界：设备数据为非法 JSON 时必须降级为空列表且不崩溃
    @Test
    fun `corrupted device payload degrades to empty list`() {
        val context = FakeContext()
        context.getSharedPreferences("brewping_devices", 0)
            .edit()
            .putString("BrewPing.Devices", "{not-a-json-array")
            .putString("BrewPing.ActiveDeviceID", "phantom")
            .apply()

        val store = DeviceStore(context)

        assertTrue(store.devices.value.isEmpty())
        assertEquals("", store.activeDeviceID.value)
    }

    // TC-DS-10  边界：活动 ID 指向已不存在的设备时应回退到第一个
    @Test
    fun `stale active id falls back to first device`() {
        val context = FakeContext()
        context.getSharedPreferences("brewping_devices", 0)
            .edit()
            .putString(
                "BrewPing.Devices",
                """[{"id":"aaaaaaaa","name":"Kept","host":"1.2.3.4","port":"8787","osType":"Mac"}]"""
            )
            .putString("BrewPing.ActiveDeviceID", "zzzzzzzz")
            .apply()

        val store = DeviceStore(context)

        assertEquals(1, store.devices.value.size)
        assertEquals("aaaaaaaa", store.activeDeviceID.value)
    }

    // TC-DS-11  边界：osType 为未知字符串时回退到 Mac，不抛异常
    @Test
    fun `unknown os type in payload falls back to mac`() {
        val context = FakeContext()
        context.getSharedPreferences("brewping_devices", 0)
            .edit()
            .putString(
                "BrewPing.Devices",
                """[{"id":"bbbbbbbb","name":"X","host":"1.2.3.4","port":"8787","osType":"Haiku"}]"""
            )
            .apply()

        val store = DeviceStore(context)

        assertEquals(DeviceOSType.Mac, store.devices.value[0].osType)
    }

    // TC-DS-12  旧配置迁移：brewping_prefs 存在时自动导入为 Mac 设备
    @Test
    fun `legacy single-device prefs are migrated`() {
        val context = FakeContext()
        context.getSharedPreferences("brewping_prefs", 0)
            .edit()
            .putString("brewping.macAddress", "Chenzk-Mac.local")
            .putString("brewping.port", "9000")
            .apply()

        val store = DeviceStore(context)

        assertEquals(1, store.devices.value.size)
        val migrated = store.devices.value[0]
        assertEquals("Chenzk-Mac", migrated.name)
        assertEquals("Chenzk-Mac.local", migrated.host)
        assertEquals("9000", migrated.port)
        assertEquals(DeviceOSType.Mac, migrated.osType)
        assertEquals("http://Chenzk-Mac.local:9000", migrated.baseUrl())
    }

    // TC-DS-13  边界：已有设备时不得重复执行旧配置迁移
    @Test
    fun `migration is skipped when devices already exist`() {
        val context = FakeContext()
        context.getSharedPreferences("brewping_devices", 0)
            .edit()
            .putString(
                "BrewPing.Devices",
                """[{"id":"cccccccc","name":"Existing","host":"10.0.0.1","port":"8787","osType":"Mac"}]"""
            )
            .apply()
        context.getSharedPreferences("brewping_prefs", 0)
            .edit()
            .putString("brewping.macAddress", "Legacy.local")
            .apply()

        val store = DeviceStore(context)

        assertEquals(1, store.devices.value.size)
        assertEquals("Existing", store.devices.value[0].name)
    }
}

// ─── 测试替身 ─────────────────────────────────────────────────────────────────

/** 内存版 Context：只实现 SharedPreferences 获取。 */
private class FakeContext : ContextWrapper(null) {
    private val prefsMap = mutableMapOf<String, SharedPreferences>()

    override fun getSharedPreferences(name: String?, mode: Int): SharedPreferences =
        prefsMap.getOrPut(name ?: "default") { InMemoryPrefs() }
}

/** 删除标记（内部类中不允许声明伴生对象，故提升到文件级）。 */
private val REMOVED = Any()

private class InMemoryPrefs : SharedPreferences {
    private val values = mutableMapOf<String, Any?>()

    override fun getAll(): MutableMap<String, *> = values.toMutableMap()

    override fun getString(key: String?, defValue: String?): String? = values[key] as? String ?: defValue

    @Suppress("UNCHECKED_CAST")
    override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? =
        (values[key] as? MutableSet<String>) ?: defValues

    override fun getInt(key: String?, defValue: Int): Int = values[key] as? Int ?: defValue

    override fun getLong(key: String?, defValue: Long): Long = values[key] as? Long ?: defValue

    override fun getFloat(key: String?, defValue: Float): Float = values[key] as? Float ?: defValue

    override fun getBoolean(key: String?, defValue: Boolean): Boolean = values[key] as? Boolean ?: defValue

    override fun contains(key: String?): Boolean = values.containsKey(key)

    override fun edit(): SharedPreferences.Editor = Editor()

    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit

    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit

    inner class Editor : SharedPreferences.Editor {
        private val pending = mutableMapOf<String, Any?>()
        private var clearRequested = false

        override fun putString(key: String?, value: String?): SharedPreferences.Editor = apply { pending[key!!] = value }

        override fun putStringSet(key: String?, values: MutableSet<String>?): SharedPreferences.Editor =
            apply { pending[key!!] = values }

        override fun putInt(key: String?, value: Int): SharedPreferences.Editor = apply { pending[key!!] = value }

        override fun putLong(key: String?, value: Long): SharedPreferences.Editor = apply { pending[key!!] = value }

        override fun putFloat(key: String?, value: Float): SharedPreferences.Editor = apply { pending[key!!] = value }

        override fun putBoolean(key: String?, value: Boolean): SharedPreferences.Editor = apply { pending[key!!] = value }

        override fun remove(key: String?): SharedPreferences.Editor = apply { pending[key!!] = REMOVED }

        override fun clear(): SharedPreferences.Editor = apply { clearRequested = true }

        override fun commit(): Boolean {
            if (clearRequested) values.clear()
            for ((k, v) in pending) {
                if (v === REMOVED) values.remove(k) else values[k] = v
            }
            pending.clear()
            clearRequested = false
            return true
        }

        override fun apply() {
            commit()
        }
    }
}
