package com.brewping.core.transport

import com.brewping.core.api.DesktopApiClient
import com.brewping.core.model.ApprovalDecisionResponse
import com.brewping.core.model.CommandStatusResponse
import com.brewping.core.model.ConversationResult
import com.brewping.core.model.ConversationsResult
import com.brewping.core.model.DesktopDevice
import com.brewping.core.model.PendingApprovalInfo
import com.brewping.core.model.StatusResponse
import com.brewping.core.model.SubmitResponse

/**
 * 直连实现：手表 / 手机 → 局域网明文 HTTP → 桌面端。
 *
 * 🚨 这是**唯一的** HTTP 出口包装 —— 鉴权（Bearer + Timestamp + Nonce）、
 * 超时、错误分类全部在 [DesktopApiClient] 内统一处理，两端共用，禁止再复制一份。
 */
class DirectHttpTransport(private val api: DesktopApiClient) : BrewPingTransport {

    override suspend fun status(device: DesktopDevice): StatusResponse? =
        api.fetchStatus(device)

    override suspend fun conversations(device: DesktopDevice): ConversationsResult? =
        api.fetchConversations(device)

    override suspend fun conversation(device: DesktopDevice, id: String): ConversationResult? =
        api.fetchConversation(device, id)

    override suspend fun submit(
        device: DesktopDevice,
        text: String,
        conversationId: String?,
        clientCommandId: String?,
    ): SubmitResponse? = api.submitMessage(device, text, conversationId, clientCommandId)

    override suspend fun commandStatus(device: DesktopDevice, commandId: String): CommandStatusResponse? =
        api.pollCommandStatus(device, commandId)

    override suspend fun approvals(device: DesktopDevice): List<PendingApprovalInfo>? =
        api.fetchApprovals(device)

    override suspend fun decideApproval(
        device: DesktopDevice,
        approvalId: String,
        action: String,
    ): ApprovalDecisionResponse? = api.decideApproval(device, approvalId, action)
}
