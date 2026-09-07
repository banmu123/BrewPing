package com.brewping.android.repository

import android.util.Log
import com.brewping.android.api.DesktopApiClient
import com.brewping.android.discovery.DesktopDiscoveryManager
import com.brewping.android.model.DesktopDevice
import com.brewping.android.model.DesktopStatus
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
 * Coordinates discovery and API communication.
 *
 * Observes [DesktopDiscoveryManager.discoveredDevices] and automatically
 * fetches detailed status via HTTP for each discovered device.
 */
class DesktopRepository(
    private val discoveryManager: DesktopDiscoveryManager,
    private val apiClient: DesktopApiClient,
) {
    companion object {
        private const val TAG = "BrewPingRepository"
        private const val STATUS_POLL_INTERVAL_MS = 5_000L
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val _activeDevice = MutableStateFlow<DesktopDevice?>(null)
    val activeDevice: StateFlow<DesktopDevice?> = _activeDevice.asStateFlow()

    private val _connectionState = MutableStateFlow(ConnectionState.Idle)
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

    private var pollJob: Job? = null

    fun start() {
        Log.i(TAG, "[Repository] Starting — observing discovery and polling")
        discoveryManager.startDiscovery()

        // Observe discovered devices
        scope.launch {
            discoveryManager.discoveredDevices.collectLatest { devices ->
                if (devices.isEmpty()) {
                    Log.d(TAG, "[Repository] No devices found")
                    if (_connectionState.value != ConnectionState.Idle) {
                        _connectionState.value = ConnectionState.Searching
                    }
                    _activeDevice.value = null
                } else {
                    val device = devices.first()
                    Log.i(TAG, "[Repository] Device available: ${device.name} (${device.ip}:${device.port})")
                    _activeDevice.value = device
                    _connectionState.value = ConnectionState.Connecting
                    refreshDeviceStatus(device)
                }
            }
        }
    }

    fun stop() {
        Log.i(TAG, "[Repository] Stopping")
        pollJob?.cancel()
        discoveryManager.stopDiscovery()
    }

    fun refresh() {
        Log.i(TAG, "[Repository] Manual refresh requested")
        val currentDevice = _activeDevice.value
        if (currentDevice != null) {
            scope.launch { refreshDeviceStatus(currentDevice) }
        } else {
            _connectionState.value = ConnectionState.Searching
            discoveryManager.clearDevices()
            discoveryManager.stopDiscovery()
            discoveryManager.startDiscovery()
        }
    }

    fun startSearching() {
        _connectionState.value = ConnectionState.Searching
    }

    private suspend fun refreshDeviceStatus(device: DesktopDevice) {
        val updated = apiClient.fetchDeviceStatus(device)
        if (updated != null) {
            _activeDevice.value = updated
            _connectionState.value = when (updated.status) {
                DesktopStatus.Online -> ConnectionState.Connected
                DesktopStatus.Offline -> ConnectionState.Disconnected
                DesktopStatus.Error -> ConnectionState.Error
                DesktopStatus.Connecting -> ConnectionState.Connecting
            }

            // Start polling if connected
            if (updated.status == DesktopStatus.Online) {
                startPolling(updated)
            }
        } else {
            _connectionState.value = ConnectionState.Disconnected
        }
    }

    private fun startPolling(device: DesktopDevice) {
        pollJob?.cancel()
        pollJob = scope.launch {
            while (true) {
                delay(STATUS_POLL_INTERVAL_MS)
                Log.d(TAG, "[Repository] Polling device status")
                val updated = apiClient.fetchDeviceStatus(device)
                if (updated != null) {
                    _activeDevice.value = updated
                    if (updated.status == DesktopStatus.Offline) {
                        _connectionState.value = ConnectionState.Disconnected
                        break
                    }
                } else {
                    _activeDevice.value = device.copy(status = DesktopStatus.Offline)
                    _connectionState.value = ConnectionState.Disconnected
                    break
                }
            }
        }
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
