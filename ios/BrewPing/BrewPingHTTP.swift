import Foundation

/// BrewPing 的唯一网络出口。
///
/// 所有出网请求都必须走这里，原因有二：
///  1. Demo 模式需要在**不接触真实网络**的前提下返回模拟数据。
///     做法是把 `DemoURLProtocol` 挂进会话的 `protocolClasses`，
///     对调用方完全透明 —— 调用方照常写 URLSession 那套代码；
///  2. 鉴权头（Bearer + 时间戳 + nonce）只在这里拼一次，
///     避免每个调用点各写一遍、漏掉某个接口。
enum BrewPingHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        var classes = config.protocolClasses ?? []
        classes.insert(DemoURLProtocol.self, at: 0)
        config.protocolClasses = classes
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// 为某台设备构造请求，并按需附加鉴权头。
    ///
    /// - 未配对（Keychain 里没有 token）时不加鉴权头：让服务端返回 401，
    ///   由调用方把它翻译成"需要重新配对"，而不是在这里静默失败。
    /// - Demo 设备不需要鉴权（本地模拟，没有密钥）。
    static func request(
        device: ManagedDevice?,
        path: String,
        method: String = "GET",
        timeout: TimeInterval = 30
    ) -> URLRequest? {
        guard let device, let base = device.baseURL,
              let url = URL(string: base.absoluteString + path) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout

        if !device.isDemo, let token = DeviceAuth.token(for: device), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(String(Int(Date().timeIntervalSince1970)), forHTTPHeaderField: "X-BrewPing-Timestamp")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "X-BrewPing-Nonce")
        }
        return request
    }

    /// 配对请求：拿 6 位配对码去换长期 token。
    /// 这是**唯一**一个不需要鉴权头的业务接口。
    static func pairingRequest(host: String, port: String, code: String, deviceName: String) -> URLRequest? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedPort.isEmpty,
              let url = URL(string: "http://\(trimmedHost):\(trimmedPort)/api/pair") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "code": code,
            "deviceName": deviceName
        ])
        return request
    }

    /// 服务端返回 401 时的统一判定，供各调用点翻译成用户可读提示。
    static func isUnauthorized(_ response: URLResponse?) -> Bool {
        (response as? HTTPURLResponse)?.statusCode == 401
    }
}

/// `POST /api/pair` 的响应。
struct PairingResponse: Decodable {
    let success: Bool?
    let token: String?
    let deviceId: String?
    let deviceName: String?
    let error: String?
}

/// 配对凭据的读写。
enum DeviceAuth {
    static func tokenKey(deviceId: String) -> String { "deviceToken.\(deviceId)" }

    static func token(for device: ManagedDevice) -> String? {
        KeychainStore.string(forKey: tokenKey(deviceId: device.id))
    }

    /// Demo 设备天然算"已就绪"；真实设备必须持有 token。
    static func isPaired(_ device: ManagedDevice) -> Bool {
        if device.isDemo { return true }
        return !(token(for: device) ?? "").isEmpty
    }

    static func store(token: String, for device: ManagedDevice) {
        KeychainStore.set(token, forKey: tokenKey(deviceId: device.id))
    }

    static func clear(for device: ManagedDevice) {
        KeychainStore.delete(tokenKey(deviceId: device.id))
    }
}
