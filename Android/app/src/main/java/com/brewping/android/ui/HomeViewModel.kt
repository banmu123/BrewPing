package com.brewping.android.ui

import android.content.Context
import android.content.SharedPreferences
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.brewping.android.model.AgentEntry
import com.brewping.android.model.CommandPhase
import com.brewping.android.model.DesktopDevice
import com.brewping.android.model.SessionState
import com.brewping.android.repository.ConnectionState
import com.brewping.android.repository.DesktopRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class HomeViewModel(
    private val repository: DesktopRepository,
    prefs: SharedPreferences,
) : ViewModel() {

    // ─── Persisted fields (matches iOS @AppStorage) ───────────────────────────

    private val _macAddress = MutableStateFlow(prefs.getString(KEY_MAC, "") ?: "")
    val macAddress: StateFlow<String> = _macAddress.asStateFlow()

    private val _port = MutableStateFlow(prefs.getString(KEY_PORT, "8787") ?: "8787")
    val port: StateFlow<String> = _port.asStateFlow()

    private val _messageText = MutableStateFlow("")
    val messageText: StateFlow<String> = _messageText.asStateFlow()

    private val _discoveryMessage = MutableStateFlow("")
    val discoveryMessage: StateFlow<String> = _discoveryMessage.asStateFlow()

    private val _discoveryRunning = MutableStateFlow(false)
    val discoveryRunning: StateFlow<Boolean> = _discoveryRunning.asStateFlow()

    private val prefs: SharedPreferences = prefs

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

    init {
        // Observe discovered devices and auto-configure
        viewModelScope.launch {
            repository.activeDevice.collect { device ->
                if (device != null && _macAddress.value.isEmpty()) {
                    _macAddress.value = device.ip
                    _port.value = device.port.toString()
                    savePrefs()
                }
            }
        }

        // Start discovery
        repository.start()
        repository.startDiscovery()
    }

    // ─── User actions ─────────────────────────────────────────────────────────

    fun updateMacAddress(value: String) {
        _macAddress.value = value
        savePrefs()
    }

    fun updatePort(value: String) {
        _port.value = value
        savePrefs()
    }

    fun updateMessageText(value: String) {
        _messageText.value = value
    }

    /** "Auto" button — trigger Bonjour discovery */
    fun autoDiscover() {
        _discoveryRunning.value = true
        _discoveryMessage.value = ""

        viewModelScope.launch {
            repository.stopDiscovery()
            repository.startDiscovery()

            // Wait up to 5 seconds for a result (matches iOS timing)
            var attempts = 0
            while (attempts < 10) {
                kotlinx.coroutines.delay(500)
                val device = repository.activeDevice.value
                if (device != null) {
                    _macAddress.value = device.ip
                    _port.value = device.port.toString()
                    savePrefs()
                    _discoveryMessage.value = "Found: ${device.name}"
                    _discoveryRunning.value = false
                    checkConnection()
                    return@launch
                }
                attempts++
            }

            _discoveryMessage.value = "No BrewPing agent found on this network"
            _discoveryRunning.value = false
        }
    }

    /** "Check" button — refresh status and agents */
    fun checkConnection() {
        val ip = _macAddress.value.trim()
        val portNum = _port.value.trim().toIntOrNull() ?: 8787
        if (ip.isEmpty()) return

        val device = DesktopDevice(
            id = "manual",
            name = ip,
            host = "$ip.local",
            ip = ip,
            port = portNum,
        )

        viewModelScope.launch {
            repository.refreshStatus(device)
            if (repository.online.value) {
                repository.startStatusPolling(device)
                repository.refreshAgents(device)
            }
        }
    }

    /** "Set Default" agent */
    fun setDefaultAgent(agentId: String) {
        val device = currentDevice() ?: return
        viewModelScope.launch {
            repository.setDefaultAgent(device, agentId)
        }
    }

    /** Start session */
    fun startSession() {
        val device = currentDevice() ?: return
        viewModelScope.launch {
            repository.startSession(device)
        }
    }

    /** Stop session */
    fun stopSession() {
        val device = currentDevice() ?: return
        viewModelScope.launch {
            repository.stopSession(device)
        }
    }

    /** Send message */
    fun sendMessage() {
        val device = currentDevice() ?: return
        val text = _messageText.value.trim()
        if (text.isEmpty()) return
        _messageText.value = ""

        viewModelScope.launch {
            repository.submitMessage(device, text)
        }
    }

    /** Force server-side agent re-scan */
    fun refreshDiscovery() {
        val device = currentDevice() ?: return
        _discoveryRunning.value = true
        viewModelScope.launch {
            repository.refreshDiscovery(device)
            _discoveryRunning.value = false
        }
    }

    private fun currentDevice(): DesktopDevice? {
        val ip = _macAddress.value.trim()
        if (ip.isEmpty()) return null
        val portNum = _port.value.trim().toIntOrNull() ?: 8787
        return DesktopDevice(
            id = "manual",
            name = ip,
            host = "$ip.local",
            ip = ip,
            port = portNum,
        )
    }

    private fun savePrefs() {
        prefs.edit()
            .putString(KEY_MAC, _macAddress.value)
            .putString(KEY_PORT, _port.value)
            .apply()
    }

    override fun onCleared() {
        super.onCleared()
        repository.stop()
    }

    companion object {
        private const val KEY_MAC = "brewping.macAddress"
        private const val KEY_PORT = "brewping.port"
    }

    class Factory(
        private val repository: DesktopRepository,
        private val context: Context,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            val prefs = context.getSharedPreferences("brewping_prefs", Context.MODE_PRIVATE)
            return HomeViewModel(repository, prefs) as T
        }
    }
}
