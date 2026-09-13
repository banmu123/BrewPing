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
    /** 桌面端授权门卫挂起（safe 命中危险 / askAll）：等待用户在手机上确认。 */
    data class PendingApproval(val approval: PendingApprovalInfo) : CommandPhase
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

/** 一条危险命中的机器可读标识 + 命中的原始片段（对齐 iOS ApprovalReasonInfo）。 */
data class ApprovalReasonInfo(
    val code: String = "",
    val detail: String = "",
)

/** 一条等待用户确认的命令（桌面端挂起，手机端弹窗；对齐 iOS PendingApprovalInfo）。 */
data class PendingApprovalInfo(
    val id: String = "",
    val text: String = "",
    val reasons: List<ApprovalReasonInfo> = emptyList(),
)

/** `POST /api/approvals/:id` 的响应（对齐 iOS ApprovalDecisionResponse）。 */
data class ApprovalDecisionResponse(
    val success: Boolean = false,
    val status: String = "",
    val commandId: String = "",
    val error: String = "",
)

data class SubmitResponse(
    val success: Boolean = false,
    val commandId: String = "",
    val sessionId: String = "",
    /** "queued" | "pending_approval" | …（桌面端 SubmitResponse.status）。 */
    val status: String = "",
    /** 非空 = 命中授权门卫，客户端弹确认（对齐 iOS SubmitResponse.approval）。 */
    val approval: PendingApprovalInfo? = null,
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
