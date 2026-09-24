package com.brewping.core.demo

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.roundToInt

/** 拦截结果：HTTP 状态码 + JSON 响应体。 */
class DemoResponse(val status: Int, val body: String)

/**
 * Demo 模式的后端模拟器（对齐 iOS `DemoBackend`）。
 *
 * 目的很窄：让**没有任何电脑、也没有任何硬件**的用户 / 商店审核员走通完整链路
 * （添加设备 → 看到 Agent 列表 → Start Session → 发送命令 → 看到结果 → 审批危险命令）。
 *
 * 实现方式是 OkHttp `Interceptor` 拦截（对齐 iOS 的 `URLProtocol` 方案）：
 * 只接管主机名为 [HOST] 的请求，真实设备完全不受影响，**所有调用方无需感知** ——
 * `DesktopApiClient` 里那 40 个方法一行都不用改。
 *
 * 响应形状与真实桌面端**逐字段同构**（camelCase、`success` 包裹、`pending_approval` 等），
 * 这样客户端的解析逻辑在 Demo 与真机上走的是同一条代码路径。
 */
class DemoBackend(
    private val strings: DemoStrings,
    /** `queued` 阶段时长（毫秒）。测试注入 0 即可立即进入终态，不必 sleep。 */
    private val queuedMs: Long = 1_200,
    /** `working` 阶段结束时刻（毫秒）。 */
    private val workingUntilMs: Long = 3_600,
) {

    companion object {
        /**
         * Demo 设备的固定主机名。`ManagedDevice.isDemo` 据此**派生**判定，
         * 而不是新增一个存储字段 —— 避免旧版本已写入 `SharedPreferences` 的 JSON
         * 因缺少新键而反序列化失败、把用户设备列表清空（iOS 同此约定）。
         */
        const val HOST = "demo.brewping.local"
        const val PORT = "8787"

        private const val SESSION_ID = "demo-session-0001"
        private const val DEMO_HOME = "C:\\Users\\Demo"

        /** 模拟的 Agent 列表（与 iOS `DemoBackend.agents` 逐字段一致）。 */
        private val AGENTS: List<JSONObject> = listOf(
            obj("id" to "opencode", "name" to "OpenCode", "installed" to true,
                "active" to false, "executable" to true, "version" to "0.4.2 (demo)"),
            obj("id" to "claude-code", "name" to "Claude Code", "installed" to true,
                "active" to true, "executable" to true, "version" to "1.9.0 (demo)"),
            obj("id" to "codex", "name" to "Codex CLI", "installed" to false,
                "active" to false, "executable" to false),
        )

        /** 每个 Agent 的可选模型（让「切换模型」在 Demo 里也看得见，而不是永远空的入口）。 */
        private val MODELS: Map<String, List<JSONObject>> = mapOf(
            "opencode" to listOf(
                obj("id" to "claude-sonnet-4", "name" to "Claude Sonnet 4", "available" to true),
                obj("id" to "gpt-5", "name" to "GPT-5", "available" to true),
                obj("id" to "glm-4.6", "name" to "GLM-4.6", "available" to true),
            ),
            "claude-code" to listOf(
                obj("id" to "sonnet", "name" to "Sonnet", "available" to true),
                obj("id" to "opus", "name" to "Opus", "available" to true),
                obj("id" to "haiku", "name" to "Haiku", "available" to true),
            ),
            "codex" to listOf(
                obj("id" to "gpt-5", "name" to "GPT-5", "available" to true),
                obj("id" to "o4-mini", "name" to "o4-mini", "available" to true),
            ),
        )

        /** 用可空值构造 JSONObject：null 统一落成 `JSONObject.NULL`。 */
        private fun obj(vararg pairs: Pair<String, Any?>): JSONObject {
            val o = JSONObject()
            for ((k, v) in pairs) o.put(k, v ?: JSONObject.NULL)
            return o
        }

        /**
         * Demo 用的简化危险检测（真实桌面端有完整正则 `DangerPattern`）。
         * 只覆盖常见几类，让「危险命令会先弹确认」在 Demo 里也能被演示 ——
         * 与 iOS `demoDangers` 同一份规则，两端行为一致。
         */
        fun dangers(text: String): List<JSONObject> {
            val lower = text.lowercase()
            val out = mutableListOf<JSONObject>()
            if (lower.contains("rm -rf") || lower.contains("rm -fr") || lower.contains("rm --recursive")) {
                out += obj("code" to "recursive_delete", "detail" to "recursive delete")
            }
            if (lower.contains("--force") || lower.contains("push -f")) {
                out += obj("code" to "force_push", "detail" to "git push --force")
            }
            if (lower.contains("sudo")) out += obj("code" to "sudo", "detail" to "sudo")
            if (lower.contains("chmod 777")) out += obj("code" to "chmod_777", "detail" to "chmod 777")
            if (lower.contains("git reset --hard")) {
                out += obj("code" to "git_reset_hard", "detail" to "git reset --hard")
            }
            if (lower.contains("| sh") || lower.contains("| bash")) {
                out += obj("code" to "pipe_to_shell", "detail" to "curl | sh")
            }
            return out
        }
    }

    // ─── 可变状态（Demo 会话内的「服务端」状态）───────────────────────────────

    private val lock = Any()
    private var sessionActive = false
    private var activeAgentId = "opencode"

    /** 授权档位（safe / askAll / auto），与桌面端 `ApprovalGate` 同构；Demo 默认 safe。 */
    private var approvalMode = "safe"

    private val commands = ConcurrentHashMap<String, DemoCommand>()
    private val pendingApprovals = ConcurrentHashMap<String, DemoApproval>()

    /** 用户在 Demo 里选过的模型 / 工作目录（按 Agent 分别记）。 */
    private val preferredModel = ConcurrentHashMap<String, String>()
    private val workdirs = ConcurrentHashMap<String, String>()

    private val createdConversations = mutableListOf<JSONObject>()
    private val conversationOverrides = ConcurrentHashMap<String, JSONObject>()

    /**
     * 已被删除的对话 id。
     *
     * 内置的两条对话是**静态数据**，若只从 `createdConversations` 里删，删完还会再出现 ——
     * Demo 里的「归档 → 删除」就变成假的（iOS 的 Demo 后端正是如此）。这里单独登记，
     * 让审核员能真的把这条流程走完。
     */
    private val deletedConversations = mutableSetOf<String>()

    private class DemoCommand(val text: String, val createdAtMs: Long)
    private class DemoApproval(val text: String, val reasons: List<JSONObject>)

    // ─── 入口 ─────────────────────────────────────────────────────────────────

    /**
     * 处理一条虚拟请求，返回 HTTP 状态码 + JSON 响应体。
     * `query` 是不含 `?` 的原始 query string（目录浏览的 `path` 参数靠它传进来）。
     */
    fun handle(method: String, path: String, query: String?, body: String): DemoResponse {
        val json = try {
            if (body.isBlank()) JSONObject() else JSONObject(body)
        } catch (_: Exception) {
            JSONObject()
        }
        val queryItems = parseQuery(query)

        when {
            method == "GET" && path == "/api/status" -> return ok(statusPayload())

            method == "GET" && path == "/api/agents" -> {
                // workdir 并进每个 agent（缺失 = 未设置），与真实桌面端 /api/agents 对齐。
                // `active` 必须按当前 activeAgentId **动态**算：静态表里那个标记在切换
                // Agent 后会变成过期值，而真实桌面端返回的永远是当前的。
                val active = activeAgent()
                val agents = JSONArray()
                for (a in AGENTS) {
                    val copy = JSONObject(a.toString())
                    val id = copy.optString("id")
                    copy.put("active", id == active)
                    copy.put("workdir", workdirs[id] ?: JSONObject.NULL)
                    agents.put(copy)
                }
                return ok(obj("agents" to agents, "defaultAgent" to active))
            }

            method == "POST" && path == "/api/agents/default" -> {
                val agentId = json.optString("agent", "opencode")
                setActiveAgent(agentId)
                return ok(obj("success" to true, "defaultAgent" to agentId))
            }

            method == "POST" && path == "/api/session/start" -> {
                synchronized(lock) { sessionActive = true }
                return ok(obj("success" to true, "sessionId" to SESSION_ID, "status" to "running"))
            }

            method == "POST" && path == "/api/session/stop" -> {
                synchronized(lock) { sessionActive = false }
                return ok(obj("success" to true, "status" to "stopped"))
            }

            method == "POST" && path == "/api/message" -> {
                val text = json.optString("text", "").trim()
                if (text.isEmpty()) {
                    return DemoResponse(400, obj("success" to false, "error" to "text is empty").toString())
                }
                // 授权门卫（与桌面端 ApprovalGate 同构）：
                //   safe：命中危险 → 挂起；askAll：一律挂起；auto：直接执行。
                val mode = currentMode()
                val found = dangers(text)
                if (mode == "askAll" || (mode != "auto" && found.isNotEmpty())) {
                    val approvalId = "apv-demo-${UUID.randomUUID()}"
                    pendingApprovals[approvalId] = DemoApproval(text, found)
                    val reasons = JSONArray(); found.forEach { reasons.put(it) }
                    return ok(
                        obj(
                            "success" to true,
                            "status" to "pending_approval",
                            "approval" to obj(
                                "id" to approvalId,
                                "text" to text,
                                "reasons" to reasons,
                            ),
                        )
                    )
                }
                val commandId = newCommandId()
                commands[commandId] = DemoCommand(text, System.currentTimeMillis())
                return ok(
                    obj(
                        "success" to true, "commandId" to commandId,
                        "sessionId" to SESSION_ID, "status" to "queued",
                    )
                )
            }
        }

        if (method == "GET" && path.startsWith("/api/message/")) {
            return commandStatus(path.removePrefix("/api/message/"))
        }
        if (path == "/api/approvals/mode") {
            if (method == "POST" && json.has("mode")) {
                synchronized(lock) { approvalMode = json.optString("mode", approvalMode) }
            }
            return ok(obj("success" to true, "mode" to currentMode()))
        }
        if (method == "POST" && path.startsWith("/api/approvals/")) {
            val id = path.removePrefix("/api/approvals/")
            val action = json.optString("action", "")
            if (action == "deny") {
                pendingApprovals.remove(id)
                return ok(obj("success" to true, "status" to "denied"))
            }
            val approval = pendingApprovals.remove(id)
                ?: return DemoResponse(
                    404,
                    obj("success" to false, "error" to "unknown or expired approval").toString(),
                )
            val commandId = newCommandId()
            commands[commandId] = DemoCommand(approval.text, System.currentTimeMillis())
            return ok(
                obj(
                    "success" to true, "commandId" to commandId,
                    "sessionId" to SESSION_ID, "status" to "queued",
                )
            )
        }
        if (method == "POST" && path.startsWith("/api/agents/") && path.endsWith("/switch")) {
            val agentId = path.removePrefix("/api/agents/").removeSuffix("/switch")
            setActiveAgent(agentId)
            return ok(obj("success" to true, "activeAgent" to agentId))
        }
        if (method == "GET" && path.startsWith("/api/agents/") && path.endsWith("/models")) {
            val agentId = path.removePrefix("/api/agents/").removeSuffix("/models")
            return ok(modelsPayload(agentId))
        }
        if (method == "POST" && path == "/api/agents/models/default") {
            val agentId = json.optString("agentId").ifEmpty { activeAgent() }
            if (json.has("modelId") && !json.isNull("modelId")) {
                preferredModel[agentId] = json.optString("modelId")
            }
            return ok(
                obj(
                    "success" to true, "agentId" to agentId,
                    "modelId" to (preferredModel[agentId] ?: JSONObject.NULL),
                )
            )
        }

        // ── 目录浏览（与 Windows 端 /api/folders* 同构，Demo 里也能走通「选工作目录」）──
        if (method == "GET" && path == "/api/folders/roots") {
            val drives = JSONArray().put("C:\\").put("D:\\")
            return ok(
                obj(
                    "platform" to "windows", "pathSeparator" to "\\",
                    "homeDir" to DEMO_HOME, "drives" to drives,
                )
            )
        }
        if (method == "GET" && path == "/api/folders") {
            return ok(browsePayload(queryItems))
        }
        if (method == "POST" && path == "/api/agents/workdir") {
            val agentId = json.optString("agentId", "")
            if (agentId.isEmpty()) {
                return DemoResponse(
                    400,
                    obj(
                        "success" to false,
                        "error" to "expected JSON body {\"agentId\": \"...\", \"path\": \"...\" | null}",
                    ).toString(),
                )
            }
            if (agentId == "opencode") {
                return DemoResponse(
                    400,
                    obj("success" to false, "error" to "opencode does not support workdir yet").toString(),
                )
            }
            val workdir = if (json.has("path") && !json.isNull("path")) json.optString("path") else null
            if (!workdir.isNullOrEmpty()) workdirs[agentId] = workdir else workdirs.remove(agentId)
            return ok(
                obj(
                    "success" to true, "agentId" to agentId,
                    "workdir" to (workdirs[agentId] ?: JSONObject.NULL),
                )
            )
        }

        // ── 对话（多对话管理，与桌面端 /api/conversations 同构）──
        if (method == "POST" && path == "/api/conversations") {
            val agentId = json.optString("agentId").ifEmpty { "opencode" }
            if (AGENTS.none { it.optString("id") == agentId }) {
                return DemoResponse(
                    400,
                    obj("success" to false, "error" to "unknown agent: $agentId").toString(),
                )
            }
            val now = System.currentTimeMillis()
            val id = "demo-" + UUID.randomUUID().toString().take(8)
            val approval = if (json.has("approvalMode") && !json.isNull("approvalMode")) {
                json.optString("approvalMode")
            } else {
                null
            }
            val conv = obj(
                "id" to id, "agentId" to agentId, "title" to null, "titleSource" to null,
                "createdAtMs" to now, "updatedAtMs" to now, "archived" to false, "isPinned" to false,
                "modelOverride" to null, "modelProviderOverride" to null, "workdirOverride" to null,
                "approvalMode" to approval, "latestCommandId" to null, "messageCount" to 0,
            )
            synchronized(lock) { createdConversations.add(conv) }
            return ok(obj("success" to true, "conversation" to conv))
        }

        if (method == "PATCH" && path.startsWith("/api/conversations/")) {
            val id = path.removePrefix("/api/conversations/")
            if (demoConversations().none { it.optString("id") == id }) {
                return DemoResponse(
                    404,
                    obj("success" to false, "error" to "conversation not found").toString(),
                )
            }
            val overrides = JSONObject(conversationOverrides[id]?.toString() ?: "{}")
            // 切 Agent：与桌面端一致，自动清除该对话的模型覆盖
            if (json.has("agentId") && json.optString("agentId").isNotEmpty()) {
                val agentId = json.optString("agentId")
                if (AGENTS.none { it.optString("id") == agentId }) {
                    return DemoResponse(
                        400,
                        obj("success" to false, "error" to "unknown agent: $agentId").toString(),
                    )
                }
                overrides.put("agentId", agentId)
                overrides.put("modelOverride", JSONObject.NULL)
                overrides.put("modelProviderOverride", JSONObject.NULL)
            }
            if (json.has("approvalMode")) {
                val mode = json.optString("approvalMode")
                overrides.put("approvalMode", if (mode.isEmpty()) JSONObject.NULL else mode)
            }
            if (json.has("modelId")) {
                val modelId = json.optString("modelId")
                val provider = json.optString("modelProviderId")
                overrides.put("modelOverride", if (modelId.isEmpty()) JSONObject.NULL else modelId)
                overrides.put(
                    "modelProviderOverride",
                    if (modelId.isEmpty() || provider.isEmpty()) JSONObject.NULL else provider,
                )
            }
            if (json.has("workdir")) {
                val workdir = json.optString("workdir")
                overrides.put("workdirOverride", if (workdir.isEmpty()) JSONObject.NULL else workdir)
            }
            if (json.has("pinned")) overrides.put("pinned", json.optBoolean("pinned"))
            if (json.has("archived")) overrides.put("archived", json.optBoolean("archived"))
            conversationOverrides[id] = overrides
            val updated = demoConversations().first { it.optString("id") == id }
            return ok(obj("success" to true, "conversation" to updated))
        }

        if (method == "GET" && path == "/api/conversations") {
            val arr = JSONArray(); demoConversations().forEach { arr.put(it) }
            return ok(obj("success" to true, "conversations" to arr))
        }
        if (method == "DELETE" && path.startsWith("/api/conversations/")) {
            // 与真实桌面端同语义：仅归档态可删，否则 409。
            // ⚠️ 必须查**合并后**的视图 —— 归档是经 PATCH 写进 `conversationOverrides` 的，
            // 只看 baseDemoConversations() 会永远读到 archived=false，导致「归档了也删不掉」
            // 而一直 409（iOS 的 Demo 后端有这个缺陷，这里不复刻）。
            val id = path.removePrefix("/api/conversations/")
            val archived = demoConversations()
                .firstOrNull { it.optString("id") == id }
                ?.optBoolean("archived")
                ?: false
            if (!archived) {
                return DemoResponse(
                    409,
                    obj(
                        "success" to false,
                        "error" to "conversation must be archived before delete",
                    ).toString(),
                )
            }
            synchronized(lock) {
                createdConversations.removeAll { it.optString("id") == id }
                deletedConversations.add(id)
            }
            conversationOverrides.remove(id)
            return ok(obj("success" to true))
        }
        if (method == "GET" && path.startsWith("/api/conversations/")) {
            val id = path.removePrefix("/api/conversations/")
            val conv = demoConversations().firstOrNull { it.optString("id") == id }
                ?: return DemoResponse(
                    404,
                    obj("success" to false, "error" to "conversation not found").toString(),
                )
            val detail = JSONObject(conv.toString())
            detail.put("messages", JSONArray().also { arr -> demoMessages(id).forEach { arr.put(it) } })
            return ok(obj("success" to true, "conversation" to detail))
        }

        return DemoResponse(404, obj("success" to false, "error" to "not found").toString())
    }

    // ─── 载荷 ─────────────────────────────────────────────────────────────────

    private fun statusPayload(): JSONObject {
        val active = activeAgent()
        val running = synchronized(lock) { sessionActive }
        return obj(
            "status" to "online",
            "host" to strings.hostLabel,
            "defaultAgent" to active,
            "activeAgent" to active,
            "session" to if (running) {
                obj("id" to SESSION_ID, "agent" to active, "agentName" to displayName(active), "status" to "running")
            } else {
                null
            },
        )
    }

    /** `GET /api/agents/<id>/models` 的响应，结构与桌面端一致（providers → models 两层）。 */
    private fun modelsPayload(agentId: String): JSONObject {
        val list = MODELS[agentId] ?: emptyList()
        val preferred = preferredModel[agentId]
        val firstId = list.firstOrNull()?.optString("id")
        val marked = JSONArray()
        for (m in list) {
            val id = m.optString("id")
            val copy = JSONObject(m.toString())
            copy.put("isActive", id == preferred || (preferred == null && id == firstId))
            copy.put("isDefault", id == preferred)
            marked.put(copy)
        }
        return obj(
            "agentId" to agentId,
            "providers" to JSONArray().put(
                obj("id" to "demo", "name" to "Demo Provider", "models" to marked)
            ),
            "activeModelId" to (firstId ?: JSONObject.NULL),
            "preferredModelId" to (preferred ?: JSONObject.NULL),
        )
    }

    /** 命令状态随时间推进，让 UI 能真实地走过 queued → working → completed。 */
    private fun commandStatus(id: String): DemoResponse {
        val command = commands[id]
            ?: return DemoResponse(
                404,
                obj("success" to false, "error" to "unknown commandId").toString(),
            )
        val elapsed = (System.currentTimeMillis() - command.createdAtMs).toDouble()
        val payload = obj("commandId" to id, "sessionId" to SESSION_ID)
        when {
            elapsed < queuedMs -> payload.put("status", "queued")
            elapsed < workingUntilMs -> payload.put("status", "working")
            else -> {
                // 错误路径也要能被看到：命令含 "fail" → failed，走与真实桌面端同形的
                // 失败载荷（error + failureReason）。
                if (command.text.lowercase().contains("fail")) {
                    payload.put("status", "failed")
                    payload.put("duration", (elapsed / 1000.0 * 10).roundToInt() / 10.0)
                    payload.put("error", strings.commandFailed)
                    payload.put("failureReason", "timeout")
                } else {
                    payload.put("status", "completed")
                    payload.put("duration", (elapsed / 1000.0 * 10).roundToInt() / 10.0)
                    payload.put("modelId", "demo-model")
                    payload.put("response", String.format(strings.commandResponse, command.text))
                }
            }
        }
        return ok(payload)
    }

    /** Demo 对话列表（两条内置 + 用户新建的，减去已删除的），并套用对话级设置覆盖。 */
    private fun demoConversations(): List<JSONObject> {
        val created = synchronized(lock) { createdConversations.toList() }
        val deleted = synchronized(lock) { deletedConversations.toSet() }
        val all = baseDemoConversations().toMutableList()
        all.addAll(created)
        val visible = all.filter { it.optString("id") !in deleted }
        if (conversationOverrides.isEmpty()) return visible
        return visible.map { conv ->
            val ov = conversationOverrides[conv.optString("id")] ?: return@map conv
            val merged = JSONObject(conv.toString())
            val keys = ov.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                merged.put(k, ov.get(k))
            }
            merged
        }
    }

    /** 内置两条对话：一条绑定工作目录、一条未绑定 —— 覆盖列表页的两种分组形态。 */
    private fun baseDemoConversations(): List<JSONObject> {
        val now = System.currentTimeMillis()
        return listOf(
            obj(
                "id" to "demo-cakewalk", "agentId" to "opencode",
                "title" to strings.conversationTitleBound, "titleSource" to "firstMessage",
                "createdAtMs" to now - 3_600_000, "updatedAtMs" to now - 1_200_000,
                "archived" to false, "isPinned" to false,
                "modelOverride" to null, "modelProviderOverride" to null,
                "workdirOverride" to "D:\\cakewalk", "approvalMode" to null,
                "latestCommandId" to null, "messageCount" to 3,
            ),
            obj(
                "id" to "demo-unbound", "agentId" to "opencode",
                "title" to strings.conversationTitleUnbound, "titleSource" to "firstMessage",
                "createdAtMs" to now - 7_200_000, "updatedAtMs" to now - 6_000_000,
                "archived" to false, "isPinned" to false,
                "modelOverride" to null, "modelProviderOverride" to null,
                "workdirOverride" to null, "approvalMode" to null,
                "latestCommandId" to null, "messageCount" to 3,
            ),
        )
    }

    /** Demo 转录（与真实契约同形：role / text / source / commandId / createdAtMs）。 */
    private fun demoMessages(id: String): List<JSONObject> {
        val now = System.currentTimeMillis()
        val bound = id == "demo-cakewalk"
        val userText = if (bound) strings.conversationTitleBound else strings.conversationTitleUnbound
        return listOf(
            obj(
                "role" to "system",
                "text" to if (bound) strings.systemPromptBound else strings.systemPromptUnbound,
                "source" to null, "commandId" to null, "createdAtMs" to now - 300_000,
            ),
            obj(
                "role" to "user", "text" to userText, "source" to "android",
                "commandId" to null, "createdAtMs" to now - 290_000,
            ),
            obj(
                "role" to "assistant",
                "text" to if (bound) strings.replyBound else strings.replyUnbound,
                "source" to null, "commandId" to null, "createdAtMs" to now - 280_000,
            ),
        )
    }

    /**
     * 模拟一层数据源：home（含盘符根）→ projects；projects → 三个项目
     * （其一含 .git 徽章、其一不可读置灰）；其余为空。
     * 覆盖 UI 需要分辨的三种形态。
     */
    private fun browsePayload(queryItems: Map<String, String>): JSONObject {
        val raw = queryItems["path"].orEmpty()
        val path = raw.ifEmpty { DEMO_HOME }
        val showHidden = queryItems["hidden"] in setOf("1", "true", "TRUE", "yes")

        fun entry(name: String, parent: String, git: Boolean = false, unreadable: Boolean = false): JSONObject {
            val e = obj(
                "name" to name,
                "absolutePath" to "$parent\\$name",
                "isSymlink" to false,
                "hidden" to false,
            )
            if (git) e.put("hints", obj("git" to true))
            if (unreadable) e.put("error", "unreadable")
            return e
        }

        val target = if (path.endsWith("\\")) path.dropLast(1) else path
        val idx = target.lastIndexOf('\\')
        val parent = if (idx < 0 || target.substring(0, idx).length <= 2) null else target.substring(0, idx)

        val entries = when {
            target == "C:" || target == "C:\\" || target == "D:" || target == "D:\\" || target == DEMO_HOME ->
                listOf(entry("projects", target), entry(".hidden-assets", target))
            target.endsWith("\\projects") -> listOf(
                entry("brewping-ios", target, git = true),
                entry("legacy-app", target),
                entry("locked-archive", target, unreadable = true),
            )
            else -> emptyList()
        }

        // 隐藏目录默认过滤（与真实服务端一致）
        val visible = if (showHidden) entries else entries.filter { !it.optString("name").startsWith(".") }
        val arr = JSONArray(); visible.forEach { arr.put(it) }
        return obj(
            "path" to target,
            "parentPath" to (parent ?: JSONObject.NULL),
            "entries" to arr,
            "truncated" to false,
        )
    }

    // ─── 状态辅助 ─────────────────────────────────────────────────────────────

    private fun newCommandId() = "demo-cmd-${System.currentTimeMillis()}"

    private fun currentMode(): String = synchronized(lock) { approvalMode }

    private fun activeAgent(): String = synchronized(lock) { activeAgentId }

    private fun setActiveAgent(id: String) {
        synchronized(lock) { activeAgentId = id }
    }

    private fun displayName(id: String): String =
        AGENTS.firstOrNull { it.optString("id") == id }?.optString("name") ?: id

    private fun ok(payload: JSONObject) = DemoResponse(200, payload.toString())

    /** 解析原始 query string（`a=1&b=2`），只做 percent-decode，不抛错。 */
    private fun parseQuery(query: String?): Map<String, String> {
        if (query.isNullOrEmpty()) return emptyMap()
        val out = mutableMapOf<String, String>()
        for (pair in query.split("&")) {
            if (pair.isEmpty()) continue
            val idx = pair.indexOf('=')
            val key = if (idx < 0) pair else pair.substring(0, idx)
            val value = if (idx < 0) "" else pair.substring(idx + 1)
            out[java.net.URLDecoder.decode(key, "UTF-8")] =
                java.net.URLDecoder.decode(value, "UTF-8")
        }
        return out
    }
}
