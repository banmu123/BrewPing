package com.brewping.android.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.brewping.android.CommandReceiver
import com.brewping.android.model.AgentEntry
import com.brewping.android.model.CommandPhase
import com.brewping.android.model.DesktopDevice
import com.brewping.android.model.ManagedDevice
import com.brewping.android.model.SessionState
import com.brewping.android.repository.ConnectionState
import com.brewping.android.repository.DesktopRepository
import com.brewping.android.store.ConversationStore
import com.brewping.android.store.DeviceStore
import com.brewping.android.store.ModelStore
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** 对话导航目标（对齐 iOS ConversationRoute）：既有对话 / 新对话草稿。 */
sealed interface ConversationRoute {
    data class Existing(val id: String) : ConversationRoute
    data object Draft : ConversationRoute
}

class HomeViewModel(
    private val repository: DesktopRepository,
    private val deviceStore: DeviceStore,
    private val commandReceiver: CommandReceiver,
    val conversationStore: ConversationStore,
    val modelStore: ModelStore,
) : ViewModel() {

    // ─── Device store ─────────────────────────────────────────────────────────

    val devices: StateFlow<List<ManagedDevice>> = deviceStore.devices
    val activeDeviceID: StateFlow<String> = deviceStore.activeDeviceID

    // ─── Message ──────────────────────────────────────────────────────────────

    private val _messageText = MutableStateFlow("")
    val messageText: StateFlow<String> = _messageText.asStateFlow()

    // ─── Discovery ────────────────────────────────────────────────────────────

    private val _discoveryMessage = MutableStateFlow("")
    val discoveryMessage: StateFlow<String> = _discoveryMessage.asStateFlow()

    private val _discoveryRunning = MutableStateFlow(false)
    val discoveryRunning: StateFlow<Boolean> = _discoveryRunning.asStateFlow()

    // ─── Session detail (from /api/status, matches iOS) ─────────────────────────

    private val _sessionID = MutableStateFlow("")
    val sessionID: StateFlow<String> = _sessionID.asStateFlow()

    private val _sessionAgentID = MutableStateFlow("opencode")
    val sessionAgentID: StateFlow<String> = _sessionAgentID.asStateFlow()

    private val _sessionAgentName = MutableStateFlow("OpenCode")
    val sessionAgentName: StateFlow<String> = _sessionAgentName.asStateFlow()

    // ─── Delegated from Repository ────────────────────────────────────────────

    val connectionState: StateFlow<ConnectionState> = repository.connectionState
    val activeDevice: StateFlow<DesktopDevice?> = repository.activeDevice
    val online: StateFlow<Boolean> = repository.online
    val hostName: StateFlow<String> = repository.hostName
    val agents: StateFlow<List<AgentEntry>> = repository.agents
    val sessionState: StateFlow<SessionState> = repository.sessionState
    val sessionMessage: StateFlow<String> = repository.sessionMessage
    val lifecycleBusy: StateFlow<Boolean> = repository.lifecycleBusy
    val commandPhase: StateFlow<CommandPhase> = repository.commandPhase

    // ─── Conversation navigation & context（对齐 iOS 主页 = 对话列表）────────────

    /** 当前连接的桌面设备（对话页所有请求都用它；切设备时置空）。 */
    private val _desktopDevice = MutableStateFlow<DesktopDevice?>(null)
    val desktopDevice: StateFlow<DesktopDevice?> = _desktopDevice.asStateFlow()

    private val _conversationRoute = MutableStateFlow<ConversationRoute?>(null)
    val conversationRoute: StateFlow<ConversationRoute?> = _conversationRoute.asStateFlow()

    /** agentId → 显示名（复用已拉取的 /api/agents 结果，对齐 iOS agentNames）。 */
    val agentNames: Map<String, String>
        get() = repository.agents.value.associate { it.id to it.name }

    /** 草稿态兜底 Agent：桌面端默认 Agent（对齐 iOS fallbackAgentId）。 */
    val fallbackAgentId: String
        get() = repository.agents.value.firstOrNull { it.active }?.id
            ?: repository.statusResponse.value?.defaultAgent?.takeIf { it.isNotEmpty() }
            ?: "opencode"

    private var statusPollJob: Job? = null

    /** PairingStore / ApiClient 单例（BrewPingApp 提供，测试可替换）。 */
    private val appPairingStore get() = com.brewping.android.BrewPingApp.instance.pairingStore
    private val appPairingApi get() = com.brewping.android.BrewPingApp.instance.apiClient

    private fun ManagedDevice.toDesktopDevice(): DesktopDevice? {
        val ip = host.trim()
        if (ip.isEmpty()) return null
        val portNum = port.trim().toIntOrNull() ?: 8787
        return DesktopDevice(id = id, name = name, host = ip, ip = ip, port = portNum)
    }

    init {
        // App 启动即开始 NSD 扫描（局域网自动发现；发现结果经 discoveredDevices 流出）
        repository.startDiscovery()
    }

    // ─── Pairing（对齐 iOS 配对流程：码换 token，持久化于 PairingStore）──────────

    /** 配对状态版本号：配对成功 / 解除后 +1，驱动 UI 重组。 */
    private val _pairingVersion = MutableStateFlow(0)
    val pairingVersion: StateFlow<Int> = _pairingVersion.asStateFlow()

    fun isPaired(deviceId: String): Boolean = appPairingStore.isPaired(deviceId)

    /**
     * 用 6 位配对码（或扫码得到的 payload）配对当前设备。
     * 成功后保存 token、重连并拉取对话列表 —— 任务 1「收不到对话目录」即因此前
     * 无 token、`/api/conversations` 401 所致。
     */
    fun pairWithCode(
        device: ManagedDevice,
        code: String,
        onResult: (success: Boolean, message: String) -> Unit,
    ) {
        val desktop = device.toDesktopDevice() ?: run {
            onResult(false, "Invalid host or port")
            return
        }
        viewModelScope.launch {
            val result = appPairingApi.pairWithCode(desktop, code)
            if (result == null) {
                onResult(false, "Can't reach ${device.name}")
                return@launch
            }
            if (!result.success || result.token.isEmpty()) {
                onResult(false, result.error ?: "Invalid or expired pairing code")
                return@launch
            }
            // token 的归属键：优先用服务端返回的 deviceId（桌面端身份），
            // 回退到本地设备的 id（老桌面端可能不回 deviceId）。
            appPairingStore.saveToken(result.deviceId.ifEmpty { device.id }, result.token)
            if (result.deviceId.isNotEmpty() && result.deviceId != device.id) {
                // 设备身份以桌面端为准：更新本地 id，保证 token 键与设备一一对应
                val renamed = device.copy(id = result.deviceId)
                deviceStore.updateDevice(renamed)
                deviceStore.setActive(renamed.id)
            }
            _pairingVersion.value += 1
            // 配对成功 = 拿到 token：立即重连并拉对话列表（修「收不到对话目录」）
            val active = deviceStore.activeDevice
            if (active != null && active.host == device.host) {
                connectToDevice(active)
            }
            onResult(true, "Paired with ${result.deviceName.ifEmpty { device.name }}")
        }
    }

    /** 局域网发现到的设备（NSD `_brewping._tcp`），App 启动即开始扫描。 */
    val discoveredDevices: StateFlow<List<DesktopDevice>> = repository.discoveredDevices

    /** 把发现到的设备一键加入设备列表并激活（配对仍需 6 位码 / 扫码）。 */
    fun addDiscoveredDevice(device: DesktopDevice): ManagedDevice {
        val existing = deviceStore.devices.value.firstOrNull {
            it.host == device.ip && it.port == device.port.toString()
        }
        if (existing != null) {
            deviceStore.setActive(existing.id)
            return existing
        }
        val managed = ManagedDevice.new(
            name = device.name,
            host = device.ip,
            port = device.port.toString(),
            osType = com.brewping.android.model.DeviceOSType.fromRaw(device.platform),
        )
        deviceStore.addDevice(managed)
        deviceStore.setActive(managed.id)
        return managed
    }

    init {
        // Observe active device changes and re-connect
        viewModelScope.launch {
            deviceStore.activeDeviceID.collect { id ->
                resetState()
                val device = deviceStore.activeDevice
                if (device != null) {
                    connectToDevice(device)
                }
            }
        }

        // Observe status response to update session detail (matches iOS refreshStatus)
        viewModelScope.launch {
            repository.sessionBrief.collect { brief ->
                if (brief != null) {
                    _sessionID.value = brief.id
                    _sessionAgentID.value = brief.agent.ifEmpty { "opencode" }
                    _sessionAgentName.value = brief.agentName.ifEmpty { "OpenCode" }
                } else {
                    // Session ended (agent switch or stop) — reset session detail
                    _sessionID.value = ""
                    _sessionAgentID.value = "opencode"
                    _sessionAgentName.value = "OpenCode"
                }
            }
        }
    }

    // ─── Device management ────────────────────────────────────────────────────

    fun setActiveDevice(id: String) {
        deviceStore.setActive(id)
    }

    fun addDevice(device: ManagedDevice) {
        deviceStore.addDevice(device)
        // Auto-select the newly added device
        deviceStore.setActive(device.id)
    }

    fun updateDevice(device: ManagedDevice) {
        deviceStore.updateDevice(device)
    }

    fun removeDevice(id: String) {
        deviceStore.removeDevice(id)
    }

    // ─── User actions ─────────────────────────────────────────────────────────

    fun updateMessageText(value: String) {
        _messageText.value = value
    }

    /** "Auto" button — trigger Bonjour discovery for add/edit device sheet */
    fun autoDiscoverForSheet(onResult: (host: String, port: String, name: String, message: String) -> Unit) {
        _discoveryRunning.value = true

        viewModelScope.launch {
            repository.stopDiscovery()
            repository.startDiscovery()

            var attempts = 0
            while (attempts < 10) {
                delay(500)
                val device = repository.activeDevice.value
                if (device != null) {
                    val resolved = device.name
                    _discoveryRunning.value = false
                    onResult(
                        if (resolved.endsWith(".local")) resolved else "$resolved.local",
                        device.port.toString(),
                        resolved,
                        "Found: ${device.name}",
                    )
                    return@launch
                }
                attempts++
            }

            _discoveryRunning.value = false
            onResult("", "", "", "No BrewPing agent found")
        }
    }

    /** "Check" button — connect to the current active device */
    fun checkConnection() {
        val device = deviceStore.activeDevice ?: return
        connectToDevice(device)
    }

    /** "Set Default" agent */
    fun setDefaultAgent(agentId: String) {
        val device = currentDesktopDevice() ?: return
        viewModelScope.launch {
            repository.setDefaultAgent(device, agentId)
        }
    }

    /** Start session */
    fun startSession() {
        val device = currentDesktopDevice() ?: return
        viewModelScope.launch {
            repository.startSession(device)
        }
    }

    /** Stop session */
    fun stopSession() {
        val device = currentDesktopDevice() ?: return
        viewModelScope.launch {
            repository.stopSession(device)
        }
    }

    /** Send message */
    fun sendMessage() {
        val device = currentDesktopDevice() ?: return
        val text = _messageText.value.trim()
        if (text.isEmpty()) return
        _messageText.value = ""

        viewModelScope.launch {
            repository.submitMessage(device, text)
        }
    }

    /** Force server-side agent re-scan */
    fun refreshDiscovery() {
        val device = currentDesktopDevice() ?: return
        _discoveryRunning.value = true
        viewModelScope.launch {
            repository.refreshDiscovery(device)
            _discoveryRunning.value = false
        }
    }

    // ─── Conversation actions（对齐 iOS ConversationListView / DetailView）───────

    fun openConversation(id: String) {
        _conversationRoute.value = ConversationRoute.Existing(id)
    }

    fun openDraftConversation() {
        _conversationRoute.value = ConversationRoute.Draft
    }

    fun closeConversation() {
        _conversationRoute.value = null
    }

    fun refreshConversations() {
        val device = _desktopDevice.value ?: return
        viewModelScope.launch {
            conversationStore.refresh(device, force = true)
        }
    }

    /**
     * 在对话里发送消息。`conversationId == null`（草稿）时先物化成对话
     * （Agent / 授权档位随创建固化），再按新 id 提交 —— 不落到桌面端
     * 「当前激活对话」，避免把消息发进别的对话里（iOS 同款语义）。
     *
     * `onMaterialized` 回传物化后的对话 id；null = 物化失败（调用方回滚草稿）。
     */
    fun sendInConversation(
        conversationId: String?,
        text: String,
        draftAgentId: String?,
        draftApprovalMode: String?,
        onMaterialized: (String?) -> Unit,
    ) {
        val device = _desktopDevice.value ?: run { onMaterialized(null); return }
        val trimmed = text.trim()
        if (trimmed.isEmpty()) {
            onMaterialized(null)
            return
        }

        viewModelScope.launch {
            var targetId = conversationId
            if (targetId == null) {
                val agentId = draftAgentId ?: fallbackAgentId
                targetId = conversationStore.createConversation(
                    device = device,
                    agentId = agentId,
                    approvalMode = draftApprovalMode,
                )
                if (targetId == null) {
                    onMaterialized(null)
                    return@launch
                }
                onMaterialized(targetId)
            }
            repository.submitMessage(device, trimmed, targetId)
        }
    }

    /** 命令结束 / 设置变更后刷新：详情（agentId / 覆盖 / 档位）与列表。 */
    fun reloadConversation(conversationId: String?) {
        val device = _desktopDevice.value ?: return
        viewModelScope.launch {
            conversationId?.let { conversationStore.open(it, device) }
            conversationStore.refresh(device, force = true)
        }
    }

    /** 切换对话绑定的 Agent（桌面端自动清除该对话的模型覆盖）。 */
    fun switchConversationAgent(conversationId: String?, agentId: String, onDone: () -> Unit) {
        val device = _desktopDevice.value
        val id = conversationId ?: return
        viewModelScope.launch {
            if (device != null && conversationStore.setAgent(device, id, agentId)) {
                onDone()
            }
        }
    }

    /** 设置对话的授权档位（对话级，互不影响）。 */
    fun setConversationApproval(conversationId: String?, mode: String, onDone: () -> Unit) {
        val device = _desktopDevice.value
        val id = conversationId ?: return
        viewModelScope.launch {
            if (device != null && conversationStore.setApprovalMode(device, id, mode)) {
                onDone()
            }
        }
    }

    /** 设置 / 清除对话的模型覆盖（`modelId == null` = 清除，回落 Agent 默认模型）。 */
    fun setConversationModel(
        conversationId: String?,
        modelId: String?,
        providerId: String?,
        onDone: () -> Unit,
    ) {
        val device = _desktopDevice.value
        val id = conversationId ?: return
        viewModelScope.launch {
            if (device != null && conversationStore.setModel(device, id, modelId, providerId)) {
                onDone()
            }
        }
    }

    /** 置顶 / 取消置顶（与桌面端侧栏同一 PATCH 语义）。 */
    fun pinConversation(id: String, pinned: Boolean, onDone: () -> Unit) {
        val device = _desktopDevice.value ?: return
        viewModelScope.launch {
            if (conversationStore.setPinned(device, id, pinned)) onDone()
        }
    }

    /** 归档对话（从列表消失，恢复走桌面端或后续「已归档」入口）。 */
    fun archiveConversation(id: String, onDone: () -> Unit) {
        val device = _desktopDevice.value ?: return
        viewModelScope.launch {
            if (conversationStore.setArchived(device, id, true)) onDone()
        }
    }

    /** 绑定 / 解绑对话的工作目录（`path == null` = 解绑）。 */
    fun setConversationWorkdir(conversationId: String, path: String?, onDone: () -> Unit) {
        val device = _desktopDevice.value ?: return
        viewModelScope.launch {
            if (conversationStore.setWorkdir(device, conversationId, path)) onDone()
        }
    }

    // ─── Folder browsing（对话级 workdir 绑定的目录浏览）───────────────────────

    fun fetchFolderRoots(onResult: (com.brewping.android.model.FolderRoots?) -> Unit) {
        val device = _desktopDevice.value ?: run { onResult(null); return }
        viewModelScope.launch { onResult(appPairingApi.fetchFolderRoots(device)) }
    }

    fun fetchFolder(path: String?, onResult: (com.brewping.android.model.FolderBrowse?) -> Unit) {
        val device = _desktopDevice.value ?: run { onResult(null); return }
        viewModelScope.launch { onResult(appPairingApi.browseFolder(device, path)) }
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    private fun connectToDevice(device: ManagedDevice) {
        val ip = device.host.trim()
        val portNum = device.port.trim().toIntOrNull() ?: 8787
        if (ip.isEmpty()) return

        val desktopDevice = DesktopDevice(
            id = device.id,
            name = device.name,
            host = ip,
            ip = ip,
            port = portNum,
        )

        // 对话页所有请求都用这台设备（conversationStore / modelStore 的缓存键含 deviceID）
        _desktopDevice.value = desktopDevice
        modelStore.invalidate()

        statusPollJob?.cancel()
        viewModelScope.launch {
            repository.refreshStatus(desktopDevice)
            if (repository.online.value) {
                repository.startStatusPolling(desktopDevice)
                repository.refreshAgents(desktopDevice)
                // 在线即拉对话列表（配对后 token 已就位，否则走 unsupported/error 提示）
                conversationStore.refresh(desktopDevice)
            }
        }
    }

    private fun currentDesktopDevice(): DesktopDevice? {
        val device = deviceStore.activeDevice ?: return null
        val ip = device.host.trim()
        if (ip.isEmpty()) return null
        val portNum = device.port.trim().toIntOrNull() ?: 8787
        return DesktopDevice(
            id = device.id,
            name = device.name,
            host = ip,
            ip = ip,
            port = portNum,
        )
    }

    private fun resetState() {
        _messageText.value = ""
        _discoveryMessage.value = ""
        _sessionID.value = ""
        _sessionAgentID.value = "opencode"
        _sessionAgentName.value = "OpenCode"
        _desktopDevice.value = null
        _conversationRoute.value = null
        conversationStore.invalidate()
        modelStore.invalidate()
        repository.resetAllState()
    }

    override fun onCleared() {
        super.onCleared()
        repository.stop()
    }

    class Factory(
        private val repository: DesktopRepository,
        private val deviceStore: DeviceStore,
        private val commandReceiver: CommandReceiver,
        private val conversationStore: ConversationStore,
        private val modelStore: ModelStore,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            return HomeViewModel(repository, deviceStore, commandReceiver, conversationStore, modelStore) as T
        }
    }
}
