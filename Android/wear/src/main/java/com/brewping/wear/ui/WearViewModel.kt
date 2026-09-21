package com.brewping.wear.ui

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.brewping.core.model.CommandRunStatus
import com.brewping.core.model.ConversationDetail
import com.brewping.core.model.ConversationSummary
import com.brewping.core.model.PendingApprovalInfo
import com.brewping.core.store.PairingStore
import com.brewping.wear.data.WearProvisionStore
import com.brewping.wear.data.WearRepository
import com.brewping.wear.data.mostRecentActive
import com.brewping.wear.pairing.ProvisionBus
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** 连接问题分类：UI 区分展示，绝不笼统显示 "Network error"（任务 §19）。 */
enum class ConnectionError { Offline, Auth, Server, Network }

data class WearUiState(
    /** 已下发的桌面端配置（null = 未配置 → 显示 Waiting for phone）。 */
    val provisioned: WearProvisionStore.Provisioned? = null,
    /** token 是否存在（配置了 host 但没有 token = 需要重新下发）。 */
    val paired: Boolean = false,
    val online: Boolean = false,
    val hostName: String = "",
    val conversations: List<ConversationSummary> = emptyList(),
    /** 最近一条在飞对话的服务端执行阶段（null = 没有在飞命令 / 老桌面端）。 */
    val activeRun: CommandRunStatus? = null,
    /** 该命令的最终输出尾部（completed / failed 时展示）。 */
    val lastOutput: String? = null,
    val approvals: List<PendingApprovalInfo> = emptyList(),
    val connectionError: ConnectionError? = null,
    /** 审批决定提交中：按钮 disabled（任务 §15 防抖 + 请求中禁用）。 */
    val decisionInFlight: Boolean = false,
    /** 已处理审批的 id 集合：重复点击不再提交（任务 §15）。 */
    val decidedIds: Set<String> = emptySet(),
    val decisionSent: Boolean = false,
    val sending: Boolean = false,
    val sendDone: Boolean = false,
    val sendError: String? = null,
    val detail: ConversationDetail? = null,
    val detailLoading: Boolean = false,
)

/**
 * Wear v1 状态容器。轮询策略（任务 §18）：
 *  - 进入页面 → 立即 refresh，前台 7s 适度轮询；
 *  - 离开页面（ON_STOP）→ [stopPolling]；
 *  - 恢复 → 立即 refresh；
 *  - 不创建任何常驻 Service。
 */
class WearViewModel(
    private val repository: WearRepository,
    private val provisionStore: WearProvisionStore,
    private val pairingStore: PairingStore,
) : ViewModel() {

    companion object {
        private const val TAG = "BrewPingWear"
        private const val POLL_INTERVAL_MS = 7_000L
        /** Home 上展示的输出尾部最大长度（手表小屏，只看结尾）。 */
        private const val LAST_OUTPUT_TAIL = 240
    }

    private val _state = MutableStateFlow(WearUiState())
    val state: StateFlow<WearUiState> = _state.asStateFlow()

    private var pollJob: Job? = null
    private var provisioningDeviceId: String? = null

    init {
        // 手机端重新下发配置 → 立即重建设备上下文并刷新
        viewModelScope.launch {
            ProvisionBus.events.collect {
                resetDeviceContext()
                refreshOnce()
                startPolling()
            }
        }
    }

    /** 手机端配置到达 / 变化后调用（ProvisionBus 之外，UI 首帧也会走）。 */
    fun resetDeviceContext() {
        val provisioned = provisionStore.provisioned
        provisioningDeviceId = provisioned?.deviceId
        val paired = provisioned != null && pairingStore.token(provisioned.deviceId) != null
        _state.update {
            it.copy(
                provisioned = provisioned,
                paired = paired,
                // 配置变化后一切连接态归零，等下一次 refresh 重建
                online = false,
                hostName = "",
                connectionError = null,
                conversations = emptyList(),
                approvals = emptyList(),
                activeRun = null,
                lastOutput = null,
            )
        }
    }

    fun startPolling() {
        if (pollJob?.isActive == true) return
        pollJob = viewModelScope.launch {
            while (isActive) {
                refreshOnce()
                delay(POLL_INTERVAL_MS)
            }
        }
    }

    fun stopPolling() {
        pollJob?.cancel()
        pollJob = null
    }

    fun refreshOnce() {
        viewModelScope.launch { refreshInternal() }
    }

    private suspend fun refreshInternal() {
        val device = _state.value.provisioned?.toDesktopDevice() ?: return
        val deviceId = device.id

        // token 丢失（清了数据 / 换机恢复）→ 需要重新下发，不算网络错误
        if (pairingStore.token(deviceId) == null) {
            _state.update { it.copy(paired = false, online = false, connectionError = ConnectionError.Auth) }
            return
        }
        _state.update { it.copy(paired = true) }

        // 1) 健康检查（公开端点，不带 token 也能测连通性）
        val status = runCatching { repository.status(device) }.getOrNull()
        if (status == null) {
            _state.update { it.copy(online = false, connectionError = ConnectionError.Network) }
            return
        }
        val online = status.status == "online"
        _state.update { it.copy(online = online, hostName = status.host) }

        // 2) 对话列表
        val conversationsResult = runCatching { repository.conversations(device) }.getOrNull()
        when {
            conversationsResult == null ->
                _state.update { it.copy(connectionError = ConnectionError.Network) }
            conversationsResult.unauthorized -> {
                _state.update { it.copy(connectionError = ConnectionError.Auth) }
                return
            }
            conversationsResult.error != null ->
                _state.update { it.copy(connectionError = ConnectionError.Server) }
            else -> _state.update { it.copy(connectionError = null) }
        }
        val conversations = conversationsResult?.conversations.orEmpty()
            .filter { !it.archived }
            .sortedByDescending { it.updatedAtMs }
        _state.update { it.copy(conversations = conversations) }

        // 3) 最近对话的服务端执行阶段 + 终态输出尾部（stalled 由桌面端权威判定）
        val latest = conversations.mostRecentActive()
        var run: CommandRunStatus? = null
        var outputTail: String? = null
        if (latest?.latestCommandId?.isNotEmpty() == true) {
            val commandStatus = runCatching {
                repository.commandStatus(device, latest.latestCommandId!!)
            }.getOrNull()
                if (commandStatus != null) {
                    run = commandStatus.run
                    if (run == null) {
                        // 老桌面端没有 run 字段 → 从旧 status 字符串近似映射（不猜 stalled）
                        run = legacyPhase(commandStatus.status)?.let { phase ->
                            CommandRunStatus(commandId = commandStatus.commandId, phase = phase)
                        }
                    }
                    if (run?.isTerminal == true) {
                        val text = commandStatus.response.ifEmpty { commandStatus.rawOutput }
                        if (text.isNotEmpty()) outputTail = text.takeLast(LAST_OUTPUT_TAIL)
                    }
                }
        }
        _state.update { it.copy(activeRun = run, lastOutput = outputTail) }

        // 4) 待审批列表
        val approvals = runCatching { repository.approvals(device) }.getOrNull()
        if (approvals != null) {
            _state.update { it.copy(approvals = approvals) }
        }
    }

    /**
     * 老桌面端（无 run 字段）的近似映射：只映射**服务端真实存在**的命令状态，
     * 绝不推断 stalled —— 那是桌面端的职责（任务 §13）。
     */
    private fun legacyPhase(status: String): String? = when (status) {
        "queued", "sent" -> CommandRunStatus.PHASE_QUEUED
        "working" -> CommandRunStatus.PHASE_THINKING
        "completed", "completed_with_raw" -> CommandRunStatus.PHASE_COMPLETED
        "failed" -> CommandRunStatus.PHASE_FAILED
        else -> null
    }

    /** 加载对话详情（转录；Conversation 页用）。 */
    fun loadConversation(id: String) {
        val device = _state.value.provisioned?.toDesktopDevice() ?: return
        viewModelScope.launch {
            _state.update { it.copy(detailLoading = true) }
            val result = runCatching { repository.conversation(device, id) }.getOrNull()
            val detail = when {
                result?.detail != null -> result.detail
                else -> {
                    Log.w(TAG, "loadConversation failed: ${result?.error}")
                    null
                }
            }
            _state.update { it.copy(detail = detail, detailLoading = false) }
        }
    }

    /** 审批决定：请求中禁用按钮 + 已处理的不再提交（幂等由桌面端兜底）。 */
    fun decide(approvalId: String, approve: Boolean) {
        val current = _state.value
        if (current.decisionInFlight || approvalId in current.decidedIds) return
        val device = current.provisioned?.toDesktopDevice() ?: return
        viewModelScope.launch {
            _state.update { it.copy(decisionInFlight = true, decisionSent = false) }
            val response = runCatching {
                if (approve) repository.approve(device, approvalId)
                else repository.reject(device, approvalId)
            }.getOrNull()
            _state.update {
                it.copy(
                    decisionInFlight = false,
                    // 桌面端 404（unknown or expired）也视为已处理：从列表移除即可
                    decidedIds = it.decidedIds + approvalId,
                    approvals = it.approvals.filterNot { a -> a.id == approvalId },
                    decisionSent = response != null,
                )
            }
            // 批准后命令立即执行 → 刷新 run 状态
            refreshOnce()
        }
    }

    /** 语音指令发送（自动带幂等键；失败可重试 —— 同一条文本重新走一遍即可）。 */
    fun sendVoice(text: String, conversationId: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        val device = _state.value.provisioned?.toDesktopDevice() ?: return
        viewModelScope.launch {
            _state.update { it.copy(sending = true, sendDone = false, sendError = null) }
            val response = runCatching { repository.send(device, trimmed, conversationId) }.getOrNull()
            _state.update {
                when {
                    response == null -> it.copy(sending = false, sendError = "network")
                    response.success -> it.copy(sending = false, sendDone = true)
                    else -> it.copy(sending = false, sendError = response.error.ifEmpty { "failed" })
                }
            }
            refreshOnce()
        }
    }

    /** 清一次性提示（UI 消费后调用）。 */
    fun clearTransient() {
        _state.update { it.copy(decisionSent = false, sendDone = false, sendError = null) }
    }
}
