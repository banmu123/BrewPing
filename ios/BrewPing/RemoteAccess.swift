import Foundation

/// 远程访问（实验）：把发往**已配对电脑**的 HTTP 请求经中继隧道转发。
///
/// 为什么需要它：BrewPing 默认走局域网直连（Bonjour + `http://<ip>:8787`），
/// 一旦 iPhone 与电脑不在同一网络，请求就发不出去。开启本开关后，请求会被
/// 包装成隧道帧交给中继，由电脑端的中继桥在**本机**执行同一套 HTTP API：
///
/// ```
/// 本 App ──WS──▶ 中继 ◀──WS── 电脑端中继桥 ──进程内──▶ HTTPAPI.handle
/// ```
///
/// 三条重要约定：
///  1. **默认关闭**：未开启时行为与以前完全一致（纯局域网直连）；
///  2. **不绕过鉴权**：隧道帧里原样携带 Bearer + 时间戳 + nonce，电脑端仍按
///     配对令牌校验；中继只是搬运；
///  3. **可用性兜底**：中继不可用时回落直连（见 `RelayURLProtocol`），
///     因此开着开关在同一 Wi-Fi 下也能正常工作。
///
/// 配对仍需在同一局域网完成一次（配对码换取长期 token），远程只是让**之后的**
/// 请求不必同网。
final class RemoteAccess: ObservableObject {
    static let shared = RemoteAccess()

    enum State: Equatable {
        /// 开关关闭或地址为空
        case off
        case connecting
        case connected
        /// 连不上中继（错误文案用于 UI 展示）
        case failed(String)

        var isConnected: Bool { self == .connected }
    }

    // MARK: - 持久化键

    private enum Key {
        static let enabled = "remote.enabled"
        static let url = "remote.relayURL"
        static let deviceId = "remote.deviceId"
        static let token = "remote.relayToken"
    }

    // MARK: - 用户可见状态

    @Published private(set) var state: State = .off
    /// 开关。**不**在 didSet 里直接重连：UI 里改文字不该每次按键都重连，
    /// 由调用方在提交时显式调用 `applyChanges()`。
    @Published var isEnabled: Bool
    /// 中继地址，例如 `wss://relay.example.com` 或 `ws://192.168.1.9:3000`。
    @Published var relayURL: String
    /// 中继共享令牌（服务端 `RELAY_TOKEN`）。匿名模式可留空。
    @Published var token: String

    // MARK: - 私有状态

    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "BrewPing remote access")
    private var socket: URLSessionWebSocketTask?
    private var heartbeat: Timer?
    private var reconnectAttempt = 0
    private var pending: [String: CheckedContinuation<TunnelResponse, Error>] = [:]
    private var generation = 0

    /// 独立的 URLSession：**绝不能**用 `BrewPingHTTP.session` ——
    /// 那条会话挂了 `RelayURLProtocol`，用它建 WebSocket 会自我递归。
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private init() {
        isEnabled = defaults.bool(forKey: Key.enabled)
        relayURL = defaults.string(forKey: Key.url) ?? ""
        token = KeychainStore.string(forKey: Key.token) ?? ""
        Self.refreshPairedHosts()
        if isEnabled, !relayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            applyChanges()
        }
    }

    // MARK: - 配置变更

    /// 落盘 + 按新配置重连。UI 在开关切换、地址提交时调用。
    func applyChanges() {
        defaults.set(isEnabled, forKey: Key.enabled)
        defaults.set(relayURL, forKey: Key.url)
        KeychainStore.set(token.isEmpty ? nil : token, forKey: Key.token)
        Self.refreshPairedHosts()

        queue.async { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.teardown()
            guard self.isEnabled, self.endpointURL() != nil else {
                self.publish(.off)
                return
            }
            self.reconnectAttempt = 0
            self.connect()
        }
    }

    /// 稳定的本机标识（中继据此把响应送回）。与桌面端 `bp_mac_…` 同构。
    var deviceId: String {
        if let existing = defaults.string(forKey: Key.deviceId), !existing.isEmpty { return existing }
        let generated = "bp_ios_" + UUID().uuidString.prefix(8).lowercased()
        defaults.set(generated, forKey: Key.deviceId)
        return generated
    }

    /// 把用户填的地址规范成中继的 `/ws` 端点。
    private func endpointURL() -> URL? {
        var text = relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "wss://" + text }
        guard var comps = URLComponents(string: text) else { return nil }
        let basePath = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        comps.path = basePath.isEmpty ? "/ws" : "/" + basePath
        if !comps.path.hasSuffix("/ws") { comps.path += "/ws" }
        return comps.url
    }

    /// 本地网络直连是否应该让位给中继：开关打开**且**中继已连上。
    var shouldTunnel: Bool { isEnabled && state.isConnected }

    /// 中继自身的主机 / 端口（供 `RelayURLProtocol` 排除自身，避免把中继请求又塞回隧道）。
    var relayEndpointHostPort: (host: String, port: Int?)? {
        guard let url = endpointURL(), let host = url.host?.lowercased() else { return nil }
        return (host, url.port)
    }

    // MARK: - 已配对主机快照（供 URLProtocol 同步判定）

    /// `URLProtocol.canInit` 是**同步且非隔离**的，而 `DeviceStore` 的属性是主线程隔离的，
    /// 不能在 `canInit` 里直接读设备列表。因此缓存两份快照：主线程写、任意线程读（加锁）。
    ///
    /// - `cachedPairedHosts`：所有已配对（非 Demo）设备的主机 → 决定"要不要走隧道"；
    /// - `cachedHostDeviceIds`：主机 → 主机端 `deviceId` → 决定"隧道帧投给谁"。
    ///   缺失时隧道帧不带 deviceId，退回中继的角色路由（能用，但没有精确投递）。
    ///
    /// 快照为空时 `RelayURLProtocol` 一律不拦截 —— 退化为原来的局域网直连，不会更糟。
    private static let hostLock = NSLock()
    nonisolated(unsafe) private static var cachedPairedHosts: Set<String> = []
    nonisolated(unsafe) private static var cachedHostDeviceIds: [String: String] = [:]

    static var pairedHostSnapshot: Set<String> {
        hostLock.lock()
        defer { hostLock.unlock() }
        return cachedPairedHosts
    }

    /// 主机对应的主机端 deviceId（精确路由用）。未记录时返回 nil。
    static func hostDeviceId(forHost host: String) -> String? {
        hostLock.lock()
        defer { hostLock.unlock() }
        return cachedHostDeviceIds[host.lowercased()]
    }

    /// 刷新快照。App 启动、开关变更、设备列表变化、配对成功后调用。
    static func refreshPairedHosts() {
        Task { @MainActor in
            var hosts: Set<String> = []
            var deviceIds: [String: String] = [:]
            for device in DeviceStore.shared.devices where !device.isDemo {
                guard let host = device.baseURL?.host?.lowercased() else { continue }
                hosts.insert(host)
                if let hostDeviceId = device.hostDeviceId, !hostDeviceId.isEmpty {
                    deviceIds[host] = hostDeviceId
                }
            }
            hostLock.lock()
            cachedPairedHosts = hosts
            cachedHostDeviceIds = deviceIds
            hostLock.unlock()
        }
    }

    // MARK: - 连接

    private func connect() {
        guard let endpoint = endpointURL() else { publish(.off); return }
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var items = comps?.queryItems ?? []
        items.append(URLQueryItem(name: "role", value: "agent"))
        items.append(URLQueryItem(name: "deviceId", value: deviceId))
        comps?.queryItems = items
        guard let wsURL = comps?.url else { publish(.off); return }

        var request = URLRequest(url: wsURL)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let current = generation
        publish(.connecting)
        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        BrewPingLog.discovery.info("remote: connecting to \(endpoint.host ?? "?", privacy: .public)")

        receive(task, generation: current)
        sendFrame(["type": "ping"])
        startHeartbeat(generation: current)
    }

    private func receive(_ task: URLSessionWebSocketTask, generation current: Int) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.generation == current, self.socket === task else { return }
                switch result {
                case .success(let message):
                    self.reconnectAttempt = 0
                    switch message {
                    case .string(let text):
                        self.handleInbound(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) { self.handleInbound(text) }
                    @unknown default:
                        break
                    }
                    self.receive(task, generation: current)
                case .failure(let error):
                    BrewPingLog.discovery.error("remote: receive failed \(error.localizedDescription, privacy: .public)")
                    self.scheduleReconnect(generation: current)
                }
            }
        }
    }

    private func handleInbound(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = object["type"] as? String
        if type == "message", let payload = object["payload"] as? [String: Any] {
            guard let id = payload["id"] as? String else { return }
            let response = TunnelResponse(
                id: id,
                status: payload["status"] as? Int ?? 500,
                reason: payload["reason"] as? String,
                body: payload["body"] as? String ?? ""
            )
            if let continuation = pending.removeValue(forKey: id) {
                publish(.connected)
                continuation.resume(returning: response)
            }
            return
        }
        if type == "pong" || type == "system" {
            // 拿到中继任何回包都说明链路是通的（`pong` 或 `system/connected`）。
            publish(.connected)
            return
        }
        if type == "error" {
            let message = (object["payload"] as? [String: Any])?["error"] as? String ?? "relay error"
            BrewPingLog.discovery.error("remote: relay error \(message, privacy: .public)")
            // 🚨 中继的路由类错误（如「目标设备不在线」）**不代表连接坏了** —— 因此
            // 不改连接状态，只把在途请求立刻判失败，让调用方马上走局域网直连回落，
            // 而不是干等 30s 超时（否则一次脱靶会让每个请求都卡半分钟）。
            let continuations = pending
            pending.removeAll()
            for (_, continuation) in continuations {
                continuation.resume(throwing: TunnelError.targetUnavailable)
            }
            return
        }
    }

    private func startHeartbeat(generation current: Int) {
        heartbeat?.invalidate()
        let timer = Timer(timeInterval: 25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.generation == current, self.socket != nil else { return }
                self.sendFrame(["type": "ping"])
            }
        }
        heartbeat = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 指数退避重连（2s → 60s）。
    private func scheduleReconnect(generation current: Int) {
        teardown()
        guard isEnabled, endpointURL() != nil, generation == current else {
            publish(.off)
            return
        }
        reconnectAttempt += 1
        let delay = min(60.0, pow(2.0, Double(reconnectAttempt)))
        publish(.failed("relay unreachable"))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == current, self.isEnabled else { return }
            self.connect()
        }
    }

    private func teardown() {
        heartbeat?.invalidate()
        heartbeat = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        let continuations = pending
        pending.removeAll()
        for (_, continuation) in continuations {
            continuation.resume(throwing: URLError(.networkConnectionLost))
        }
    }

    private func sendFrame(_ object: [String: Any]) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { [weak self] error in
            guard let error, let self else { return }
            self.queue.async {
                BrewPingLog.discovery.error("remote: send failed \(error.localizedDescription, privacy: .public)")
                self.scheduleReconnect(generation: self.generation)
            }
        }
    }

    private func publish(_ newState: State) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state != newState else { return }
            self.state = newState
        }
    }

    // MARK: - 隧道请求

    struct TunnelRequest {
        let method: String
        let path: String
        let query: String?
        let headers: [String: String]
        let body: Data
        /// 目标电脑的 `deviceId`（主机端 DeviceIdentity）。非 nil 时中继**精确投递**给
        /// 那一台桌面端；nil 时退回角色广播（兼容尚未记录 deviceId 的老记录）。
        let targetDeviceId: String?
    }

    struct TunnelResponse {
        let id: String
        let status: Int
        let reason: String?
        let body: String

        var data: Data { Data(base64Encoded: body) ?? Data() }
    }

    enum TunnelError: Error {
        case notConnected
        case timedOut
        case malformedResponse
        /// 中继找不到目标设备（主机端中继桥没连上 / deviceId 不匹配）。
        case targetUnavailable
    }

    /// 经中继发一次请求。超时 30s（与直连一致）。
    func send(_ request: TunnelRequest) async throws -> TunnelResponse {
        let id = UUID().uuidString
        var payload: [String: Any] = [
            "id": id,
            "method": request.method,
            "path": request.path,
            "headers": request.headers,
            "body": request.body.base64EncodedString(),
        ]
        if let query = request.query { payload["query"] = query }
        // 🚨 精确路由：带上目标 deviceId 让中继走 `sendToDevice`。
        // 不带就变成按角色广播 —— 任何持有中继令牌并注册成 `desktop` 的连接
        // 都能收到这一帧（帧里带着设备令牌头），所以能带就必须带。
        if let targetDeviceId = request.targetDeviceId, !targetDeviceId.isEmpty {
            payload["deviceId"] = targetDeviceId
        }

        let frame: [String: Any] = [
            "type": "message",
            "target": "desktop",
            "payload": payload,
        ]

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self, self.socket != nil, self.state.isConnected else {
                    continuation.resume(throwing: TunnelError.notConnected)
                    return
                }
                self.pending[id] = continuation
                self.sendFrame(frame)
                self.queue.asyncAfter(deadline: .now() + 30) { [weak self] in
                    guard let self, let stale = self.pending.removeValue(forKey: id) else { return }
                    stale.resume(throwing: TunnelError.timedOut)
                }
            }
        }
    }
}
