package com.brewping.android.repository

import android.util.Log
import com.brewping.android.api.DesktopApiClient
import com.brewping.android.discovery.DesktopDiscoveryManager
import com.brewping.android.model.AgentEntry
import com.brewping.android.model.CommandPhase
import com.brewping.android.model.DesktopDevice
import com.brewping.android.model.DesktopStatus
import com.brewping.android.model.SessionBrief
import com.brewping.android.model.SessionState
import com.brewping.android.model.StatusResponse
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * Coordinates discovery, status polling, agent management,
 * session lifecycle, and message sending.
 * Matches the iOS ContentView's data flow.
 */
class DesktopRepository(
    private val discoveryManager: DesktopDiscoveryManager,
    private val apiClient: DesktopApiClient,
) {
    companion object {
        private const val TAG = "BrewPingRepository"
        private const val STATUS_POLL_INTERVAL_MS = 5_000L
        private const val COMMAND_POLL_INTERVAL_MS = 1_000L
        private const val MAX_CONSECUTIVE_ERRORS = 10
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    // ─── Device & connection ──────────────────────────────────────────────────

    private val _activeDevice = MutableStateFlow<DesktopDevice?>(null)
    val activeDevice: StateFlow<DesktopDevice?> = _activeDevice.asStateFlow()

    private val _connectionState = MutableStateFlow(ConnectionState.Idle)
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

    // ─── Status response ──────────────────────────────────────────────────────

    private val _statusResponse = MutableStateFlow<StatusResponse?>(null)
    val statusResponse: StateFlow<StatusResponse?> = _statusResponse.asStateFlow()

    private val _online = MutableStateFlow(false)
    val online: StateFlow<Boolean> = _online.asStateFlow()

    private val _hostName = MutableStateFlow("")
    val hostName: StateFlow<String> = _hostName.asStateFlow()

    // ─── Agents ───────────────────────────────────────────────────────────────

    private val _agents = MutableStateFlow<List<AgentEntry>>(emptyList())
    val agents: StateFlow<List<AgentEntry>> = _agents.asStateFlow()

    // ─── Session ──────────────────────────────────────────────────────────────

    private val _sessionState = MutableStateFlow(SessionState.Offline)
    val sessionState: StateFlow<SessionState> = _sessionState.asStateFlow()

    private val _sessionBrief = MutableStateFlow<SessionBrief?>(null)
    val sessionBrief: StateFlow<SessionBrief?> = _sessionBrief.asStateFlow()

    private val _sessionMessage = MutableStateFlow("")
    val sessionMessage: StateFlow<String> = _sessionMessage.asStateFlow()

    private val _lifecycleBusy = MutableStateFlow(false)
    val lifecycleBusy: StateFlow<Boolean> = _lifecycleBusy.asStateFlow()

    // ─── Command / message ────────────────────────────────────────────────────

    private val _commandPhase = MutableStateFlow<CommandPhase>(CommandPhase.Idle)
    val commandPhase: StateFlow<CommandPhase> = _commandPhase.asStateFlow()

    private var pollJob: Job? = null
    private var statusPollJob: Job? = null
    private var commandPollJob: Job? = null

    // ─── Discovery flow ───────────────────────────────────────────────────────

    fun start() {
        Log.i(TAG, "[Repository] Starting")
        scope.launch {
            discoveryManager.discoveredDevices.collectLatest { devices ->
                if (devices.isEmpty()) {
                    if (_connectionState.value == ConnectionState.Connected ||
                        _connectionState.value == ConnectionState.Connecting
                    ) {
                        _connectionState.value = ConnectionState.Searching
                    }
                } else {
                    val device = devices.first()
                    _activeDevice.value = device
                    _connectionState.value = ConnectionState.Connecting
                    refreshStatus(device)
                }
            }
        }
    }

    fun stop() {
        Log.i(TAG, "[Repository] Stopping")
        pollJob?.cancel()
        statusPollJob?.cancel()
        commandPollJob?.cancel()
        discoveryManager.stopDiscovery()
    }

    fun startDiscovery() {
        discoveryManager.startDiscovery()
    }

    fun stopDiscovery() {
        discoveryManager.stopDiscovery()
    }

    // ─── Status polling (matches iOS 5-second refreshStatus loop) ─────────────

    fun startStatusPolling(device: DesktopDevice) {
        statusPollJob?.cancel()
        statusPollJob = scope.launch {
            while (true) {
                delay(STATUS_POLL_INTERVAL_MS)
                refreshStatus(device)
            }
        }
    }

    suspend fun refreshStatus(device: DesktopDevice) {
        val response = apiClient.fetchStatus(device)
        _statusResponse.value = response

        if (response != null) {
            _online.value = response.status == "online"
            _hostName.value = response.host

            // Session state from server (matches iOS logic)
            if (!_lifecycleBusy.value) {
                val serverSession = response.session
                if (serverSession?.status == "running") {
                    _sessionState.value = SessionState.Running
                    _sessionBrief.value = serverSession
                } else {
                    if (_sessionState.value == SessionState.Running) {
                        _sessionState.value = SessionState.Offline
                    }
                    _sessionBrief.value = serverSession
                }
            }

            _connectionState.value = ConnectionState.Connected

            // Fetch agents after status is confirmed
            if (_agents.value.isEmpty()) {
                refreshAgents(device)
            }
        } else {
            _online.value = false
            _connectionState.value = ConnectionState.Disconnected
        }
    }

    // ─── Agents ───────────────────────────────────────────────────────────────

    suspend fun refreshAgents(device: DesktopDevice) {
        val response = apiClient.fetchAgents(device)
        if (response != null) {
            _agents.value = response.agents
        }
    }

    suspend fun setDefaultAgent(device: DesktopDevice, agentId: String) {
        val error = apiClient.setDefaultAgent(device, agentId)
        if (error != null) {
            _sessionMessage.value = error
        }
        refreshStatus(device)
        refreshAgents(device)
    }

    // ─── Session lifecycle (matches iOS newSession/stopSession) ───────────────

    suspend fun startSession(device: DesktopDevice) {
        commandPollJob?.cancel()
        _commandPhase.value = CommandPhase.Idle
        _lifecycleBusy.value = true
        _sessionState.value = SessionState.Starting
        _sessionMessage.value = ""

        val response = apiClient.startSession(device)
        if (response != null) {
            if (response.success) {
                _sessionMessage.value = ""
            } else {
                _sessionMessage.value = response.error.ifEmpty { "Start failed" }
            }
        } else {
            _sessionMessage.value = "Start failed — no response"
        }

        _lifecycleBusy.value = false
        refreshStatus(device)

        // Fallback if still starting and offline
        if (_sessionState.value == SessionState.Starting && !_online.value) {
            _sessionState.value = SessionState.Offline
        }
    }

    suspend fun stopSession(device: DesktopDevice) {
        commandPollJob?.cancel()
        _lifecycleBusy.value = true
        _sessionState.value = SessionState.Stopping
        _sessionMessage.value = ""

        val response = apiClient.stopSession(device)
        if (response != null && response.success) {
            _sessionMessage.value = "Session stopped"
            _commandPhase.value = CommandPhase.Idle
        } else {
            _sessionMessage.value = response?.error?.ifEmpty { "Stop failed" } ?: "Stop failed — no response"
        }

        _lifecycleBusy.value = false
        refreshStatus(device)

        if (_sessionState.value == SessionState.Stopping && !_online.value) {
            _sessionState.value = SessionState.Offline
        }
    }

    // ─── Message sending (matches iOS send/submit/poll) ───────────────────────

    suspend fun submitMessage(device: DesktopDevice, text: String) {
        // Confirm session is alive
        refreshStatus(device)

        commandPollJob?.cancel()
        _commandPhase.value = CommandPhase.Sending

        val response = apiClient.submitMessage(device, text)
        if (response != null && response.commandId.isNotEmpty()) {
            _commandPhase.value = CommandPhase.Delivered
            startCommandPolling(device, response.commandId)
        } else {
            _commandPhase.value = CommandPhase.Failed(
                error = response?.error ?: "Send failed",
            )
        }
    }

    private fun startCommandPolling(device: DesktopDevice, commandId: String) {
        commandPollJob?.cancel()
        commandPollJob = scope.launch {
            var consecutiveErrors = 0
            while (true) {
                delay(COMMAND_POLL_INTERVAL_MS)
                val result = apiClient.pollCommandStatus(device, commandId)
                if (result != null) {
                    consecutiveErrors = 0
                    when (result.status) {
                        "queued", "sent" -> _commandPhase.value = CommandPhase.Delivered
                        "working" -> _commandPhase.value = CommandPhase.Working
                        "completed" -> {
                            _commandPhase.value = CommandPhase.Completed(
                                response = result.response,
                                duration = result.duration,
                                modelId = result.modelId.ifEmpty { null },
                            )
                            return@launch
                        }
                        "completed_with_raw" -> {
                            _commandPhase.value = CommandPhase.CompletedRaw(
                                rawOutput = result.rawOutput,
                                duration = result.duration,
                                modelId = result.modelId.ifEmpty { null },
                            )
                            return@launch
                        }
                        "failed" -> {
                            _commandPhase.value = CommandPhase.Failed(
                                error = result.error,
                                duration = result.duration,
                                failureReason = result.failureReason.ifEmpty { null },
                                modelId = result.modelId.ifEmpty { null },
                            )
                            return@launch
                        }
                    }
                } else {
                    consecutiveErrors++
                    if (consecutiveErrors >= MAX_CONSECUTIVE_ERRORS) {
                        _commandPhase.value = CommandPhase.Failed(
                            error = "Lost connection after $consecutiveErrors retries",
                        )
                        return@launch
                    }
                }
            }
        }
    }

    // ─── Discovery refresh (POST /api/discovery/refresh) ──────────────────────

    suspend fun refreshDiscovery(device: DesktopDevice) {
        apiClient.refreshDiscovery(device)
        refreshStatus(device)
        refreshAgents(device)
    }
}

enum class ConnectionState {
    Idle,
    Searching,
    Connecting,
    Connected,
    Disconnected,
    Error,
}
