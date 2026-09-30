import Foundation

/// 远程访问（实验）在桌面端的另一半：把中继转发过来的请求交给本机 HTTP API 执行。
///
/// 拓扑：
/// ```
///  iPhone ──WS──▶ 中继(relay) ◀──WS── 本桥 ──进程内调用──▶ HTTPAPI.handle
/// ```
///
/// 设计要点：**桥里没有任何业务逻辑**。它把隧道帧还原成 `HTTPRequest`，直接喂给
/// `HTTPAPI.handle(_:router:)` —— 与局域网请求走的是同一个入口。因此：
///   - 设备级鉴权（Bearer + 时间戳 + nonce）仍由 `PairingStore.authorize` 原样校验，
///     中继**不构成**绕过；隧道帧里的头会被原样带入；
///   - 新增 API 自动可用，桥里不需要维护路由表。
///
/// 开关默认关闭：只有配置了中继地址（`~/.brewping/relay.json` 或环境变量）才会连接。
/// 配置来源优先级：环境变量 > 配置文件。
///
/// 隧道帧（中继的 `message` payload）：
/// ```json
/// // 请求（iPhone → 中继 → 本桥）
/// { "id": "uuid", "method": "POST", "path": "/api/message",
///   "query": "optional=1", "headers": { "authorization": "Bearer …" }, "body": "<base64>" }
/// // 响应（本桥 → 中继 → iPhone）
/// { "id": "uuid", "status": 200, "reason": "OK", "body": "<base64>" }
/// ```
final class RelayBridge {
    /// 单例：`BrewPingAgent.run()` 启动它，桌面端设置页重配时也调用它。
    static let shared = RelayBridge()

    struct Config: Codable, Equatable {
        /// 中继地址，例如 `wss://relay.example.com` 或 `ws://192.168.1.9:3000`。
        var url: String
        /// 中继共享令牌（服务端 `RELAY_TOKEN`）。匿名模式可留空。
        var token: String

        var endpointURL: URL? {
            guard var text = Optional(url.trimmingCharacters(in: .whitespacesAndNewlines)), !text.isEmpty else { return nil }
            if !text.contains("://") { text = "wss://" + text }
            guard var comps = URLComponents(string: text) else { return nil }
            // 统一成 `/ws` 端点：允许用户只填主机名。
            let basePath = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            comps.path = basePath.isEmpty ? "/ws" : "/" + basePath
            if !comps.path.hasSuffix("/ws") { comps.path += "/ws" }
            return comps.url
        }
    }

    private let queue = DispatchQueue(label: "BrewPing relay bridge")
    private var task: URLSessionWebSocketTask?
    /// 🚨 心跳必须用 `DispatchSourceTimer` 挂在**自己的串行队列**上，不能用
    /// `Timer` + `RunLoop.main`：桌面端 daemon 的主线程是阻塞式 accept 循环
    /// （`BrewPingAgent.run()` 里的 while + usleep），主 RunLoop 根本不转，
    /// 挂在它上面的 Timer 永远不会触发 → 中继按 60s 空闲把连接踢掉，
    /// 表现为「桥每 80 秒掉线重连一次」（实测踩到过）。
    private var heartbeat: DispatchSourceTimer?
    private var reconnectWork: DispatchWorkItem?
    private var reconnectAttempt = 0
    private var config: Config?
    private var isStopping = false

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private init() {}

    // MARK: - 配置

    /// 配置文件：与 `device.json` 同目录（`~/.brewping/relay.json`）。
    static var configURL: URL {
        SessionManager.shared.directory.appendingPathComponent("relay.json")
    }

    /// 读取配置。环境变量优先（便于临时联调），其次配置文件。
    /// 返回 nil = 未配置（远程访问保持关闭，行为与以前完全一致）。
    static func loadConfig() -> Config? {
        let env = ProcessInfo.processInfo.environment
        let envURL = (env["BREWPING_RELAY_URL"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        var fileConfig: Config?
        if let data = try? Data(contentsOf: configURL),
           let decoded = try? JSONDecoder().decode(Config.self, from: data) {
            fileConfig = decoded
        }

        if !envURL.isEmpty {
            return Config(url: envURL, token: env["BREWPING_RELAY_TOKEN"] ?? fileConfig?.token ?? "")
        }
        guard let fileConfig, !fileConfig.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return fileConfig
    }

    /// 写入配置（桌面端设置页调用）。
    static func saveConfig(_ config: Config) throws {
        let directory = SessionManager.shared.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }

    /// 按当前配置（重新）建立连接。未配置则断开。
    func reload() {
        queue.async { [weak self] in
            guard let self else { return }
            self.teardownLocked()
            guard let config = Self.loadConfig() else {
                print("[RelayBridge] disabled (no ~/.brewping/relay.json and no BREWPING_RELAY_URL)")
                return
            }
            self.config = config
            self.isStopping = false
            self.reconnectAttempt = 0
            self.connectLocked()
        }
    }

    /// App 启动时调用：配置了就连接，没配置就什么都不做。
    func startIfConfigured() {
        guard Self.loadConfig() != nil else {
            print("[RelayBridge] disabled (no ~/.brewping/relay.json and no BREWPING_RELAY_URL)")
            return
        }
        reload()
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopping = true
            self.teardownLocked()
        }
    }

    // MARK: - 连接

    private func connectLocked() {
        guard !isStopping, let config, let endpoint = config.endpointURL else { return }
        let identity = DeviceIdentity.loadOrCreate()

        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var items = comps?.queryItems ?? []
        items.append(URLQueryItem(name: "role", value: "desktop"))
        items.append(URLQueryItem(name: "deviceId", value: identity.deviceId))
        comps?.queryItems = items
        guard let wsURL = comps?.url else { return }

        var request = URLRequest(url: wsURL)
        if !config.token.isEmpty {
            request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        }

        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        print("[RelayBridge] connecting to \(endpoint.host ?? "?") as \(identity.deviceId)")

        receiveLocked(task)
        sendHandshakeLocked(task)
        startHeartbeatLocked()
    }

    /// 中继在连接建立后不会再发 hello（除 `system/connected`），这里主动发一次 ping，
    /// 既是心跳、也用于尽快暴露握手失败（令牌不对会被 4003 关闭）。
    private func sendHandshakeLocked(_ task: URLSessionWebSocketTask) {
        sendLocked(["type": "ping"])
    }

    private func receiveLocked(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.task === task else { return }
                switch result {
                case .success(let message):
                    self.reconnectAttempt = 0
                    switch message {
                    case .string(let text):
                        self.handleInboundLocked(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleInboundLocked(text)
                        }
                    @unknown default:
                        break
                    }
                    self.receiveLocked(task)
                case .failure(let error):
                    print("[RelayBridge] receive failed: \(error.localizedDescription)")
                    self.scheduleReconnectLocked()
                }
            }
        }
    }

    private func handleInboundLocked(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard (object["type"] as? String) == "message" else { return }
        guard let payload = object["payload"] as? [String: Any] else { return }
        let from = object["from"] as? String

        let response = handleTunnelRequest(payload)
        guard let id = payload["id"] as? String else { return }

        var frame: [String: Any] = [
            "type": "message",
            "target": "agent",
            "payload": [
                "id": id,
                "status": response.status,
                "reason": response.reason,
                "body": response.body.base64EncodedString(),
            ] as [String: Any],
        ]
        if let from { frame["deviceId"] = from }
        sendLocked(frame)
    }

    /// 把隧道请求还原成 `HTTPRequest`，交给本机 HTTP API 执行。
    private func handleTunnelRequest(_ payload: [String: Any]) -> HTTPResponse {
        guard let method = payload["method"] as? String,
              let path = payload["path"] as? String else {
            return .json(400, "Bad Request", ["success": false, "error": "malformed tunnel frame"])
        }
        let bodyB64 = payload["body"] as? String ?? ""
        let body = Data(base64Encoded: bodyB64) ?? Data()

        var headers: [String: String] = [:]
        if let raw = payload["headers"] as? [String: Any] {
            for (key, value) in raw {
                if let value = value as? String {
                    headers[key.lowercased()] = value
                }
            }
        }

        let request = HTTPRequest(
            method: method,
            path: path,
            query: payload["query"] as? String,
            body: body,
            headers: headers
        )
        return HTTPAPI.handle(request, router: CommandRouter.shared)
    }

    private func sendLocked(_ object: [String: Any]) {
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            guard let error, let self else { return }
            self.queue.async {
                print("[RelayBridge] send failed: \(error.localizedDescription)")
                self.scheduleReconnectLocked()
            }
        }
    }

    // MARK: - 心跳与重连

    private func startHeartbeatLocked() {
        heartbeat?.cancel()
        heartbeat = nil
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 25, repeating: 25)
        timer.setEventHandler { [weak self] in
            guard let self, self.task != nil else { return }
            self.sendLocked(["type": "ping"])
        }
        timer.resume()
        heartbeat = timer
    }

    /// 指数退避重连（2s → 60s）。中继重启、网络切换都靠它自愈。
    private func scheduleReconnectLocked() {
        guard !isStopping, config != nil else { return }
        teardownLocked(keepConfig: true)
        reconnectAttempt += 1
        let delay = min(60.0, pow(2.0, Double(reconnectAttempt)))
        print("[RelayBridge] reconnecting in \(Int(delay))s (attempt \(reconnectAttempt))")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard !self.isStopping else { return }
                self.connectLocked()
            }
        }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func teardownLocked(keepConfig: Bool = false) {
        heartbeat?.cancel()
        heartbeat = nil
        reconnectWork?.cancel()
        reconnectWork = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        if !keepConfig { config = nil }
    }
}
