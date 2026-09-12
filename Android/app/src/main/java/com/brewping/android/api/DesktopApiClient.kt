package com.brewping.android.api

import android.util.Log
import com.brewping.android.model.AgentModelsResult
import com.brewping.android.model.AgentEntry
import com.brewping.android.model.AgentsResponse
import com.brewping.android.model.CommandStatusResponse
import com.brewping.android.model.ConversationResult
import com.brewping.android.model.ConversationSummary
import com.brewping.android.model.ConversationsResult
import com.brewping.android.model.DesktopDevice
import com.brewping.android.model.LifecycleResponse
import com.brewping.android.model.ModelOption
import com.brewping.android.model.StatusResponse
import com.brewping.android.model.SubmitResponse
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * HTTP client for the BrewPing Desktop API.
 * Matches the iOS ContentView's URLSession calls exactly.
 *
 * 鉴权（对齐 iOS `BrewPingHTTP.request`）：
 *  - 有 token 时所有请求带 `Authorization: Bearer <token>`；
 *  - 写操作（非 GET）额外带 `X-BrewPing-Timestamp`（秒，±120s）+ `X-BrewPing-Nonce`（一次性）。
 * `pairingStore == null`（单元测试桩）时不注入任何鉴权头。
 */
class DesktopApiClient(private val pairingStore: com.brewping.android.store.PairingStore? = null) {

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
                val json = get(client, baseUrl(device) + "/api/status", device) ?: return@withContext null
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
                val json = get(client, baseUrl(device) + "/api/agents", device) ?: return@withContext null
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
                val json = post(client, baseUrl(device) + "/api/agents/default", body, device)
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
                val json = post(sessionClient, baseUrl(device) + "/api/session/start", "", device)
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
                val json = post(messageClient, baseUrl(device) + "/api/session/stop", "", device)
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

    /**
     * 提交消息。`conversationId` 非空时显式指定目标对话（对齐 iOS 的
     * `submitter.submit(text:conversationId:)`）—— 不带则由桌面端按
     * 「显式对话 → agent → active」三层回落，可能落进别的对话，UI 层永远显式传。
     */
    suspend fun submitMessage(device: DesktopDevice, text: String, conversationId: String? = null): SubmitResponse? =
        withContext(Dispatchers.IO) {
            try {
                val body = JSONObject().put("text", text).apply {
                    if (!conversationId.isNullOrEmpty()) put("conversationId", conversationId)
                }.toString()
                val json = post(messageClient, baseUrl(device) + "/api/message", body, device)
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
                val json = get(client, baseUrl(device) + "/api/message/$commandId", device)
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
                val json = post(messageClient, baseUrl(device) + "/api/discovery/refresh", "", device)
                Log.i(TAG, "[API] POST /api/discovery/refresh -> $json")
                json != null
            } catch (e: Exception) {
                Log.w(TAG, "[API] refreshDiscovery error: ${e.message}")
                false
            }
        }

    // ─── HTTP helpers ─────────────────────────────────────────────────────────

    private fun baseUrl(device: DesktopDevice) = "http://${device.ip}:${device.port}"

    /**
     * 鉴权头注入（唯一出口，对齐 iOS `BrewPingHTTP.request`）：
     * 有 token → 所有请求带 `Authorization: Bearer`；写操作再加 timestamp + nonce。
     */
    private fun signed(builder: Request.Builder, device: DesktopDevice?, method: String): Request.Builder {
        if (device == null || pairingStore == null) return builder
        val token = pairingStore.token(device.id) ?: return builder
        builder.header("Authorization", "Bearer $token")
        if (!method.equals("GET", ignoreCase = true)) {
            builder.header("X-BrewPing-Timestamp", (System.currentTimeMillis() / 1000).toString())
            builder.header("X-BrewPing-Nonce", java.util.UUID.randomUUID().toString())
        }
        return builder
    }

    private fun get(client: OkHttpClient, url: String, device: DesktopDevice? = null): JSONObject? {
        Log.d(TAG, "[API] GET $url")
        val request = signed(Request.Builder().url(url).get(), device, "GET").build()
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

    private fun post(client: OkHttpClient, url: String, jsonBody: String, device: DesktopDevice? = null): JSONObject? {
        Log.d(TAG, "[API] POST $url body=${jsonBody.take(100)}")
        val body = jsonBody.toRequestBody("application/json".toMediaType())
        val request = signed(Request.Builder().url(url).post(body), device, "POST").build()
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

    // ─── Conversations（多对话，契约对齐 iOS ConversationStore）─────────────────
    //
    // 与旧 get/post 的区别：这里必须感知状态码 —— 404/501 表示「老版本桌面端
    // 没有该路由」，UI 要静默降级而不是报错（iOS 同款语义）。

    private data class RawResponse(val code: Int, val body: String?)

    private fun executeRaw(client: OkHttpClient, request: Request): RawResponse =
        try {
            client.newCall(request).execute().use { response ->
                RawResponse(response.code, response.body?.string())
            }
        } catch (e: Exception) {
            Log.w(TAG, "[API] raw request failed: ${e.message}")
            RawResponse(0, null)
        }

    private fun jsonBody(payload: JSONObject) =
        payload.toString().toRequestBody("application/json".toMediaType())

    /** GET /api/conversations?includeArchived=1 */
    suspend fun fetchConversations(device: DesktopDevice): ConversationsResult? =
        withContext(Dispatchers.IO) {
            val url = baseUrl(device) + "/api/conversations?includeArchived=1"
            val raw = executeRaw(client, signed(Request.Builder().url(url).get(), device, "GET").build())
            when {
                raw.code == 404 || raw.code == 501 -> ConversationsResult(conversations = null, unsupported = true)
                raw.code != 200 -> ConversationsResult(
                    conversations = null,
                    error = "Server error ${raw.code}",
                )
                raw.body == null -> ConversationsResult(conversations = null, error = "Empty response")
                else -> try {
                    val json = JSONObject(raw.body)
                    val arr = json.optJSONArray("conversations")
                    val list = mutableListOf<ConversationSummary>()
                    if (arr != null) {
                        for (i in 0 until arr.length()) {
                            list.add(parseConversationSummary(arr.getJSONObject(i)))
                        }
                    }
                    ConversationsResult(conversations = list)
                } catch (e: Exception) {
                    Log.w(TAG, "[API] fetchConversations parse error: ${e.message}")
                    ConversationsResult(conversations = null, error = "Malformed response")
                }
            }
        }

    /** GET /api/conversations/{id} */
    suspend fun fetchConversation(device: DesktopDevice, id: String): ConversationResult? =
        withContext(Dispatchers.IO) {
            val url = baseUrl(device) + "/api/conversations/$id"
            val raw = executeRaw(client, signed(Request.Builder().url(url).get(), device, "GET").build())
            when {
                raw.code == 404 || raw.code == 501 -> ConversationResult(detail = null, unsupported = true)
                raw.code != 200 -> ConversationResult(detail = null, error = "Server error ${raw.code}")
                raw.body == null -> ConversationResult(detail = null, error = "Empty response")
                else -> try {
                    val json = JSONObject(raw.body)
                    val conv = json.optJSONObject("conversation")
                    if (conv == null) {
                        ConversationResult(detail = null, error = "Conversation not found")
                    } else {
                        ConversationResult(detail = parseConversationDetail(conv))
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "[API] fetchConversation parse error: ${e.message}")
                    ConversationResult(detail = null, error = "Malformed response")
                }
            }
        }

    /** POST /api/conversations —— 新对话草稿的物化入口（Agent / 授权档位随创建固化）。 */
    suspend fun createConversation(
        device: DesktopDevice,
        agentId: String,
        approvalMode: String? = null,
    ): ConversationResult? =
        withContext(Dispatchers.IO) {
            val payload = JSONObject().put("agentId", agentId)
            if (!approvalMode.isNullOrEmpty()) payload.put("approvalMode", approvalMode)
            val request = signed(
                Request.Builder()
                    .url(baseUrl(device) + "/api/conversations")
                    .post(jsonBody(payload)),
                device, "POST",
            ).build()
            val raw = executeRaw(messageClient, request)
            parseConversationMutation(raw)
        }

    /**
     * PATCH /api/conversations/{id} —— 对话级设置（agentId / approvalMode /
     * modelId+modelProviderId / workdir / title / archived / pinned）。
     * 返回 null = 网络失败；error 字段承载服务端原因。
     */
    suspend fun patchConversation(device: DesktopDevice, id: String, payload: JSONObject): ConversationResult? =
        withContext(Dispatchers.IO) {
            val request = signed(
                Request.Builder()
                    .url(baseUrl(device) + "/api/conversations/$id")
                    .patch(jsonBody(payload)),
                device, "PATCH",
            ).build()
            val raw = executeRaw(messageClient, request)
            parseConversationMutation(raw)
        }

    // ─── POST /api/pair（配对码换长期 token；公开端点，码一次性 10 分钟有效）────

    suspend fun pairWithCode(device: DesktopDevice, code: String): com.brewping.android.model.PairResult? =
        withContext(Dispatchers.IO) {
            try {
                val payload = JSONObject().put("code", code.trim())
                val request = Request.Builder()
                    .url(baseUrl(device) + "/api/pair")
                    .post(payload.toString().toRequestBody("application/json".toMediaType()))
                    .build()
                val raw = executeRaw(messageClient, request)
                if (raw.body == null) {
                    com.brewping.android.model.PairResult(success = false, error = "Can't reach ${device.name}")
                } else try {
                    val json = JSONObject(raw.body)
                    com.brewping.android.model.PairResult(
                        success = json.optBoolean("success", false) && raw.code == 200,
                        token = json.optString("token", ""),
                        deviceId = json.optString("deviceId", ""),
                        deviceName = json.optString("deviceName", ""),
                        error = json.optString("error", "").ifEmpty { null },
                    )
                } catch (e: Exception) {
                    com.brewping.android.model.PairResult(success = false, error = "Malformed response")
                }
            } catch (e: Exception) {
                Log.w(TAG, "[API] pairWithCode error: ${e.message}")
                com.brewping.android.model.PairResult(success = false, error = "Pair failed: ${e.message}")
            }
        }

    // ─── 目录浏览（对话级 workdir 绑定用；契约对齐桌面端 folder_browser）────────

    /** GET /api/folders/roots —— home + 盘符（Windows）。 */
    suspend fun fetchFolderRoots(device: DesktopDevice): com.brewping.android.model.FolderRoots? =
        withContext(Dispatchers.IO) {
            val raw = executeRaw(
                client,
                signed(Request.Builder().url(baseUrl(device) + "/api/folders/roots").get(), device, "GET").build(),
            )
            if (raw.code != 200 || raw.body == null) return@withContext null
            try {
                val json = JSONObject(raw.body)
                val drives = mutableListOf<String>()
                json.optJSONArray("drives")?.let { arr ->
                    for (i in 0 until arr.length()) drives.add(arr.optString(i, ""))
                }
                com.brewping.android.model.FolderRoots(
                    platform = json.optString("platform", ""),
                    pathSeparator = json.optString("pathSeparator", "/"),
                    homeDir = json.optString("homeDir", ""),
                    drives = drives,
                )
            } catch (e: Exception) {
                Log.w(TAG, "[API] fetchFolderRoots parse error: ${e.message}")
                null
            }
        }

    /** GET /api/folders?path= —— 浏览目录（path 缺省 = 根）。 */
    suspend fun browseFolder(device: DesktopDevice, path: String?): com.brewping.android.model.FolderBrowse? =
        withContext(Dispatchers.IO) {
            val url = buildString {
                append(baseUrl(device)).append("/api/folders")
                if (!path.isNullOrEmpty()) {
                    append("?path=").append(java.net.URLEncoder.encode(path, "UTF-8"))
                }
            }
            val raw = executeRaw(
                client,
                signed(Request.Builder().url(url).get(), device, "GET").build(),
            )
            if (raw.code != 200 || raw.body == null) return@withContext null
            try {
                val json = JSONObject(raw.body)
                val entries = mutableListOf<com.brewping.android.model.FolderEntry>()
                json.optJSONArray("entries")?.let { arr ->
                    for (i in 0 until arr.length()) {
                        val e = arr.getJSONObject(i)
                        val name = e.optString("name", "")
                        val abs = e.optString("absolutePath", "")
                        // 只呈现目录：文件没有 hints，但也没有 name/abs 兜底；
                        // 服务端 browse 已只返回目录（folder_browser 过滤文件）。
                        if (name.isEmpty() || abs.isEmpty()) continue
                        entries.add(
                            com.brewping.android.model.FolderEntry(
                                name = name,
                                absolutePath = abs,
                                isUnreadable = e.optString("error", "").isNotEmpty(),
                            )
                        )
                    }
                }
                com.brewping.android.model.FolderBrowse(
                    path = json.optString("path", ""),
                    parentPath = if (json.has("parentPath") && !json.isNull("parentPath"))
                        json.optString("parentPath") else null,
                    entries = entries,
                )
            } catch (e: Exception) {
                Log.w(TAG, "[API] browseFolder parse error: ${e.message}")
                null
            }
        }

    private fun parseConversationMutation(raw: RawResponse): ConversationResult {
        return when {
            raw.code == 404 || raw.code == 501 -> ConversationResult(detail = null, unsupported = true)
            raw.code != 200 -> {
                val serverError = raw.body?.let { runCatching { JSONObject(it) }.getOrNull() }?.optString("error", "").orEmpty()
                ConversationResult(detail = null, error = serverError.ifEmpty { "Server error ${raw.code}" })
            }
            raw.body == null -> ConversationResult(detail = null, error = "Empty response")
            else -> try {
                val json = JSONObject(raw.body)
                val conv = json.optJSONObject("conversation")
                if (conv == null) {
                    ConversationResult(detail = null, error = "Malformed response")
                } else {
                    ConversationResult(detail = parseConversationDetail(conv))
                }
            } catch (e: Exception) {
                Log.w(TAG, "[API] conversation mutation parse error: ${e.message}")
                ConversationResult(detail = null, error = "Malformed response")
            }
        }
    }

    // ─── GET /api/agents/{agentId}/models（模型切换，契约对齐 iOS ModelStore）───

    suspend fun fetchAgentModels(device: DesktopDevice, agentId: String): AgentModelsResult? =
        withContext(Dispatchers.IO) {
            val url = baseUrl(device) + "/api/agents/$agentId/models"
            val raw = executeRaw(client, signed(Request.Builder().url(url).get(), device, "GET").build())
            when {
                raw.code == 404 || raw.code == 501 -> AgentModelsResult(unsupported = true)
                raw.code != 200 -> AgentModelsResult(error = "Server error ${raw.code}")
                raw.body == null -> AgentModelsResult(error = "Empty response")
                else -> try {
                    val json = JSONObject(raw.body)
                    val providers = json.optJSONArray("providers")
                    val models = mutableListOf<ModelOption>()
                    val seen = HashSet<String>()
                    if (providers != null) {
                        for (p in 0 until providers.length()) {
                            val provider = providers.getJSONObject(p)
                            val providerId = provider.optString("id", "")
                            val providerName = provider.optString("name", providerId)
                            val modelArr = provider.optJSONArray("models") ?: continue
                            for (m in 0 until modelArr.length()) {
                                val model = modelArr.getJSONObject(m)
                                val modelId = model.optString("id", "")
                                if (modelId.isEmpty()) continue
                                val key = "$providerId/$modelId"
                                if (!seen.add(key)) continue
                                models.add(
                                    ModelOption(
                                        id = modelId,
                                        name = model.optString("name", modelId),
                                        providerName = providerName,
                                        providerID = providerId,
                                        available = model.optBoolean("available", true),
                                    )
                                )
                            }
                        }
                    }
                    AgentModelsResult(
                        models = models,
                        activeModelID = json.optString("activeModelId", "").ifEmpty { null },
                        preferredModelID = json.optString("preferredModelId", "").ifEmpty { null },
                        preferredProviderID = json.optString("preferredProviderId", "").ifEmpty { null },
                    )
                } catch (e: Exception) {
                    Log.w(TAG, "[API] fetchAgentModels parse error: ${e.message}")
                    AgentModelsResult(error = "Malformed response")
                }
            }
        }

    /** POST /api/agents/models/default —— 模型与 providerId 成对提交（同名模型可来自多个厂商）。 */
    suspend fun setDefaultModel(device: DesktopDevice, agentId: String, modelId: String, providerId: String?): String? =
        withContext(Dispatchers.IO) {
            try {
                val payload = JSONObject()
                    .put("agentId", agentId)
                    .put("modelId", modelId)
                if (!providerId.isNullOrEmpty()) payload.put("providerId", providerId)
                val json = post(messageClient, baseUrl(device) + "/api/agents/models/default", payload.toString(), device)
                if (json == null) "Request failed"
                else if (!json.optBoolean("success", true)) json.optString("error", "Unknown error")
                else null
            } catch (e: Exception) {
                Log.w(TAG, "[API] setDefaultModel error: ${e.message}")
                "Switch failed: ${e.message}"
            }
        }

    // ─── Conversation JSON 解析（全部容错，对齐 iOS init(from decoder) 的默认值语义）──

    private fun optStringOrNull(obj: JSONObject, key: String): String? {
        if (!obj.has(key) || obj.isNull(key)) return null
        return obj.optString(key, "")
    }

    private fun parseConversationSummary(obj: JSONObject): ConversationSummary {
        // Windows / Mac 端键名是 camelCase；iOS 早期契约里没有 approvalMode /
        // modelProviderOverride —— 逐字段 opt，缺省回落，绝不让一条坏数据炸整表。
        return ConversationSummary(
            id = obj.optString("id", ""),
            agentId = obj.optString("agentId", ""),
            title = optStringOrNull(obj, "title"),
            titleSource = optStringOrNull(obj, "titleSource"),
            createdAtMs = obj.optDouble("createdAtMs", 0.0),
            updatedAtMs = obj.optDouble("updatedAtMs", 0.0),
            archived = obj.optBoolean("archived", false),
            isPinned = obj.optBoolean("isPinned", false),
            modelOverride = optStringOrNull(obj, "modelOverride"),
            modelProviderOverride = optStringOrNull(obj, "modelProviderOverride"),
            workdirOverride = optStringOrNull(obj, "workdirOverride"),
            approvalMode = optStringOrNull(obj, "approvalMode"),
            latestCommandId = optStringOrNull(obj, "latestCommandId"),
            messageCount = obj.optInt("messageCount", 0),
        )
    }

    private fun parseConversationDetail(obj: JSONObject): com.brewping.android.model.ConversationDetail {
        val entries = mutableListOf<com.brewping.android.model.TranscriptEntry>()
        val messages = obj.optJSONArray("messages")
        if (messages != null) {
            val convId = obj.optString("id", "")
            for (i in 0 until messages.length()) {
                val m = messages.getJSONObject(i)
                entries.add(
                    com.brewping.android.model.TranscriptEntry(
                        role = m.optString("role", "assistant"),
                        text = m.optString("text", ""),
                        source = optStringOrNull(m, "source"),
                        commandId = optStringOrNull(m, "commandId"),
                        createdAtMs = m.optDouble("createdAtMs", 0.0),
                        uid = "$convId-$i",
                    )
                )
            }
        }
        return com.brewping.android.model.ConversationDetail(
            id = obj.optString("id", ""),
            agentId = obj.optString("agentId", ""),
            title = optStringOrNull(obj, "title"),
            modelOverride = optStringOrNull(obj, "modelOverride"),
            modelProviderOverride = optStringOrNull(obj, "modelProviderOverride"),
            workdirOverride = optStringOrNull(obj, "workdirOverride"),
            approvalMode = optStringOrNull(obj, "approvalMode"),
            updatedAtMs = obj.optDouble("updatedAtMs", 0.0),
            messages = entries,
        )
    }
}
