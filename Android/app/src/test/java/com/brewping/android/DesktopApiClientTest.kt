package com.brewping.android

import com.brewping.android.api.DesktopApiClient
import com.brewping.android.model.DesktopDevice
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.ServerSocket as JServerSocket

/**
 * DesktopApiClient 集成测试：用本地 HTTP 服务模拟 BrewPing Desktop，
 * 校验请求路径/请求体与响应解析契约（含 Windows 端 executable 为字符串的边界）。
 *
 * 说明：Android 单元测试 classpath 不包含 com.sun.net.httpserver，
 * 因此这里用 java.net.ServerSocket 实现最小 HTTP/1.1 桩服务。
 */
class DesktopApiClientTest {

    private lateinit var server: StubHttpServer
    private val client = DesktopApiClient()
    private lateinit var device: DesktopDevice

    @Before
    fun setUp() {
        server = StubHttpServer()
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

    // ─── GET /api/status ──────────────────────────────────────────────────────

    // TC-API-01  正常解析状态与嵌套会话
    @Test
    fun `fetchStatus parses full payload`() = runBlocking {
        server.stub(
            "GET", "/api/status", 200,
            """{"status":"online","host":"Win-PC","defaultAgent":"opencode",
               "session":{"id":"sess_abcd1234","agent":"opencode","agentName":"OpenCode","status":"running"}}"""
        )

        val response = client.fetchStatus(device)

        assertNotNull(response)
        assertEquals("online", response!!.status)
        assertEquals("Win-PC", response.host)
        assertEquals("opencode", response.defaultAgent)
        assertEquals("sess_abcd1234", response.session?.id)
        assertEquals("OpenCode", response.session?.agentName)
        assertEquals("running", response.session?.status)
        assertEquals("GET", server.lastMethod)
        assertEquals("/api/status", server.lastPath)
    }

    // TC-API-02  边界：无会话时 session 为 null 且不抛异常
    @Test
    fun `fetchStatus tolerates missing session`() = runBlocking {
        server.stub("GET", "/api/status", 200, """{"status":"online","host":"H","defaultAgent":null,"session":null}""")

        val response = client.fetchStatus(device)

        assertNotNull(response)
        assertNull(response!!.session)
        assertEquals("", response.defaultAgent)
    }

    // TC-API-03  边界：字段缺失时使用空串兜底
    @Test
    fun `fetchStatus tolerates absent fields`() = runBlocking {
        server.stub("GET", "/api/status", 200, "{}")

        val response = client.fetchStatus(device)

        assertNotNull(response)
        assertEquals("", response!!.status)
        assertEquals("", response.host)
        assertNull(response.session)
    }

    // TC-API-04  边界：服务端 500 必须返回 null 而非部分对象
    @Test
    fun `fetchStatus returns null on server error`() = runBlocking {
        server.stub("GET", "/api/status", 500, """{"error":"boom"}""")
        assertNull(client.fetchStatus(device))
    }

    // TC-API-05  边界：响应非法 JSON 必须返回 null
    @Test
    fun `fetchStatus returns null on malformed json`() = runBlocking {
        server.stub("GET", "/api/status", 200, "<html>not json</html>")
        assertNull(client.fetchStatus(device))
    }

    // TC-API-06  边界：端口不可达必须优雅降级为 null
    @Test
    fun `fetchStatus returns null when port is closed`() = runBlocking {
        val deadPort = ServerSocket(0).use { it.localPort }
        val dead = device.copy(port = deadPort)
        assertNull(client.fetchStatus(dead))
    }

    // ─── GET /api/agents ──────────────────────────────────────────────────────

    // TC-API-07  布尔 executable（macOS 契约）
    @Test
    fun `fetchAgents parses boolean executable`() = runBlocking {
        server.stub(
            "GET", "/api/agents", 200,
            """{"defaultAgent":"opencode","agents":[
                 {"id":"opencode","name":"OpenCode","installed":true,"active":true,"executable":true,"version":"1.0.0"},
                 {"id":"aider","name":"Aider","installed":false,"active":false,"executable":false}]}"""
        )

        val response = client.fetchAgents(device)

        assertNotNull(response)
        assertEquals("opencode", response!!.defaultAgent)
        assertEquals(2, response.agents.size)
        assertTrue(response.agents[0].executable)
        assertTrue(response.agents[0].installed)
        assertTrue(response.agents[0].active)
        assertEquals("1.0.0", response.agents[0].version)
        assertFalse(response.agents[1].executable)
    }

    // TC-API-08  字符串 executable（Windows 契约）必须被识别为可用
    @Test
    fun `fetchAgents treats non-empty string executable as available`() = runBlocking {
        server.stub(
            "GET", "/api/agents", 200,
            """{"defaultAgent":"codex","agents":[
                 {"id":"codex","name":"Codex CLI","installed":true,"active":true,
                  "executable":"C:\\\\Users\\\\me\\\\AppData\\\\Roaming\\\\npm\\\\codex.cmd","version":"2.0.0"}]}"""
        )

        val response = client.fetchAgents(device)

        assertNotNull(response)
        assertTrue("字符串路径应被视为可执行", response!!.agents[0].executable)
    }

    // TC-API-09  边界：executable 为空串 / 字段缺失 → false
    @Test
    fun `fetchAgents treats empty or missing executable as unavailable`() = runBlocking {
        server.stub(
            "GET", "/api/agents", 200,
            """{"agents":[{"id":"a","name":"A","installed":true,"executable":""},
                          {"id":"b","name":"B","installed":true}]}"""
        )

        val response = client.fetchAgents(device)

        assertNotNull(response)
        assertFalse(response!!.agents[0].executable)
        assertFalse(response.agents[1].executable)
    }

    // TC-API-10  边界：agents 为空数组 → 空列表，不崩溃
    @Test
    fun `fetchAgents tolerates empty array`() = runBlocking {
        server.stub("GET", "/api/agents", 200, """{"agents":[]}""")
        assertEquals(0, client.fetchAgents(device)!!.agents.size)
    }

    // ─── POST /api/agents/default ─────────────────────────────────────────────

    // TC-API-11  成功切换返回 null，且请求体包含 agent 字段
    @Test
    fun `setDefaultAgent returns null on success and sends agent field`() = runBlocking {
        server.stub("POST", "/api/agents/default", 200, """{"success":true,"defaultAgent":"codex"}""")

        val error = client.setDefaultAgent(device, "codex")

        assertNull(error)
        assertEquals("POST", server.lastMethod)
        assertEquals("/api/agents/default", server.lastPath)
        assertTrue("请求体必须包含 agent 字段", server.lastBody!!.contains("\"agent\":\"codex\""))
    }

    // TC-API-12  服务端 success=false → 透传错误信息
    @Test
    fun `setDefaultAgent surfaces server error`() = runBlocking {
        server.stub("POST", "/api/agents/default", 200, """{"success":false,"error":"agent not installed"}""")

        assertEquals("agent not installed", client.setDefaultAgent(device, "ghost"))
    }

    // TC-API-13  边界：非 200 响应 → 返回失败提示而非 null
    @Test
    fun `setDefaultAgent returns failure message on non-200`() = runBlocking {
        server.stub("POST", "/api/agents/default", 404, "")

        val result = client.setDefaultAgent(device, "codex")

        assertNotNull(result)
        assertTrue(result!!.isNotEmpty())
    }

    // ─── 会话生命周期 ─────────────────────────────────────────────────────────

    // TC-API-14  startSession 解析会话 ID
    @Test
    fun `startSession parses session id`() = runBlocking {
        server.stub("POST", "/api/session/start", 200, """{"success":true,"sessionId":"sess_1234abcd","status":"running"}""")

        val response = client.startSession(device)

        assertNotNull(response)
        assertTrue(response!!.success)
        assertEquals("sess_1234abcd", response.sessionId)
        assertEquals("running", response.status)
    }

    // TC-API-15  stopSession 解析停止结果
    @Test
    fun `stopSession parses stopped status`() = runBlocking {
        server.stub("POST", "/api/session/stop", 200, """{"success":true,"sessionId":"sess_1234abcd","status":"stopped"}""")

        val response = client.stopSession(device)

        assertNotNull(response)
        assertTrue(response!!.success)
        assertEquals("stopped", response.status)
    }

    // TC-API-16  边界：会话接口返回 500 → null
    @Test
    fun `lifecycle returns null on server error`() = runBlocking {
        server.stub("POST", "/api/session/start", 500, "")
        server.stub("POST", "/api/session/stop", 500, "")
        assertNull(client.startSession(device))
        assertNull(client.stopSession(device))
    }

    // ─── POST /api/message ────────────────────────────────────────────────────

    // TC-API-17  提交消息返回 commandId，请求体为 {"text": ...}
    @Test
    fun `submitMessage returns command id and sends text field`() = runBlocking {
        server.stub("POST", "/api/message", 200, """{"success":true,"commandId":"cmd_abcd1234","sessionId":"sess_x"}""")

        val response = client.submitMessage(device, "hello world")

        assertNotNull(response)
        assertTrue(response!!.success)
        assertEquals("cmd_abcd1234", response.commandId)
        assertEquals("POST", server.lastMethod)
        assertEquals("/api/message", server.lastPath)
        assertTrue(server.lastBody!!.contains("\"text\":\"hello world\""))
    }

    // TC-API-18  边界：无会话时服务端返回 400 → null（客户端据此判定失败）
    @Test
    fun `submitMessage returns null when session is missing`() = runBlocking {
        server.stub("POST", "/api/message", 400, "")
        assertNull(client.submitMessage(device, "hi"))
    }

    // ─── GET /api/message/{id} ────────────────────────────────────────────────

    // TC-API-19  轮询 completed 状态并解析耗时
    @Test
    fun `pollCommandStatus parses completed payload`() = runBlocking {
        server.stub(
            "GET", "/api/message/cmd_1", 200,
            """{"commandId":"cmd_1","status":"completed","response":"done","duration":2.5,"modelId":"gpt-x"}"""
        )

        val response = client.pollCommandStatus(device, "cmd_1")

        assertNotNull(response)
        assertEquals("completed", response!!.status)
        assertEquals("done", response.response)
        assertEquals(2.5, response.duration!!, 0.001)
        assertEquals("gpt-x", response.modelId)
    }

    // TC-API-20  轮询 failed 状态并解析 failureReason
    @Test
    fun `pollCommandStatus parses failed payload`() = runBlocking {
        server.stub(
            "GET", "/api/message/cmd_2", 200,
            """{"commandId":"cmd_2","status":"failed","error":"exit 1","failureReason":"process_exited","duration":0.8}"""
        )

        val response = client.pollCommandStatus(device, "cmd_2")

        assertNotNull(response)
        assertEquals("failed", response!!.status)
        assertEquals("exit 1", response.error)
        assertEquals("process_exited", response.failureReason)
    }

    // TC-API-21  边界：duration 为 null / 缺失时必须解析为 null 而非 0.0
    @Test
    fun `pollCommandStatus treats absent duration as null`() = runBlocking {
        server.stub("GET", "/api/message/cmd_3", 200, """{"status":"completed","response":"ok","duration":null}""")
        server.stub("GET", "/api/message/cmd_4", 200, """{"status":"completed","response":"ok"}""")

        assertNull(client.pollCommandStatus(device, "cmd_3")!!.duration)
        assertNull(client.pollCommandStatus(device, "cmd_4")!!.duration)
    }

    // TC-API-22  commandId 必须拼接到请求路径中
    @Test
    fun `pollCommandStatus uses command id in path`() = runBlocking {
        server.stub("GET", "/api/message/cmd_abc-123", 200, """{"status":"working"}""")

        val response = client.pollCommandStatus(device, "cmd_abc-123")

        assertNotNull(response)
        assertEquals("working", response!!.status)
        assertEquals("/api/message/cmd_abc-123", server.lastPath)
    }

    // ─── POST /api/discovery/refresh ──────────────────────────────────────────

    // TC-API-23  刷新成功返回 true
    @Test
    fun `refreshDiscovery reports success flag`() = runBlocking {
        server.stub("POST", "/api/discovery/refresh", 200, """{"agents":[]}""")
        assertTrue(client.refreshDiscovery(device))
    }

    // TC-API-24  边界：刷新失败返回 false，不抛异常
    @Test
    fun `refreshDiscovery returns false on failure`() = runBlocking {
        server.stub("POST", "/api/discovery/refresh", 500, "")
        assertFalse(client.refreshDiscovery(device))
    }
}

// ─── 最小 HTTP/1.1 桩服务 ─────────────────────────────────────────────────────

private data class StubResponse(val code: Int, val body: String)

private class StubHttpServer {
    private val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
    private val routes = java.util.concurrent.ConcurrentHashMap<String, StubResponse>()

    @Volatile var lastMethod: String? = null
        private set

    @Volatile var lastPath: String? = null
        private set

    @Volatile var lastBody: String? = null
        private set

    val port: Int = server.localPort

    init {
        Thread({ acceptLoop() }, "stub-http-server").apply {
            isDaemon = true
            start()
        }
    }

    fun stub(method: String, path: String, code: Int, body: String) {
        routes["$method $path"] = StubResponse(code, body)
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
            Thread({ handle(socket) }, "stub-http-conn").apply {
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

            val stub = routes["$method $path"] ?: StubResponse(404, """{"error":"not found"}""")
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
        else -> "Status"
    }
}
