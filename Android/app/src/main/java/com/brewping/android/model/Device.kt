package com.brewping.android.model

/**
 * Represents a discovered BrewPing Desktop device on the local network.
 * Platform-agnostic — does not assume macOS, Windows, or Linux.
 */
data class DesktopDevice(
    val id: String,
    val name: String,
    val host: String,
    val ip: String,
    val port: Int,
    val serviceType: String = "_brewping._tcp",
    val platform: String = "unknown",
    val version: String = "",
    val status: DesktopStatus = DesktopStatus.Offline,
    val agentName: String = "",
    val agentStatus: String = "",
    val agents: List<AgentInfo> = emptyList(),
)

enum class DesktopStatus {
    Online,
    Offline,
    Connecting,
    Error,
}

/**
 * An AI agent available on the Desktop.
 */
data class AgentInfo(
    val id: String,
    val name: String,
    val installed: Boolean = false,
    val active: Boolean = false,
    val version: String = "",
)
