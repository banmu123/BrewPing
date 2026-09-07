package com.brewping.android

import com.brewping.android.model.AgentEntry
import com.brewping.android.model.CommandPhase
import com.brewping.android.model.DesktopDevice
import com.brewping.android.model.DesktopStatus
import com.brewping.android.model.SessionState
import com.brewping.android.repository.ConnectionState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
