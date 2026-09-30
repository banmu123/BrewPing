package com.brewping.core.demo

import android.util.Log
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer

/**
 * 拦截发往 Demo 主机的请求，交给 [DemoBackend] 生成模拟响应。
 *
 * 对齐 iOS `DemoURLProtocol`：**只**接管主机名为 [DemoBackend.HOST] 的请求，
 * 其余一律 `chain.proceed()` 走真实网络。因为拦截发生在 OkHttp 这一层，
 * `DesktopApiClient` 里全部 40 个方法一行都不用改 —— 与 iOS「调用方无需感知」等价。
 */
class DemoInterceptor(private val backend: DemoBackend) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        if (!request.url.host.equals(DemoBackend.HOST, ignoreCase = true)) {
            return chain.proceed(request)
        }

        val bodyText = request.body?.let { body ->
            Buffer().use { buffer ->
                body.writeTo(buffer)
                buffer.readUtf8()
            }
        }.orEmpty()

        val result = backend.handle(
            method = request.method,
            path = request.url.encodedPath,
            query = request.url.query,
            body = bodyText,
        )
        Log.i(TAG, "demo ${request.method} ${request.url.encodedPath} -> ${result.status}")

        // 加一点延迟，让 UI 的 Sending / Working 状态真的看得见（对齐 iOS 的 0.25s）。
        // 拦截器跑在 OkHttp 的调度线程上，阻塞这里等价于「网络慢」。
        Thread.sleep(LATENCY_MS)

        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(result.status)
            .message(if (result.status == 200) "OK" else "Demo")
            .body(result.body.toResponseBody(JSON))
            .build()
    }

    companion object {
        private const val TAG = "BrewPingDemo"
        private const val LATENCY_MS = 250L
        private val JSON = "application/json; charset=utf-8".toMediaType()
    }
}
