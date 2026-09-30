package com.brewping.core

import com.brewping.core.demo.DemoBackend
import com.brewping.core.demo.DemoResponse
import com.brewping.core.demo.DemoStrings
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Demo 后端（`DemoBackend`）的端点覆盖测试。
 *
 * 对齐 iOS `DemoBackend` 覆盖的能力面：status / agents / session / models / message /
 * approvals（含三档）/ conversations（含 PATCH 与删除语义）/ folders / workdir，
 * 外加「时间推进」的命令状态机。
 *
 * 阈值注入 0 → 命令提交后**立即**进入终态，测试无需 sleep（iOS 侧靠真实等待）。
 */
class DemoBackendTest {

    private fun strings() = DemoStrings(
        hostLabel = "Demo Mac (Simulated)",
        commandResponse = "%1\$s — simulated",
        commandFailed = "Command failed (simulated).",
        conversationTitleBound = "Which directory am I in?",
        conversationTitleUnbound = "Hello",
        systemPromptBound = "Working directory: D:\\cakewalk",
        systemPromptUnbound = "No working directory bound.",
        replyBound = "reply bound",
        replyUnbound = "reply unbound",
    )

    /** `immediate=true` → 命令提交后立即进入 completed / failed。 */
    private fun backend(immediate: Boolean = false) = DemoBackend(
        strings = strings(),
        queuedMs = if (immediate) 0 else 1_200,
        workingUntilMs = if (immediate) 0 else 3_600,
    )

    private fun DemoBackend.get(path: String, query: String? = null) = handle("GET", path, query, "")
    private fun DemoBackend.post(path: String, body: String = "{}") = handle("POST", path, null, body)
    private fun DemoBackend.patch(path: String, body: String) = handle("PATCH", path, null, body)
    private fun DemoBackend.delete(path: String) = handle("DELETE", path, null, "")

    private fun json(res: DemoResponse) = JSONObject(res.body)

    // ─── status / agents / session ────────────────────────────────────────────

    @Test
    fun `status 返回在线状态与默认 Agent，且未起会话时 session 为 null`() {
        val res = backend().get("/api/status")
        assertEquals(200, res.status)
        val body = json(res)
        assertEquals("online", body.optString("status"))
        assertEquals("opencode", body.optString("defaultAgent"))
        assertEquals("Demo Mac (Simulated)", body.optString("host"))
        assertTrue("未起会话时 session 应为 null", body.isNull("session"))
    }

    @Test
    fun `agents 列出三个 Agent，active 动态标注，且未绑定时 workdir 为 null`() {
        val body = json(backend().get("/api/agents"))
        val agents = body.getJSONArray("agents")
        assertEquals(3, agents.length())
        assertEquals("opencode", agents.getJSONObject(0).optString("id"))
        assertEquals("claude-code", agents.getJSONObject(1).optString("id"))
        assertTrue(agents.getJSONObject(1).optBoolean("installed"))
        assertFalse("codex 在 Demo 里是未安装状态", agents.getJSONObject(2).optBoolean("installed"))
        // active 必须与 defaultAgent 一致（按当前 Agent 动态算，而不是静态表里的过期标记）
        assertEquals("opencode", body.optString("defaultAgent"))
        assertTrue(agents.getJSONObject(0).optBoolean("active"))
        assertFalse(agents.getJSONObject(1).optBoolean("active"))
        assertTrue(agents.getJSONObject(0).isNull("workdir"))
    }

    @Test
    fun `session start 与 stop 反映到 status 上`() {
        val backend = backend()
        backend.post("/api/session/start")
        val started = json(backend.get("/api/status"))
        assertFalse(started.isNull("session"))
        assertEquals("running", started.getJSONObject("session").optString("status"))

        backend.post("/api/session/stop")
        assertTrue("stop 后 session 应回到 null", json(backend.get("/api/status")).isNull("session"))
    }

    @Test
    fun `agents default 可切换默认 Agent`() {
        val backend = backend()
        val res = backend.post("/api/agents/default", """{"agent":"codex"}""")
        assertEquals(200, res.status)
        assertEquals("codex", json(res).optString("defaultAgent"))
        assertEquals("codex", json(backend.get("/api/status")).optString("defaultAgent"))
    }

    // ─── models ───────────────────────────────────────────────────────────────

    @Test
    fun `models 返回 providers 两层结构，并把第一个模型标为 active`() {
        val body = json(backend().get("/api/agents/opencode/models"))
        assertEquals("opencode", body.optString("agentId"))
        val providers = body.getJSONArray("providers")
        assertEquals(1, providers.length())
        val models = providers.getJSONObject(0).getJSONArray("models")
        assertEquals(3, models.length())
        assertTrue("默认把第一个模型标为 active", models.getJSONObject(0).optBoolean("isActive"))
        assertFalse(models.getJSONObject(1).optBoolean("isActive"))
    }

    @Test
    fun `agents models default 记住选择并影响后续 models 的 active 标记`() {
        val backend = backend()
        val res = backend.post("/api/agents/models/default", """{"agentId":"opencode","modelId":"gpt-5"}""")
        assertEquals(200, res.status)
        assertEquals("gpt-5", json(res).optString("modelId"))

        val models = json(backend.get("/api/agents/opencode/models"))
            .getJSONArray("providers").getJSONObject(0).getJSONArray("models")
        val gpt5 = (0 until models.length())
            .map { models.getJSONObject(it) }
            .first { it.optString("id") == "gpt-5" }
        assertTrue("被选中的模型应标为 isDefault", gpt5.optBoolean("isDefault"))
        assertEquals("gpt-5", json(backend.get("/api/agents/opencode/models")).optString("preferredModelId"))
    }

    // ─── message / approvals ──────────────────────────────────────────────────

    @Test
    fun `普通命令在 safe 档位下直接排队`() {
        val res = backend().post("/api/message", """{"text":"list the files"}""")
        assertEquals(200, res.status)
        val body = json(res)
        assertTrue(body.optBoolean("success"))
        assertEquals("queued", body.optString("status"))
        assertTrue(body.optString("commandId").startsWith("demo-cmd-"))
    }

    @Test
    fun `空命令返回 400`() {
        val res = backend().post("/api/message", """{"text":"   "}""")
        assertEquals(400, res.status)
        assertEquals("text is empty", json(res).optString("error"))
    }

    @Test
    fun `危险命令在 safe 档位下挂起审批，且不改动会话`() {
        val res = backend().post("/api/message", """{"text":"rm -rf /tmp/x"}""")
        assertEquals(200, res.status)
        val body = json(res)
        assertEquals("pending_approval", body.optString("status"))
        val approval = body.getJSONObject("approval")
        assertTrue(approval.optString("id").startsWith("apv-demo-"))
        val reasons = approval.getJSONArray("reasons")
        assertEquals(1, reasons.length())
        assertEquals("recursive_delete", reasons.getJSONObject(0).optString("code"))
    }

    @Test
    fun `批准挂起的命令会产出可轮询的 commandId`() {
        val backend = backend()
        val approvalId = json(backend.post("/api/message", """{"text":"sudo reboot"}"""))
            .getJSONObject("approval").optString("id")

        val res = backend.post("/api/approvals/$approvalId", """{"action":"approve"}""")
        assertEquals(200, res.status)
        val commandId = json(res).optString("commandId")
        assertTrue(commandId.startsWith("demo-cmd-"))
        assertEquals(200, backend.get("/api/message/$commandId").status)
    }

    @Test
    fun `拒绝挂起的命令返回 denied 且不再有可执行命令`() {
        val backend = backend()
        val approvalId = json(backend.post("/api/message", """{"text":"git reset --hard"}"""))
            .getJSONObject("approval").optString("id")
        val res = backend.post("/api/approvals/$approvalId", """{"action":"deny"}""")
        assertEquals(200, res.status)
        assertEquals("denied", json(res).optString("status"))
    }

    @Test
    fun `未知审批 id 返回 404`() {
        assertEquals(404, backend().post("/api/approvals/nope", """{"action":"approve"}""").status)
    }

    @Test
    fun `auto 档位下危险命令不再挂起`() {
        val backend = backend()
        assertEquals("safe", json(backend.get("/api/approvals/mode")).optString("mode"))
        backend.post("/api/approvals/mode", """{"mode":"auto"}""")
        val res = backend.post("/api/message", """{"text":"rm -rf /tmp/x"}""")
        assertEquals("queued", json(res).optString("status"))
    }

    @Test
    fun `askAll 档位下普通命令也要确认`() {
        val backend = backend()
        backend.post("/api/approvals/mode", """{"mode":"askAll"}""")
        val body = json(backend.post("/api/message", """{"text":"ls"}"""))
        assertEquals("pending_approval", body.optString("status"))
    }

    // ─── 命令状态机（时间推进）────────────────────────────────────────────────

    @Test
    fun `命令按时间推进：queued 可见`() {
        val backend = backend()          // 阈值 1200 / 3600 ms
        val commandId = json(backend.post("/api/message", """{"text":"hi"}""")).optString("commandId")
        assertEquals("queued", json(backend.get("/api/message/$commandId")).optString("status"))
    }

    @Test
    fun `命令终态：成功路径返回 response`() {
        val backend = backend(immediate = true)
        val commandId = json(backend.post("/api/message", """{"text":"say hi"}""")).optString("commandId")
        val body = json(backend.get("/api/message/$commandId"))
        assertEquals("completed", body.optString("status"))
        assertTrue("回复模板应带上原命令", body.optString("response").contains("say hi"))
        assertEquals("demo-model", body.optString("modelId"))
    }

    @Test
    fun `命令终态：含 fail 的命令走失败路径`() {
        val backend = backend(immediate = true)
        val commandId = json(backend.post("/api/message", """{"text":"please fail"}""")).optString("commandId")
        val body = json(backend.get("/api/message/$commandId"))
        assertEquals("failed", body.optString("status"))
        assertEquals("Command failed (simulated).", body.optString("error"))
        assertEquals("timeout", body.optString("failureReason"))
    }

    @Test
    fun `未知 commandId 返回 404`() {
        assertEquals(404, backend().get("/api/message/nope").status)
    }

    // ─── conversations ────────────────────────────────────────────────────────

    @Test
    fun `内置两条对话：一条绑定目录、一条未绑定`() {
        val arr = json(backend().get("/api/conversations")).getJSONArray("conversations")
        assertEquals(2, arr.length())
        assertEquals("demo-cakewalk", arr.getJSONObject(0).optString("id"))
        assertEquals("D:\\cakewalk", arr.getJSONObject(0).optString("workdirOverride"))
        assertTrue(arr.getJSONObject(1).isNull("workdirOverride"))
    }

    @Test
    fun `对话详情带转录，三条且角色齐全`() {
        val conv = json(backend().get("/api/conversations/demo-cakewalk")).getJSONObject("conversation")
        val messages = conv.getJSONArray("messages")
        assertEquals(3, messages.length())
        assertEquals("system", messages.getJSONObject(0).optString("role"))
        assertEquals("user", messages.getJSONObject(1).optString("role"))
        assertEquals("assistant", messages.getJSONObject(2).optString("role"))
    }

    @Test
    fun `未知对话返回 404`() {
        assertEquals(404, backend().get("/api/conversations/nope").status)
    }

    @Test
    fun `新建对话会出现在列表里，未知 agent 返回 400`() {
        val backend = backend()
        backend.post("/api/conversations", """{"agentId":"claude-code"}""")
        assertEquals(3, json(backend.get("/api/conversations")).getJSONArray("conversations").length())
        assertEquals(400, backend.post("/api/conversations", """{"agentId":"nope"}""").status)
    }

    @Test
    fun `PATCH 可置顶归档，切 Agent 会清掉模型覆盖`() {
        val backend = backend()
        backend.patch("/api/conversations/demo-unbound", """{"pinned":true,"modelId":"gpt-5","modelProviderId":"demo"}""")
        var conv = json(backend.get("/api/conversations/demo-unbound")).getJSONObject("conversation")
        assertTrue(conv.optBoolean("pinned"))
        assertEquals("gpt-5", conv.optString("modelOverride"))

        backend.patch("/api/conversations/demo-unbound", """{"agentId":"codex"}""")
        conv = json(backend.get("/api/conversations/demo-unbound")).getJSONObject("conversation")
        assertEquals("codex", conv.optString("agentId"))
        assertTrue("切 Agent 后模型覆盖应被清空", conv.isNull("modelOverride"))
    }

    @Test
    fun `未归档的对话不可删除（409），归档后可删`() {
        val backend = backend()
        assertEquals(409, backend.delete("/api/conversations/demo-cakewalk").status)
        backend.patch("/api/conversations/demo-cakewalk", """{"archived":true}""")
        assertEquals(200, backend.delete("/api/conversations/demo-cakewalk").status)
        assertEquals(1, json(backend.get("/api/conversations")).getJSONArray("conversations").length())
    }

    // ─── folders / workdir ────────────────────────────────────────────────────

    @Test
    fun `folders roots 返回 Windows 形态的平台信息`() {
        val body = json(backend().get("/api/folders/roots"))
        assertEquals("windows", body.optString("platform"))
        assertEquals("C:\\Users\\Demo", body.optString("homeDir"))
        assertEquals(2, body.getJSONArray("drives").length())
    }

    @Test
    fun `浏览默认过滤隐藏目录，显式请求时才出现`() {
        val backend = backend()
        val default = json(backend.get("/api/folders"))
        assertEquals(1, default.getJSONArray("entries").length())
        assertEquals("projects", default.getJSONArray("entries").getJSONObject(0).optString("name"))

        val shown = json(backend.get("/api/folders", "hidden=1"))
        assertEquals(2, shown.getJSONArray("entries").length())
    }

    @Test
    fun `projects 下覆盖三种形态：普通、git 徽章、不可读`() {
        val entries = json(backend().get("/api/folders", "path=C:\\Users\\Demo\\projects"))
            .getJSONArray("entries")
        assertEquals(3, entries.length())
        assertTrue(entries.getJSONObject(0).optJSONObject("hints").optBoolean("git"))
        assertEquals("unreadable", entries.getJSONObject(2).optString("error"))
    }

    @Test
    fun `workdir：opencode 不支持，其他 Agent 可设置并回读`() {
        val backend = backend()
        assertEquals(400, backend.post("/api/agents/workdir", """{"agentId":"opencode","path":"D:\\x"}""").status)

        val res = backend.post("/api/agents/workdir", """{"agentId":"claude-code","path":"D:\\proj"}""")
        assertEquals(200, res.status)
        assertEquals("D:\\proj", json(res).optString("workdir"))

        val agents = json(backend.get("/api/agents")).getJSONArray("agents")
        val claude = (0 until agents.length()).map { agents.getJSONObject(it) }
            .first { it.optString("id") == "claude-code" }
        assertEquals("D:\\proj", claude.optString("workdir"))
    }

    @Test
    fun `workdir 缺少 agentId 返回 400`() {
        assertEquals(400, backend().post("/api/agents/workdir", """{"path":"D:\\x"}""").status)
    }

    // ─── 兜底 ─────────────────────────────────────────────────────────────────

    @Test
    fun `未知路径返回 404`() {
        val res = backend().get("/api/definitely-not-a-route")
        assertEquals(404, res.status)
        assertEquals("not found", json(res).optString("error"))
    }

    @Test
    fun `非 JSON 请求体不会让后端崩掉`() {
        val res = backend().post("/api/agents/default", "not json at all")
        assertEquals(200, res.status)
        assertNotNull(res.body)
    }
}
