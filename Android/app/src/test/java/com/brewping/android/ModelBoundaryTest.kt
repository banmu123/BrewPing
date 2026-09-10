package com.brewping.android

import com.brewping.android.model.AgentEntry
import com.brewping.android.model.CommandPhase
import com.brewping.android.model.DesktopDevice
import com.brewping.android.model.DesktopStatus
import com.brewping.android.model.DeviceOSType
import com.brewping.android.model.ManagedDevice
import com.brewping.android.model.SessionState
import com.brewping.android.repository.ConnectionState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 模型层边界与契约测试（补充 HomeUiStateTest 未覆盖的边界场景）。
 */
class ModelBoundaryTest {

    // ─── ManagedDevice ────────────────────────────────────────────────────────

    // TC-MD-01  默认端口为 8787
    @Test
    fun `managed device default port is 8787`() {
        val device = ManagedDevice.new(name = "Pro", host = "10.0.0.1")
        assertEquals("8787", device.port)
    }

    // TC-MD-02  边界：端口为空串时 baseUrl 必须为 null（避免生成 http://host:）
    @Test
    fun `baseUrl is null when port is blank`() {
        assertNull(ManagedDevice.new(host = "10.0.0.1", port = "").baseUrl())
        assertNull(ManagedDevice.new(host = "10.0.0.1", port = "   ").baseUrl())
    }

    // TC-MD-03  边界：host 两侧空白必须被裁剪
    @Test
    fun `baseUrl trims surrounding whitespace`() {
        val device = ManagedDevice.new(host = "  192.168.1.10  ", port = " 8787 ")
        assertEquals("http://192.168.1.10:8787", device.baseUrl())
    }

    // TC-MD-04  id 为 8 位且全局唯一
    @Test
    fun `managed device ids are 8 chars and unique`() {
        val ids = (1..200).map { ManagedDevice.new().id }
        assertTrue(ids.all { it.length == 8 })
        assertEquals(200, ids.toSet().size)
    }

    // TC-MD-05  displayName 组合 OS 标签与名称
    @Test
    fun `displayName concatenates os label and name`() {
        assertEquals("Win MyPC", ManagedDevice.new(name = "MyPC", osType = DeviceOSType.Windows).displayName)
        assertEquals("Mac ", ManagedDevice.new(name = "").displayName)
    }

    // ─── DeviceOSType ─────────────────────────────────────────────────────────

    // TC-OS-01  fromRaw 大小写不敏感
    @Test
    fun `device os type from raw is case insensitive`() {
        assertEquals(DeviceOSType.Mac, DeviceOSType.fromRaw("MAC"))
        assertEquals(DeviceOSType.Mac, DeviceOSType.fromRaw("MacOS"))
        assertEquals(DeviceOSType.Windows, DeviceOSType.fromRaw("WINDOWS"))
        assertEquals(DeviceOSType.Linux, DeviceOSType.fromRaw("LINUX"))
    }

    // TC-OS-02  边界：未知 / 空串回退到 Mac
    @Test
    fun `device os type falls back to mac for unknown values`() {
        assertEquals(DeviceOSType.Mac, DeviceOSType.fromRaw(""))
        assertEquals(DeviceOSType.Mac, DeviceOSType.fromRaw("freebsd"))
        assertEquals(DeviceOSType.Mac, DeviceOSType.fromRaw("darwin"))
    }

    // ─── DesktopDevice / AgentEntry ───────────────────────────────────────────

    // TC-DD-01  默认值符合离线未连接语义
    @Test
    fun `desktop device defaults are offline with brewping service type`() {
        val device = DesktopDevice(id = "x", name = "n", host = "h", ip = "1.2.3.4", port = 8787)
        assertEquals("_brewping._tcp", device.serviceType)
        assertEquals(DesktopStatus.Offline, device.status)
        assertEquals("unknown", device.platform)
        assertTrue(device.agents.isEmpty())
    }

    // TC-AE-01  边界：AgentEntry 默认全部为 false / 空
    @Test
    fun `agent entry defaults are conservative`() {
        val agent = AgentEntry(id = "opencode", name = "OpenCode")
        assertFalse(agent.installed)
        assertFalse(agent.active)
        assertFalse(agent.executable)
        assertEquals("", agent.version)
    }

    // ─── CommandPhase ─────────────────────────────────────────────────────────

    // TC-CP-01  所有终态都不属于 in-flight
    @Test
    fun `terminal command phases are not in flight`() {
        assertFalse(CommandPhase.Idle.isInFlight)
        assertFalse(CommandPhase.Completed("ok").isInFlight)
        assertFalse(CommandPhase.CompletedRaw("raw").isInFlight)
        assertFalse(CommandPhase.Failed("err").isInFlight)
    }

    // TC-CP-02  边界：Completed 的 duration/modelId 缺省为 null
    @Test
    fun `completed phase optional fields default to null`() {
        val phase = CommandPhase.Completed(response = "ok")
        assertNull(phase.duration)
        assertNull(phase.modelId)
    }

    // TC-CP-03  边界：Failed 可同时缺少 duration / failureReason / modelId
    @Test
    fun `failed phase optional fields default to null`() {
        val phase = CommandPhase.Failed(error = "boom")
        assertNull(phase.duration)
        assertNull(phase.failureReason)
        assertNull(phase.modelId)
    }

    // ─── 枚举完整性 ───────────────────────────────────────────────────────────

    // TC-EN-01  会话状态与连接状态枚举必须覆盖 UI 全部分支
    @Test
    fun `session and connection enums expose all ui states`() {
        assertEquals(4, SessionState.entries.size)
        assertTrue(SessionState.entries.containsAll(listOf(SessionState.Offline, SessionState.Starting, SessionState.Running, SessionState.Stopping)))

        // UI 的 when 分支需要 Error 分支存在，否则连接异常无法展示
        assertTrue(ConnectionState.entries.contains(ConnectionState.Error))
        assertEquals(6, ConnectionState.entries.size)
    }
}
