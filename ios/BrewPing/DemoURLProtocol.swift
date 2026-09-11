import Foundation

/// 拦截发往 Demo 主机的请求，交给 `DemoBackend` 生成模拟响应。
///
/// 只接管 `demo.brewping.local`，其余主机一律返回 `false` 走真实网络。
final class DemoURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host?.lowercased() else { return false }
        return host == DemoBackend.host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let (status, payload) = DemoBackend.shared.handle(
            method: request.httpMethod ?? "GET",
            path: url.path,
            query: url.query,
            body: Self.bodyData(of: request)
        )
        // Demo 链路全部走本拦截器，这里记一条 debug 日志：
        // 审核期间排查"Demo 没反应"时可直接看请求有没有真的发出来。
        // 注意：先把 method 取到局部变量，`request` 隐式依赖 self，
        // 而 OSLog 插值的值参数是 @autoclosure，直接写在插值里会报
        // "implicit use of 'self' in closure"。
        let method = request.httpMethod ?? "GET"
        BrewPingLog.demo.debug("intercepted \(method, privacy: .public) \(url.path, privacy: .public) -> \(status)")
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        // 加一点延迟，让 UI 的 Sending / Working 状态在审核时真的看得见
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// 读请求体。
    ///
    /// 坑点：URLSession 会把 `httpBody` 转成 `httpBodyStream` 再交给 URLProtocol，
    /// 因此这里 `request.httpBody` 往往是 nil —— 只读 httpBody 会永远拿到空 body，
    /// 表现为"POST /api/message 报 text is empty"。
    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody, !body.isEmpty { return body }
        guard let stream = request.httpBodyStream else { return Data() }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
