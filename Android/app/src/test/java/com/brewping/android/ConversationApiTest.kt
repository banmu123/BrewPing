package com.brewping.android

import com.brewping.android.api.DesktopApiClient
import com.brewping.android.model.DesktopDevice
import com.brewping.android.model.pathLabel
import com.brewping.android.model.timeLabel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket

/**
 * 对话链路契约测试（对齐 iOS ConversationStore / 桌面端 camelCase 契约）：
 * 列表 / 详情 / 创建 / PATCH 对话级设置 / 模型列表 / message 带 conversationId。
 * 复用 DesktopApiClientTest 的最小 HTTP/1.1 桩服务模式（单元测试无 com.sun.net.httpserver）。
 */
class ConversationApiTest {

    private lateinit var server: StubConversationServer
    private val client = DesktopApiClient()
    private lateinit var device: DesktopDevice

    @Before
    fun setUp() {
        server = StubConversationServer()
        device = DesktopDevice(
            id = "test",
            name = "test",
            host = "127.0.0.1",
            ip = "127.0.0.1",
            port = server.port,
        )
    }

    @After
    fun tearDown() {
        server.stop()
    }

    // ─── GET /api/conversations ───────────────────────────────────────────────

    // TC-CONV-01  解析列表，缺失字段（approvalMode 等）必须容错回落
    @Test
    fun `fetchConversations parses list with tolerant defaults`() = runBlocking {
        server.stub(
            "GET", "/api/conversations?includeArchived=1", 200,
            """{"success":true,"conversations":[
                 {"id":"conv_a","agentId":"opencode","title":"Fix bug","createdAtMs":1700000000000,
                  "updatedAtMs":1700000100000,"archived":false,"isPinned":true,
                  "modelOverride":null,"modelProviderOverride":null,
                  "workdirOverride":"D:\\work\\app","approvalMode":"auto",
                  "latestCommandId":null,"messageCount":6},
                 {"id":"conv_b"}]}"""
        )

        val result = client.fetchConversations(device)

        assertNotNull(result)
        val list = result!!.conversations!!
        assertEquals(2, list.size)
        assertEquals("conv_a", list[0].id)
        assertEquals("opencode", list[0].agentId)
        assertTrue(list[0].isPinned)
        assertEquals("D:\\work\\app", list[0].workdirOverride)
        assertEquals("auto", list[0].approvalMode)
        assertEquals(6, list[0].messageCount)
        // 第二条只有 id —— 其余全部默认值，绝不抛异常
        assertEquals("conv_b", list[1].id)
        assertNull(list[1].workdirOverride)
        assertEquals(0, list[1].messageCount)
    }

    // TC-CONV-02  404 → unsupported（老版本桌面端静默降级，不是错误）
    @Test
    fun `fetchConversations marks unsupported on 404`() = runBlocking {
        server.stub("GET", "/api/conversations?includeArchived=1", 404, """{"error":"not found"}""")

        val result = client.fetchConversations(device)

        assertNotNull(result)
        assertTrue(result!!.unsupported)
        assertNull(result.conversations)
        assertNull(result.error)
    }

    // TC-CONV-03  501 同样按 unsupported 处理（对齐 iOS）
    @Test
    fun `fetchConversations marks unsupported on 501`() = runBlocking {
        server.stub("GET", "/api/conversations?includeArchived=1", 501, "")
        assertTrue(client.fetchConversations(device)!!.unsupported)
    }

    // ─── GET /api/conversations/{id} ──────────────────────────────────────────

    // TC-CONV-04  解析详情 + messages 补 uid
    @Test
    fun `fetchConversation parses transcript and assigns uids`() = runBlocking {
        server.stub(
            "GET", "/api/conversations/conv_a", 200,
            """{"success":true,"conversation":{
                 "id":"conv_a","agentId":"claude-code","title":"Fix bug",
                 "modelOverride":"gpt-4o","modelProviderOverride":"openai",
                 "workdirOverride":"D:\\work\\app","approvalMode":"safe",
                 "updatedAtMs":1700000100000,
                 "messages":[
                   {"role":"user","text":"hi","createdAtMs":1700000010000},
                   {"role":"assistant","text":"hello","createdAtMs":1700000020000}]}}"""
        )

        val result = client.fetchConversation(device, "conv_a")

        assertNotNull(result)
        val detail = result!!.detail!!
        assertEquals("claude-code", detail.agentId)
        assertEquals("gpt-4o", detail.modelOverride)
        assertEquals("openai", detail.modelProviderOverride)
        assertEquals(2, detail.messages.size)
        assertEquals("conv_a-0", detail.messages[0].uid)
        assertEquals("user", detail.messages[0].role)
        assertEquals("assistant", detail.messages[1].role)
    }

    // ─── POST /api/conversations ──────────────────────────────────────────────

    // TC-CONV-05  创建请求体带 agentId + approvalMode；响应解析为新详情
    @Test
    fun `createConversation sends agentId and approvalMode`() = runBlocking {
        server.stub(
            "POST", "/api/conversations", 200,
            """{"success":true,"conversation":{"id":"conv_new","agentId":"codex",
                 "approvalMode":"askAll","messages":[],"messageCount":0}}"""
        )

        val result = client.createConversation(device, "codex", "askAll")

        assertNotNull(result)
        assertEquals("conv_new", result!!.detail!!.id)
        assertEquals("askAll", result.detail!!.approvalMode)
        assertTrue(server.lastBody!!.contains("\"agentId\":\"codex\""))
        assertTrue(server.lastBody!!.contains("\"approvalMode\":\"askAll\""))
    }

    // ─── PATCH /api/conversations/{id} ────────────────────────────────────────

    // TC-CONV-06  PATCH 对话级设置透传请求体；服务端错误透传 error
    // （桌面端 PATCH 成功响应 = {"success":true,"conversation":summary}）
    @Test
    fun `patchConversation sends payload and surfaces server error`() = runBlocking {
        server.stub(
            "PATCH", "/api/conversations/conv_a", 200,
            """{"success":true,"conversation":{"id":"conv_a","agentId":"aider",
                 "approvalMode":"auto","messages":[],"messageCount":3}}""",
        )
        val ok = client.patchConversation(device, "conv_a", org.json.JSONObject("""{"agentId":"aider"}"""))
        assertNotNull(ok)
        assertEquals("aider", ok!!.detail!!.agentId)
        assertEquals("PATCH", server.lastMethod)
        assertTrue(server.lastBody!!.contains("\"agentId\":\"aider\""))

        server.stub("PATCH", "/api/conversations/conv_a", 400, """{"error":"bad agent"}""")
        val err = client.patchConversation(device, "conv_a", org.json.JSONObject("""{"agentId":"x"}"""))
        assertEquals("bad agent", err!!.error)
    }

    // ─── GET /api/agents/{id}/models ──────────────────────────────────────────

    // TC-CONV-07  拍平 providers/models 两层；同名模型靠 provider 区分
    @Test
    fun `fetchAgentModels flattens providers and parses preferred ids`() = runBlocking {
        server.stub(
            "GET", "/api/agents/opencode/models", 200,
            """{"agentId":"opencode",
               "providers":[
                 {"id":"openai","name":"OpenAI","models":[
                    {"id":"gpt-4o","name":"GPT-4o","available":true},
                    {"id":"gpt-4o-mini","name":"GPT-4o mini","available":true}]},
                 {"id":"xiaomi","name":"Xiaomi","models":[
                    {"id":"gpt-4o","name":"GPT-4o","available":true}]}],
               "activeModelId":"gpt-4o-mini","preferredModelId":"gpt-4o",
               "preferredProviderId":"openai"}"""
        )

        val result = client.fetchAgentModels(device, "opencode")

        assertNotNull(result)
        assertEquals(3, result!!.models.size)
        assertEquals("OpenAI", result.models[0].providerName)
        assertEquals("openai/gpt-4o", result.models[0].compositeID)
        assertEquals("xiaomi/gpt-4o", result.models[2].compositeID)
        assertEquals("gpt-4o", result.preferredModelID)
        assertEquals("openai", result.preferredProviderID)
        assertEquals("gpt-4o-mini", result.activeModelID)
    }

    // TC-CONV-08  501 → unsupported（这台主机没得选，不是错误）
    @Test
    fun `fetchAgentModels marks unsupported on 501`() = runBlocking {
        server.stub("GET", "/api/agents/opencode/models", 501, "")
        assertTrue(client.fetchAgentModels(device, "opencode")!!.unsupported)
    }

    // ─── POST /api/message 带 conversationId ──────────────────────────────────

    // TC-CONV-09  conversationId 必须随请求体提交（显式对话，防落错对话）
    @Test
    fun `submitMessage forwards conversationId`() = runBlocking {
        server.stub("POST", "/api/message", 200, """{"success":true,"commandId":"cmd_1"}""")

        val response = client.submitMessage(device, "hello", "conv_42")

        assertNotNull(response)
        assertTrue(server.lastBody!!.contains("\"text\":\"hello\""))
        assertTrue(server.lastBody!!.contains("\"conversationId\":\"conv_42\""))
    }

    // TC-CONV-10  conversationId 为 null 时不得出现该字段（三层回落留给桌面端）
    @Test
    fun `submitMessage omits conversationId when null`() = runBlocking {
        server.stub("POST", "/api/message", 200, """{"success":true,"commandId":"cmd_2"}""")
        client.submitMessage(device, "hi")
        assertTrue(!server.lastBody!!.contains("conversationId"))
    }

    // ─── 展示辅助（与 iOS bpPathLabel / bpTimeLabel 同规则）────────────────────

    // TC-CONV-11  pathLabel 取目录末段（正反斜杠均可）
    @Test
    fun `pathLabel extracts last segment`() {
        assertEquals("workFlow", pathLabel("D:\\study\\workFlow"))
        assertEquals("workFlow", pathLabel("D:\\study\\workFlow\\"))
        assertEquals("home", pathLabel("/Users/me/home/"))
        assertEquals("root", pathLabel("root"))
    }

    // TC-CONV-12  timeLabel：非今天 → MM-dd HH:mm；无效时间戳 → 空串
    @Test
    fun `timeLabel formats non-today timestamps and blank for zero`() {
        assertTrue(timeLabel(0.0).isEmpty())
        assertTrue(timeLabel(-1.0).isEmpty())
        // 2020-01-02 03:04 UTC 以本地时区渲染，仅断言形状（MM-dd HH:mm）
        assertTrue(timeLabel(1577934240000.0).matches(Regex("\\d{2}-\\d{2} \\d{2}:\\d{2}")))
    }
}

// ─── 最小 HTTP/1.1 桩服务（与 DesktopApiClientTest 同款）────────────────────────

private data class ConvStubResponse(val code: Int, val body: String)

private class StubConversationServer {
    private val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
    private val routes = java.util.concurrent.ConcurrentHashMap<String, ConvStubResponse>()

    @Volatile var lastMethod: String? = null
        private set

    @Volatile var lastPath: String? = null
        private set

    @Volatile var lastBody: String? = null
        private set

    val port: Int = server.localPort

    init {
        Thread({ acceptLoop() }, "stub-conv-server").apply {
            isDaemon = true
            start()
        }
    }

    fun stub(method: String, path: String, code: Int, body: String) {
        routes["$method $path"] = ConvStubResponse(code, body)
    }

    fun stop() {
        runCatching { server.close() }
    }

    private fun acceptLoop() {
        while (!server.isClosed) {
            val socket = try {
                server.accept()
            } catch (_: Exception) {
                return
            }
            Thread({ handle(socket) }, "stub-conv-conn").apply {
                isDaemon = true
                start()
            }
        }
    }

    private fun handle(socket: Socket) {
        socket.use { s ->
            val input = s.getInputStream()
            val requestLine = readLine(input) ?: return
            val parts = requestLine.split(" ")
            if (parts.size < 2) return
            val method = parts[0]
            val path = parts[1]

            var contentLength = 0
            while (true) {
                val line = readLine(input) ?: break
                if (line.isEmpty()) break
                if (line.lowercase().startsWith("content-length:")) {
                    contentLength = line.substringAfter(":").trim().toIntOrNull() ?: 0
                }
            }

            val bodyBytes = ByteArray(contentLength)
            var read = 0
            while (read < contentLength) {
                val n = input.read(bodyBytes, read, contentLength - read)
                if (n < 0) break
                read += n
            }
            val body = String(bodyBytes, 0, read, Charsets.UTF_8)

            lastMethod = method
            lastPath = path
            lastBody = body

            val stub = routes["$method $path"] ?: ConvStubResponse(404, """{"error":"not found"}""")
            val payload = stub.body.toByteArray(Charsets.UTF_8)
            val header = "HTTP/1.1 ${stub.code} ${reasonPhrase(stub.code)}\r\n" +
                "Content-Type: application/json\r\n" +
                "Content-Length: ${payload.size}\r\n" +
                "Connection: close\r\n\r\n"
            val out = s.getOutputStream()
            out.write(header.toByteArray(Charsets.UTF_8))
            out.write(payload)
            out.flush()
        }
    }

    private fun readLine(input: InputStream): String? {
        val sb = StringBuilder()
        while (true) {
            val b = input.read()
            if (b < 0) return if (sb.isEmpty()) null else sb.toString()
            if (b == '\n'.code) return sb.toString().removeSuffix("\r")
            sb.append(b.toChar())
        }
    }

    private fun reasonPhrase(code: Int): String = when (code) {
        200 -> "OK"
        400 -> "Bad Request"
        404 -> "Not Found"
        500 -> "Internal Server Error"
        501 -> "Not Implemented"
        else -> "Status"
    }
}
