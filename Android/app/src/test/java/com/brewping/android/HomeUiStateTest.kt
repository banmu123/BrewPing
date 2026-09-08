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
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HomeUiStateTest {

    @Test
    fun `desktop device model has all required fields`() {
        val device = createTestDevice()
        assertEquals("bp_mac_test123", device.id)
        assertEquals("MacBook Pro", device.name)
        assertEquals("192.168.1.23", device.ip)
        assertEquals(8787, device.port)
        assertEquals(DesktopStatus.Online, device.status)
        assertEquals("OpenClaw", device.agentName)
    }

    @Test
    fun `agent entry model works correctly`() {
        val agent = AgentEntry(
            id = "opencode",
            name = "OpenCode",
            installed = true,
            active = true,
            executable = true,
            version = "1.0.0",
        )
        assertEquals("opencode", agent.id)
        assertTrue(agent.installed)
        assertTrue(agent.active)
        assertTrue(agent.executable)
    }

    @Test
    fun `session state enum has expected values`() {
        val values = SessionState.entries
        assertTrue(values.contains(SessionState.Offline))
        assertTrue(values.contains(SessionState.Starting))
        assertTrue(values.contains(SessionState.Running))
        assertTrue(values.contains(SessionState.Stopping))
    }

    @Test
    fun `command phase inFlight is true for active states`() {
        assertFalse(CommandPhase.Idle.isInFlight)
        assertTrue(CommandPhase.Sending.isInFlight)
        assertTrue(CommandPhase.Delivered.isInFlight)
        assertTrue(CommandPhase.Working.isInFlight)
        assertFalse(CommandPhase.Completed("ok").isInFlight)
        assertFalse(CommandPhase.Failed("err").isInFlight)
    }

    @Test
    fun `command phase completed carries response`() {
        val phase = CommandPhase.Completed(
            response = "Hello from agent",
            duration = 3.2,
            modelId = "claude-3",
        )
        assertEquals("Hello from agent", phase.response)
        assertEquals(3.2, phase.duration!!, 0.01)
        assertEquals("claude-3", phase.modelId)
    }

    @Test
    fun `command phase failed carries failure reason`() {
        val phase = CommandPhase.Failed(
            error = "Rate limited",
            duration = 1.5,
            failureReason = "rate_limited",
        )
        assertEquals("Rate limited", phase.error)
        assertEquals("rate_limited", phase.failureReason)
    }

    @Test
    fun `connection state enum has expected values`() {
        val values = ConnectionState.entries
        assertTrue(values.contains(ConnectionState.Idle))
        assertTrue(values.contains(ConnectionState.Searching))
        assertTrue(values.contains(ConnectionState.Connected))
        assertTrue(values.contains(ConnectionState.Disconnected))
    }

    @Test
    fun `desktop device with multiple agents`() {
        val agents = listOf(
            AgentEntry("opencode", "OpenCode", installed = true, active = true, executable = true),
            AgentEntry("claude-code", "Claude Code", installed = true, active = false, executable = true),
        )
        val device = createTestDevice().copy(agents = agents)
        assertEquals(2, device.agents.size)
        assertTrue(device.agents[0].active)
        assertFalse(device.agents[1].active)
    }

    // ─── ManagedDevice tests (matches iOS ManagedDevice) ─────────────────────

    @Test
    fun `managed device creates with correct defaults`() {
        val device = ManagedDevice.new(name = "Chenzk", host = "192.168.1.10", port = "8787")
        assertEquals("Chenzk", device.name)
        assertEquals("192.168.1.10", device.host)
        assertEquals("8787", device.port)
        assertEquals(DeviceOSType.Mac, device.osType)
        assertEquals(8, device.id.length)
    }

    @Test
    fun `managed device displayName includes os label`() {
        val mac = ManagedDevice.new(name = "Pro", host = "10.0.0.1", osType = DeviceOSType.Mac)
        assertEquals("Mac Pro", mac.displayName)

        val win = ManagedDevice.new(name = "PC", host = "10.0.0.2", osType = DeviceOSType.Windows)
        assertEquals("Win PC", win.displayName)

        val linux = ManagedDevice.new(name = "Server", host = "10.0.0.3", osType = DeviceOSType.Linux)
        assertEquals("Linux Server", linux.displayName)
    }

    @Test
    fun `managed device baseUrl returns correct URL`() {
        val device = ManagedDevice.new(host = "192.168.1.10", port = "9090")
        assertEquals("http://192.168.1.10:9090", device.baseUrl())
    }

    @Test
    fun `managed device baseUrl returns null for empty host`() {
        val device = ManagedDevice.new(host = "", port = "8787")
        assertNull(device.baseUrl())
    }

    @Test
    fun `device os type from raw`() {
        assertEquals(DeviceOSType.Mac, DeviceOSType.fromRaw("mac"))
        assertEquals(DeviceOSType.Mac, DeviceOSType.fromRaw("macOS"))
        assertEquals(DeviceOSType.Windows, DeviceOSType.fromRaw("windows"))
        assertEquals(DeviceOSType.Linux, DeviceOSType.fromRaw("linux"))
        assertEquals(DeviceOSType.Mac, DeviceOSType.fromRaw("unknown"))
    }

    private fun createTestDevice() = DesktopDevice(
        id = "bp_mac_test123",
        name = "MacBook Pro",
        host = "MacBook-Pro.local",
        ip = "192.168.1.23",
        port = 8787,
        platform = "macOS",
        version = "0.1",
        status = DesktopStatus.Online,
        agentName = "OpenClaw",
        agentStatus = "running",
    )
}
