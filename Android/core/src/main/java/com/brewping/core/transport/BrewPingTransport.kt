package com.brewping.core.transport

import com.brewping.core.model.ApprovalDecisionResponse
import com.brewping.core.model.CommandStatusResponse
import com.brewping.core.model.ConversationResult
import com.brewping.core.model.ConversationsResult
import com.brewping.core.model.DesktopDevice
import com.brewping.core.model.PendingApprovalInfo
import com.brewping.core.model.StatusResponse
import com.brewping.core.model.SubmitResponse

/**
 * 桌面端通信抽象：UI / Repository 只认这个接口，不碰 OkHttp / JSON。
 *
 * 依赖方向（v1 与未来一致）：
 * ```
 * UI → ViewModel / Repository → BrewPingTransport → DesktopApiClient → HTTP
 * ```
 *
 * v1 只实现 [DirectHttpTransport]（手表直连桌面）。
 * `PhoneRelayTransport`（手表 → 手机 Data Layer → 桌面）是预留的 v2 方向：
 * 届时新增一个实现类即可，上层代码不动。**本次不实现中继链路。**
 */
interface BrewPingTransport {

    /** `GET /api/status` —— 只读健康检查（公开端点）。 */
    suspend fun status(device: DesktopDevice): StatusResponse?

    /** `GET /api/conversations?includeArchived=1`。 */
    suspend fun conversations(device: DesktopDevice): ConversationsResult?

    /** `GET /api/conversations/{id}`。 */
    suspend fun conversation(device: DesktopDevice, id: String): ConversationResult?

    /**
     * `POST /api/message`。
     *
     * [clientCommandId] 是**幂等键**（客户端生成，如 UUID）：网络超时后重试时带同一个值，
     * 桌面端按它去重，保证同一条指令不会执行两次。它与服务端的
     * `X-BrewPing-Nonce`（传输层防重放）语义完全不同 —— nonce 每次请求都变，
     * 绝不当业务幂等键用。
     */
    suspend fun submit(
        device: DesktopDevice,
        text: String,
        conversationId: String?,
        clientCommandId: String?,
    ): SubmitResponse?

    /** `GET /api/message/{commandId}` —— 含服务端权威执行阶段（`run` 字段）。 */
    suspend fun commandStatus(device: DesktopDevice, commandId: String): CommandStatusResponse?

    /** `GET /api/approvals` —— 挂起命令列表。 */
    suspend fun approvals(device: DesktopDevice): List<PendingApprovalInfo>?

    /** `POST /api/approvals/{id}` —— `action` = approve / deny / always_approve。 */
    suspend fun decideApproval(
        device: DesktopDevice,
        approvalId: String,
        action: String,
    ): ApprovalDecisionResponse?
}
