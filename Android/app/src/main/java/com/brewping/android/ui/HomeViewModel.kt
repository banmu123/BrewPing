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
import com.brewping.android.store.DeviceStore
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class HomeViewModel(
    private val repository: DesktopRepository,
    private val deviceStore: DeviceStore,
    private val commandReceiver: CommandReceiver,
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

    private var statusPollJob: Job? = null

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

        statusPollJob?.cancel()
        viewModelScope.launch {
            repository.refreshStatus(desktopDevice)
            if (repository.online.value) {
                repository.startStatusPolling(desktopDevice)
                repository.refreshAgents(desktopDevice)
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
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            return HomeViewModel(repository, deviceStore, commandReceiver) as T
        }
    }
}
