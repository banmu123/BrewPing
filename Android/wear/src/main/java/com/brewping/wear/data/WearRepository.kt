package com.brewping.wear.data

import com.brewping.core.model.ApprovalDecisionResponse
import com.brewping.core.model.CommandRunStatus
import com.brewping.core.model.CommandStatusResponse
import com.brewping.core.model.ConversationResult
import com.brewping.core.model.ConversationsResult
import com.brewping.core.model.DesktopDevice
import com.brewping.core.model.PendingApprovalInfo
import com.brewping.core.model.StatusResponse
import com.brewping.core.model.SubmitResponse
import com.brewping.core.transport.BrewPingTransport
import java.util.UUID

/**
 * Wear v1 数据层：UI → [BrewPingTransport] → DesktopApiClient → HTTP。
 *
 * - 不直接依赖 OkHttp / JSON（统一在 :core 的 DesktopApiClient 内处理鉴权与解析）；
 * - **不做轮询** —— 轮询节奏由 ViewModel 结合生命周期控制（前台 5~10s，离开页面停止）；
 * - 发送指令自动带幂等键（客户端 UUID），网络超时重试不会重复执行。
 */
class WearRepository(private val transport: BrewPingTransport) {

    suspend fun status(device: DesktopDevice): StatusResponse? = transport.status(device)

    suspend fun conversations(device: DesktopDevice): ConversationsResult? =
        transport.conversations(device)

    suspend fun conversation(device: DesktopDevice, id: String): ConversationResult? =
        transport.conversation(device, id)

    suspend fun commandStatus(device: DesktopDevice, commandId: String): CommandStatusResponse? =
        transport.commandStatus(device, commandId)

    suspend fun approvals(device: DesktopDevice): List<PendingApprovalInfo>? =
        transport.approvals(device)

    suspend fun approve(device: DesktopDevice, approvalId: String): ApprovalDecisionResponse? =
        transport.decideApproval(device, approvalId, ACTION_APPROVE)

    suspend fun reject(device: DesktopDevice, approvalId: String): ApprovalDecisionResponse? =
        transport.decideApproval(device, approvalId, ACTION_DENY)

    /** 发送指令（自动生成幂等键；对齐手机端语义，永远显式携带 conversationId）。 */
    suspend fun send(
        device: DesktopDevice,
        text: String,
        conversationId: String,
    ): SubmitResponse? = transport.submit(device, text, conversationId, UUID.randomUUID().toString())

    companion object {
        const val ACTION_APPROVE = "approve"
        const val ACTION_DENY = "deny"
    }
}

/** 取最近一条未归档对话（Home 的「当前对话」判据：updatedAtMs 最新优先）。 */
fun List<com.brewping.core.model.ConversationSummary>?.mostRecentActive(): com.brewping.core.model.ConversationSummary? =
    orEmpty()
        .filter { !it.archived }
        .maxByOrNull { it.updatedAtMs }

/** 是否在飞（供 UI 决定是否继续轮询 run）。 */
fun CommandRunStatus?.isRunActive(): Boolean = this?.isActive == true
