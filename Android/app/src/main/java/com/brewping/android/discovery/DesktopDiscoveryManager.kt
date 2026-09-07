package com.brewping.android.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import com.brewping.android.model.AgentInfo
import com.brewping.android.model.DesktopDevice
import com.brewping.android.model.DesktopStatus
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.net.InetAddress

/**
 * Discovers BrewPing Desktop services on the local network via Android NSD / mDNS.
 *
 * Listens for `_brewping._tcp` services, resolves their host/IP/port,
 * and publishes discovered devices as a [StateFlow].
 */
class DesktopDiscoveryManager(private val context: Context) {

    companion object {
        private const val TAG = "BrewPingDiscovery"
        private const val SERVICE_TYPE = "_brewping._tcp"
    }

    private val nsdManager: NsdManager =
        context.getSystemService(Context.NSD_SERVICE) as NsdManager

    private val _discoveredDevices = MutableStateFlow<List<DesktopDevice>>(emptyList())
    val discoveredDevices: StateFlow<List<DesktopDevice>> = _discoveredDevices.asStateFlow()

    private val _isDiscovering = MutableStateFlow(false)
    val isDiscovering: StateFlow<Boolean> = _isDiscovering.asStateFlow()

    private var discoveryListener: NsdManager.DiscoveryListener? = null

    // Tracks services currently being resolved to avoid duplicates
    private val resolvingServices = mutableSetOf<String>()

    fun startDiscovery() {
        if (_isDiscovering.value) {
            Log.d(TAG, "[Discovery] Already discovering, skipping")
            return
        }

        Log.i(TAG, "[Discovery] Starting discovery for $SERVICE_TYPE")
        _isDiscovering.value = true

        discoveryListener = createDiscoveryListener()
        try {
            nsdManager.discoverServices(
                SERVICE_TYPE,
                NsdManager.PROTOCOL_DNS_SD,
                discoveryListener
            )
        } catch (e: Exception) {
            Log.e(TAG, "[Discovery] Failed to start: ${e.message}", e)
            _isDiscovering.value = false
        }
    }

    fun stopDiscovery() {
        Log.i(TAG, "[Discovery] Stopping discovery")
        discoveryListener?.let {
            try {
                nsdManager.stopServiceDiscovery(it)
            } catch (e: Exception) {
                Log.w(TAG, "[Discovery] Error stopping: ${e.message}")
            }
        }
        discoveryListener = null
        _isDiscovering.value = false
        resolvingServices.clear()
    }

    fun clearDevices() {
        _discoveredDevices.value = emptyList()
    }

    private fun createDiscoveryListener(): NsdManager.DiscoveryListener {
        return object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                Log.i(TAG, "[Discovery] Discovery started for $serviceType")
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                val name = serviceInfo.serviceName
                Log.i(TAG, "[Discovery] Service found: $name")

                // Avoid resolving the same service concurrently
                if (resolvingServices.contains(name)) {
                    Log.d(TAG, "[Discovery] Already resolving: $name, skipping")
                    return
                }

                resolvingServices.add(name)
                resolveService(serviceInfo)
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                val name = serviceInfo.serviceName
                Log.i(TAG, "[Discovery] Service lost: $name")
                removeDevice(name)
            }

            override fun onDiscoveryStopped(serviceType: String) {
                Log.i(TAG, "[Discovery] Discovery stopped")
                _isDiscovering.value = false
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "[Discovery] Start failed: error code $errorCode")
                _isDiscovering.value = false
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "[Discovery] Stop failed: error code $errorCode")
            }
        }
    }

    private fun resolveService(serviceInfo: NsdServiceInfo) {
        Log.d(TAG, "[Discovery] Resolving service: ${serviceInfo.serviceName}")

        nsdManager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "[Discovery] Resolve failed: error code $errorCode")
                resolvingServices.remove(serviceInfo.serviceName)
            }

            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                val host: InetAddress = serviceInfo.host
                val port: Int = serviceInfo.port
                val ip = host.hostAddress ?: "unknown"
                val name = serviceInfo.serviceName

                Log.i(TAG, "[Discovery] Resolved: $name -> $ip:$port")

                // Read TXT record attributes if available
                val attributes = serviceInfo.attributes
                val version = attributes["version"]?.let { String(it) } ?: ""
                val agent = attributes["agent"]?.let { String(it) } ?: ""
                val platform = attributes["platform"]?.let { String(it) } ?: "unknown"
                val deviceId = attributes["deviceId"]?.let { String(it) } ?: ""
                val deviceName = attributes["deviceName"]?.let { String(it) } ?: name

                val device = DesktopDevice(
                    id = deviceId.ifEmpty { "nsd-$name" },
                    name = deviceName.ifEmpty { name },
                    host = "${name}.local",
                    ip = ip,
                    port = port,
                    platform = platform,
                    version = version,
                    status = DesktopStatus.Online,
                    agentName = agent,
                )

                addOrUpdateDevice(device)
                resolvingServices.remove(name)
            }
        })
    }

    private fun addOrUpdateDevice(device: DesktopDevice) {
        val current = _discoveredDevices.value.toMutableList()
        val existingIndex = current.indexOfFirst { it.id == device.id || it.name == device.name }
        if (existingIndex >= 0) {
            current[existingIndex] = device
        } else {
            current.add(device)
        }
        _discoveredDevices.value = current
    }

    private fun removeDevice(serviceName: String) {
        val current = _discoveredDevices.value.toMutableList()
        current.removeAll { it.name == serviceName }
        _discoveredDevices.value = current
    }
}
