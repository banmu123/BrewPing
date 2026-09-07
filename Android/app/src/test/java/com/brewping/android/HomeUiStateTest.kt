package com.brewping.android

import com.brewping.android.model.AgentInfo
import com.brewping.android.model.DesktopDevice
import com.brewping.android.model.DesktopStatus
import com.brewping.android.repository.ConnectionState
import com.brewping.android.ui.HomeUiState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HomeUiStateTest {

    @Test
    fun `idle state maps correctly`() {
        val state = HomeUiState.Idle
        assertTrue(state is HomeUiState.Idle)
    }

    @Test
    fun `searching state maps correctly`() {
        val state = HomeUiState.Searching
        assertTrue(state is HomeUiState.Searching)
    }

    @Test
    fun `connected state carries device`() {
        val device = createTestDevice()
        val state = HomeUiState.Connected(device)
        assertEquals(device, state.device)
        assertEquals("MacBook Pro", state.device.name)
        assertEquals("192.168.1.23", state.device.ip)
    }

    @Test
    fun `disconnected state carries optional device`() {
        val stateWithDevice = HomeUiState.Disconnected(createTestDevice())
        assertNotNull(stateWithDevice.device)

        val stateWithoutDevice = HomeUiState.Disconnected(null)
        assertEquals(null, stateWithoutDevice.device)
    }

    @Test
    fun `error state carries message`() {
        val state = HomeUiState.Error("Network error")
        assertEquals("Network error", state.message)
    }

    @Test
    fun `connection state enum has expected values`() {
        val values = ConnectionState.entries
        assertTrue(values.contains(ConnectionState.Idle))
        assertTrue(values.contains(ConnectionState.Searching))
        assertTrue(values.contains(ConnectionState.Connecting))
        assertTrue(values.contains(ConnectionState.Connected))
        assertTrue(values.contains(ConnectionState.Disconnected))
        assertTrue(values.contains(ConnectionState.Error))
    }

    @Test
    fun `desktop device model has all required fields`() {
        val device = createTestDevice()
        assertEquals("bp_mac_test123", device.id)
        assertEquals("MacBook Pro", device.name)
        assertEquals("MacBook-Pro.local", device.host)
        assertEquals("192.168.1.23", device.ip)
        assertEquals(8787, device.port)
        assertEquals("_brewping._tcp", device.serviceType)
        assertEquals("macOS", device.platform)
        assertEquals("0.1", device.version)
        assertEquals(DesktopStatus.Online, device.status)
        assertEquals("OpenClaw", device.agentName)
        assertEquals("running", device.agentStatus)
    }

    @Test
    fun `agent info model works correctly`() {
        val agent = AgentInfo(
            id = "opencode",
            name = "OpenCode",
            installed = true,
            active = true,
            version = "1.0.0",
        )
        assertEquals("opencode", agent.id)
        assertEquals("OpenCode", agent.name)
        assertTrue(agent.installed)
        assertTrue(agent.active)
        assertEquals("1.0.0", agent.version)
    }

    @Test
    fun `desktop device with multiple agents`() {
        val agents = listOf(
            AgentInfo("opencode", "OpenCode", installed = true, active = true),
            AgentInfo("claude-code", "Claude Code", installed = true, active = false),
        )
        val device = createTestDevice().copy(agents = agents)
        assertEquals(2, device.agents.size)
        assertEquals("OpenCode", device.agents[0].name)
        assertTrue(device.agents[0].active)
    }

    private fun createTestDevice() = DesktopDevice(
        id = "bp_mac_test123",
        name = "MacBook Pro",
        host = "MacBook-Pro.local",
        ip = "192.168.1.23",
        port = 8787,
        serviceType = "_brewping._tcp",
        platform = "macOS",
        version = "0.1",
        status = DesktopStatus.Online,
        agentName = "OpenClaw",
        agentStatus = "running",
    )
}
