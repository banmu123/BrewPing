package com.brewping.android.api

import android.util.Log
import com.brewping.android.model.AgentInfo
import com.brewping.android.model.DesktopDevice
import com.brewping.android.model.DesktopStatus
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * HTTP client for the BrewPing Desktop API.
 *
 * Communicates with the Desktop over plain HTTP (no auth) on the local network.
 * All calls are suspending and run on [Dispatchers.IO].
 */
class DesktopApiClient {

    companion object {
        private const val TAG = "BrewPingAPI"
        private const val CONNECT_TIMEOUT_SECONDS = 5L
        private const val READ_TIMEOUT_SECONDS = 5L
        private const val WRITE_TIMEOUT_SECONDS = 5L
    }

    private val client = OkHttpClient.Builder()
        .connectTimeout(CONNECT_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        .readTimeout(READ_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        .writeTimeout(WRITE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        .build()

    /**
     * Fetches the Desktop status and agent info from the HTTP API.
     * Returns an updated [DesktopDevice] with status and agent details populated,
     * or null if the request fails.
     */
    suspend fun fetchDeviceStatus(device: DesktopDevice): DesktopDevice? =
        withContext(Dispatchers.IO) {
            try {
                val baseUrl = "http://${device.ip}:${device.port}"

                // Fetch status
                val statusResponse = get("$baseUrl/api/status")
                if (statusResponse == null) {
                    Log.w(TAG, "[API] Status request failed for ${device.ip}:${device.port}")
                    return@withContext device.copy(status = DesktopStatus.Offline)
                }

                Log.i(TAG, "[API] GET /api/status -> ${statusResponse}")

                // Fetch agents
                val agentsResponse = get("$baseUrl/api/agents")
                val agents = parseAgents(agentsResponse)
                val defaultAgent = agentsResponse?.optString("defaultAgent") ?: ""

                val activeAgent = agents.firstOrNull { it.id == defaultAgent }
                    ?: agents.firstOrNull { it.active }

                device.copy(
                    status = DesktopStatus.Online,
                    agentName = activeAgent?.name ?: device.agentName,
                    agentStatus = if (activeAgent != null) "running" else "none",
                    agents = agents,
                )
            } catch (e: Exception) {
                Log.e(TAG, "[API] Error fetching status: ${e.message}", e)
                device.copy(status = DesktopStatus.Error)
            }
        }

    private fun get(url: String): JSONObject? {
        Log.d(TAG, "[API] GET $url")
        val request = Request.Builder()
            .url(url)
            .get()
            .build()

        return try {
            val response = client.newCall(request).execute()
            val code = response.code
            Log.d(TAG, "[API] Response $code from $url")

            if (code == 200) {
                val body = response.body?.string()
                if (body != null) JSONObject(body) else null
            } else {
                null
            }
        } catch (e: Exception) {
            Log.w(TAG, "[API] Request failed: $url — ${e.message}")
            null
        }
    }

    private fun parseAgents(json: JSONObject?): List<AgentInfo> {
        if (json == null) return emptyList()
        val agentsArray = json.optJSONArray("agents") ?: return emptyList()

        val result = mutableListOf<AgentInfo>()
        for (i in 0 until agentsArray.length()) {
            val obj = agentsArray.getJSONObject(i)
            result.add(
                AgentInfo(
                    id = obj.optString("id", ""),
                    name = obj.optString("name", ""),
                    installed = obj.optBoolean("installed", false),
                    active = obj.optBoolean("active", false),
                    version = obj.optString("version", ""),
                )
            )
        }
        return result
    }
}
