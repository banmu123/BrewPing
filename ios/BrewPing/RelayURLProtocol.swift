import Foundation

/// 远程访问的传输开关：**开启远程且中继已连接**时，把发往已配对电脑的请求
/// 改成经中继隧道转发；否则原样放行走局域网直连。
///
/// 为什么用 `URLProtocol` 而不是改每个调用点：全 App 的出网请求都汇聚在
/// `BrewPingHTTP.session`（协议层只此一处），挂一个拦截器即可覆盖全部接口，
/// 调用方（状态轮询、对话、审批、模型列表……）完全无感。
///
/// 判定为「该走中继」的条件（全部满足）：
///  1. 用户开了远程开关，且中继当前处于已连接状态；
///  2. 请求是 http/https（WebSocket 不经过这里，也不会被拦截）；
///  3. 目标主机命中某个**已配对且非 Demo**的设备地址；
///  4. 目标不是中继自身（防止把中继请求又塞回隧道）。
///
/// 隧道失败的兜底：**直接改走局域网直连**再发一次，避免中继抖动导致 App 整个
/// 不可用（用户开着开关、人和电脑在同一 Wi-Fi 时尤其重要）。
final class RelayURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard RemoteAccess.shared.shouldTunnel else { return false }
        guard let url = request.url, let scheme = url.scheme?.lowercased() else { return false }
        guard scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        guard !isRelayHost(host, port: url.port) else { return false }
        return matchesPairedDevice(host: host)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// 目标主机是否属于某台已配对（非 Demo）的设备。
    ///
    /// 用快照而不是直接读 `DeviceStore`：`canInit` 是同步非隔离的，
    /// 而设备列表在主线程隔离（见 `RemoteAccess.refreshPairedHosts`）。
    private static func matchesPairedDevice(host: String) -> Bool {
        RemoteAccess.pairedHostSnapshot.contains(host)
    }

    /// 是否是中继自身的地址（同主机同端口）。
    private static func isRelayHost(_ host: String, port: Int?) -> Bool {
        guard let endpoint = RemoteAccess.shared.relayEndpointHostPort else { return false }
        return endpoint.host == host && (port == nil || endpoint.port == nil || endpoint.port == port)
    }

    override func startLoading() {
        let request = self.request
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let tunnelRequest = RemoteAccess.TunnelRequest(
            method: request.httpMethod ?? "GET",
            path: url.path.isEmpty ? "/" : url.path,
            query: url.query,
            headers: (request.allHTTPHeaderFields ?? [:]).reduce(into: [String: String]()) { result, entry in
                result[entry.key.lowercased()] = entry.value
            },
            body: Self.bodyData(of: request),
            // 🚨 带上目标电脑的 deviceId → 中继精确投递（`sendToDevice`）。
            // 取不到（老记录没记过 deviceId）就传 nil，中继退回角色广播 —— 功能不受影响。
            targetDeviceId: url.host.flatMap { RemoteAccess.hostDeviceId(forHost: $0) }
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await RemoteAccess.shared.send(tunnelRequest)
                try self.deliver(response, for: url)
            } catch {
                // 隧道失败 → 回落直连（同一请求、不带本拦截器）。
                do {
                    let (data, directResponse) = try await Self.directSession.data(for: request)
                    guard let http = directResponse as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }
                    self.deliver(http: http, data: data, url: url)
                } catch let directError {
                    self.client?.urlProtocol(self, didFailWithError: directError)
                }
            }
        }
    }

    override func stopLoading() {}

    // MARK: - 交付响应

    private func deliver(_ response: RemoteAccess.TunnelResponse, for url: URL) throws {
        guard let http = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else { throw RemoteAccess.TunnelError.malformedResponse }
        deliver(http: http, data: response.data, url: url)
    }

    private func deliver(http: HTTPURLResponse, data: Data, url: URL) {
        // 🚨 OSLog 插值的值参数是 `@autoclosure`：插值里直接引用 self 的属性会报
        // "implicit use of 'self' in closure"，先取到局部常量再插值。
        let method = self.request.httpMethod ?? "GET"
        let path = url.path
        let status = http.statusCode
        BrewPingLog.discovery.debug(
            "remote: \(method, privacy: .public) \(path, privacy: .public) -> \(status, privacy: .public) (via relay)"
        )
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    // MARK: - 直连兜底会话

    private static let directSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        // 不挂任何自定义协议：这条会话只做「普通直连」。
        return URLSession(configuration: configuration)
    }()

    /// 读请求体。与 `DemoURLProtocol` 同样的坑：URLSession 会把 `httpBody`
    /// 转成 `httpBodyStream` 再交给 URLProtocol，只读 `httpBody` 会永远拿到空 body。
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
