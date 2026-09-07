package com.brewping.android.model

/**
 * Represents a discovered BrewPing Desktop device on the local network.
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
    val agents: List<AgentEntry> = emptyList(),
)

enum class DesktopStatus {
    Online,
    Offline,
    Connecting,
    Error,
}

/**
 * An AI agent available on the Desktop (matches iOS AgentEntry).
 */
data class AgentEntry(
    val id: String,
    val name: String,
    val installed: Boolean = false,
    val active: Boolean = false,
    val executable: Boolean = false,
    val version: String = "",
)

// ─── Session & Command state (matches iOS) ───────────────────────────────────

enum class SessionState {
    Offline,
    Starting,
    Running,
    Stopping,
}

sealed interface CommandPhase {
    data object Idle : CommandPhase
    data object Sending : CommandPhase
    data object Delivered : CommandPhase
    data object Working : CommandPhase
    data class Completed(val response: String, val duration: Double? = null, val modelId: String? = null) : CommandPhase
    data class CompletedRaw(val rawOutput: String, val duration: Double? = null, val modelId: String? = null) : CommandPhase
    data class Failed(val error: String, val duration: Double? = null, val failureReason: String? = null, val modelId: String? = null) : CommandPhase

    val isInFlight: Boolean
        get() = this is Sending || this is Delivered || this is Working
}

// ─── API Response models ─────────────────────────────────────────────────────

data class StatusResponse(
    val status: String = "",
    val host: String = "",
    val defaultAgent: String = "",
    val session: SessionBrief? = null,
)

data class SessionBrief(
    val id: String = "",
    val agent: String = "",
    val agentName: String = "",
    val status: String = "",
)

data class AgentsResponse(
    val agents: List<AgentEntry> = emptyList(),
    val defaultAgent: String = "",
)

data class SubmitResponse(
    val success: Boolean = false,
    val commandId: String = "",
    val sessionId: String = "",
    val error: String = "",
)

data class CommandStatusResponse(
    val commandId: String = "",
    val status: String = "",
    val response: String = "",
    val rawOutput: String = "",
    val error: String = "",
    val failureReason: String = "",
    val modelId: String = "",
    val duration: Double? = null,
)

data class LifecycleResponse(
    val success: Boolean = false,
    val sessionId: String = "",
    val status: String = "",
    val error: String = "",
)
