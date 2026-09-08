package com.brewping.android.api

import android.util.Log
import com.brewping.android.model.AgentEntry
import com.brewping.android.model.AgentsResponse
import com.brewping.android.model.CommandStatusResponse
import com.brewping.android.model.DesktopDevice
import com.brewping.android.model.LifecycleResponse
import com.brewping.android.model.StatusResponse
import com.brewping.android.model.SubmitResponse
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * HTTP client for the BrewPing Desktop API.
 * Matches the iOS ContentView's URLSession calls exactly.
 */
class DesktopApiClient {

    companion object {
        private const val TAG = "BrewPingAPI"
        private const val DEFAULT_TIMEOUT = 5L
        private const val SESSION_TIMEOUT = 120L
        private const val MESSAGE_TIMEOUT = 30L
    }

    private val client = OkHttpClient.Builder()
        .connectTimeout(DEFAULT_TIMEOUT, TimeUnit.SECONDS)
        .readTimeout(DEFAULT_TIMEOUT, TimeUnit.SECONDS)
        .writeTimeout(DEFAULT_TIMEOUT, TimeUnit.SECONDS)
        .build()

    private val sessionClient = OkHttpClient.Builder()
        .connectTimeout(SESSION_TIMEOUT, TimeUnit.SECONDS)
        .readTimeout(SESSION_TIMEOUT, TimeUnit.SECONDS)
        .writeTimeout(SESSION_TIMEOUT, TimeUnit.SECONDS)
        .build()

    private val messageClient = OkHttpClient.Builder()
        .connectTimeout(MESSAGE_TIMEOUT, TimeUnit.SECONDS)
        .readTimeout(MESSAGE_TIMEOUT, TimeUnit.SECONDS)
        .writeTimeout(MESSAGE_TIMEOUT, TimeUnit.SECONDS)
        .build()

    // ─── GET /api/status ──────────────────────────────────────────────────────

    suspend fun fetchStatus(device: DesktopDevice): StatusResponse? =
        withContext(Dispatchers.IO) {
            try {
                val json = get(client, baseUrl(device) + "/api/status") ?: return@withContext null
                Log.i(TAG, "[API] GET /api/status -> $json")
                StatusResponse(
                    status = json.optString("status", ""),
                    host = json.optString("host", ""),
                    defaultAgent = json.optString("defaultAgent", ""),
                    session = json.optJSONObject("session")?.let { parseSessionBrief(it) },
                )
            } catch (e: Exception) {
                Log.w(TAG, "[API] fetchStatus error: ${e.message}")
                null
            }
        }

    // ─── GET /api/agents ──────────────────────────────────────────────────────

    suspend fun fetchAgents(device: DesktopDevice): AgentsResponse? =
        withContext(Dispatchers.IO) {
            try {
                val json = get(client, baseUrl(device) + "/api/agents") ?: return@withContext null
                Log.i(TAG, "[API] GET /api/agents -> $json")
                val agentsArray = json.optJSONArray("agents")
                val agents = mutableListOf<AgentEntry>()
                if (agentsArray != null) {
                    for (i in 0 until agentsArray.length()) {
                        val obj = agentsArray.getJSONObject(i)
                        agents.add(
                            AgentEntry(
                                id = obj.optString("id", ""),
                                name = obj.optString("name", ""),
                                installed = obj.optBoolean("installed", false),
                                active = obj.optBoolean("active", false),
                                // executable can be bool or string path
                                executable = parseExecutable(obj),
                                version = obj.optString("version", ""),
                            )
                        )
                    }
                }
                AgentsResponse(
                    agents = agents,
                    defaultAgent = json.optString("defaultAgent", ""),
                )
            } catch (e: Exception) {
                Log.w(TAG, "[API] fetchAgents error: ${e.message}")
                null
            }
        }

    // ─── POST /api/agents/default ─────────────────────────────────────────────

    suspend fun setDefaultAgent(device: DesktopDevice, agentId: String): String? =
        withContext(Dispatchers.IO) {
            try {
                val body = JSONObject().put("agent", agentId).toString()
                val json = post(client, baseUrl(device) + "/api/agents/default", body)
                if (json != null) {
                    Log.i(TAG, "[API] POST /api/agents/default -> $json")
                    if (!json.optBoolean("success", false)) {
                        json.optString("error", "Unknown error")
                    } else null
                } else "Request failed"
            } catch (e: Exception) {
                Log.w(TAG, "[API] setDefaultAgent error: ${e.message}")
                "Switch failed: ${e.message}"
            }
        }

    // ─── POST /api/session/start ──────────────────────────────────────────────

    suspend fun startSession(device: DesktopDevice): LifecycleResponse? =
        withContext(Dispatchers.IO) {
            try {
                val json = post(sessionClient, baseUrl(device) + "/api/session/start", "")
                if (json != null) {
                    Log.i(TAG, "[API] POST /api/session/start -> $json")
                    LifecycleResponse(
                        success = json.optBoolean("success", false),
                        sessionId = json.optString("sessionId", ""),
                        status = json.optString("status", ""),
                        error = json.optString("error", ""),
                    )
                } else null
            } catch (e: Exception) {
                Log.w(TAG, "[API] startSession error: ${e.message}")
                null
            }
        }

    // ─── POST /api/session/stop ───────────────────────────────────────────────

    suspend fun stopSession(device: DesktopDevice): LifecycleResponse? =
        withContext(Dispatchers.IO) {
            try {
                val json = post(messageClient, baseUrl(device) + "/api/session/stop", "")
                if (json != null) {
                    Log.i(TAG, "[API] POST /api/session/stop -> $json")
                    LifecycleResponse(
                        success = json.optBoolean("success", false),
                        sessionId = json.optString("sessionId", ""),
                        status = json.optString("status", ""),
                        error = json.optString("error", ""),
                    )
                } else null
            } catch (e: Exception) {
                Log.w(TAG, "[API] stopSession error: ${e.message}")
                null
            }
        }

    // ─── POST /api/message ────────────────────────────────────────────────────

    suspend fun submitMessage(device: DesktopDevice, text: String): SubmitResponse? =
        withContext(Dispatchers.IO) {
            try {
                val body = JSONObject().put("text", text).toString()
                val json = post(messageClient, baseUrl(device) + "/api/message", body)
                if (json != null) {
                    Log.i(TAG, "[API] POST /api/message -> $json")
                    SubmitResponse(
                        success = json.optBoolean("success", false),
                        commandId = json.optString("commandId", ""),
                        sessionId = json.optString("sessionId", ""),
                        error = json.optString("error", ""),
                    )
                } else null
            } catch (e: Exception) {
                Log.w(TAG, "[API] submitMessage error: ${e.message}")
                null
            }
        }

    // ─── GET /api/message/{commandId} ─────────────────────────────────────────

    suspend fun pollCommandStatus(device: DesktopDevice, commandId: String): CommandStatusResponse? =
        withContext(Dispatchers.IO) {
            try {
                val json = get(client, baseUrl(device) + "/api/message/$commandId")
                if (json != null) {
                    CommandStatusResponse(
                        commandId = json.optString("commandId", ""),
                        status = json.optString("status", ""),
                        response = json.optString("response", ""),
                        rawOutput = json.optString("rawOutput", ""),
                        error = json.optString("error", ""),
                        failureReason = json.optString("failureReason", ""),
                        modelId = json.optString("modelId", ""),
                        duration = if (json.has("duration") && !json.isNull("duration"))
                            json.optDouble("duration") else null,
                    )
                } else null
            } catch (e: Exception) {
                Log.w(TAG, "[API] pollCommandStatus error: ${e.message}")
                null
            }
        }

    // ─── POST /api/discovery/refresh ──────────────────────────────────────────

    suspend fun refreshDiscovery(device: DesktopDevice): Boolean =
        withContext(Dispatchers.IO) {
            try {
                val json = post(messageClient, baseUrl(device) + "/api/discovery/refresh", "")
                Log.i(TAG, "[API] POST /api/discovery/refresh -> $json")
                json != null
            } catch (e: Exception) {
                Log.w(TAG, "[API] refreshDiscovery error: ${e.message}")
                false
            }
        }

    // ─── HTTP helpers ─────────────────────────────────────────────────────────

    private fun baseUrl(device: DesktopDevice) = "http://${device.ip}:${device.port}"

    private fun get(client: OkHttpClient, url: String): JSONObject? {
        Log.d(TAG, "[API] GET $url")
        val request = Request.Builder().url(url).get().build()
        return try {
            val response = client.newCall(request).execute()
            val code = response.code
            val body = response.body?.string()
            Log.d(TAG, "[API] GET $url -> $code ${body?.take(200) ?: ""}")
            if (code == 200) {
                if (body != null) JSONObject(body) else null
            } else {
                Log.w(TAG, "[API] GET $url non-200: $code $body")
                null
            }
        } catch (e: Exception) {
            Log.w(TAG, "[API] GET failed: $url — ${e.message}")
            null
        }
    }

    private fun post(client: OkHttpClient, url: String, jsonBody: String): JSONObject? {
        Log.d(TAG, "[API] POST $url body=${jsonBody.take(100)}")
        val body = jsonBody.toRequestBody("application/json".toMediaType())
        val request = Request.Builder().url(url).post(body).build()
        return try {
            val response = client.newCall(request).execute()
            val code = response.code
            val responseBody = response.body?.string()
            Log.d(TAG, "[API] POST $url -> $code ${responseBody?.take(200) ?: ""}")
            if (code == 200) {
                if (responseBody != null) JSONObject(responseBody) else null
            } else {
                Log.w(TAG, "[API] POST $url non-200: $code $responseBody")
                null
            }
        } catch (e: Exception) {
            Log.w(TAG, "[API] POST failed: $url — ${e.message}")
            null
        }
    }

    private fun parseSessionBrief(obj: JSONObject) = com.brewping.android.model.SessionBrief(
        id = obj.optString("id", ""),
        agent = obj.optString("agent", ""),
        agentName = obj.optString("agentName", ""),
        status = obj.optString("status", ""),
    )

    /** Parse executable field: can be bool (iOS/Mac) or string path (Win). */
    private fun parseExecutable(obj: JSONObject): Boolean {
        val value = obj.opt("executable") ?: return false
        return when (value) {
            is Boolean -> value
            is String -> value.isNotEmpty()
            else -> false
        }
    }
}
