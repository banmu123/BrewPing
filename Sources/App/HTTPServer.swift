import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    /// `?` 之后的原始 query（未解码，可为 nil）。`/api/folders?path=…` 这类
    /// 带参 GET 依赖它 —— 之前 query 被直接丢弃，带参路由无法实现。
    let query: String?
    let body: Data
    /// 头字段名**统一小写**，取值时直接用小写 key（HTTP 头本身大小写不敏感）。
    let headers: [String: String]
    /// 对端地址（IPv4/IPv6 字面量），来自 `NWConnection` 的远端端点 —— 由内核提供，
    /// **不是**客户端可伪造的请求头。仅用于配对失败限速的分桶。
    /// 中继隧道请求在进程内还原，没有真实对端地址，为 nil。
    let remoteAddress: String?

    init(
        method: String,
        path: String,
        query: String?,
        body: Data,
        headers: [String: String],
        remoteAddress: String? = nil
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.headers = headers
        self.remoteAddress = remoteAddress
    }

    /// 解析 query 为字典（percent 解码；同名字段取最后一个）。
    var queryItems: [String: String] {
        guard let query, !query.isEmpty else { return [:] }
        var items: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let key = String(kv[0]).removingPercentEncoding else { continue }
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? "") : ""
            items[key] = value
        }
        return items
    }
}

struct HTTPResponse {
    let status: Int
    let reason: String
    let body: Data
    /// 额外响应头（目前只用于 429 的 `Retry-After`）。名字/值含 CR/LF 时会被丢弃，
    /// 避免响应头注入。
    let headers: [String: String]

    init(status: Int, reason: String, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.reason = reason
        self.body = body
        self.headers = headers
    }

    static func json(
        _ status: Int,
        _ reason: String,
        _ object: [String: Any],
        headers: [String: String] = [:]
    ) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, reason: reason, body: data, headers: headers)
    }
}

final class HTTPServer {
    /// 请求头（请求行 + 所有头字段）上限。超过即 431 —— 无论是否已收到 body。
    static let maxHeadBytes = 1_048_576
    /// 单个请求体上限：防异常/恶意超大 body 导致内存无限增长
    /// （业务上限 = 消息文本，8MB 已远超所需）。
    static let maxBodyBytes = 8 * 1_048_576

    private let preferredPort: UInt16
    private let lanInterface: NWInterface?
    private let handler: (HTTPRequest) -> HTTPResponse
    private var listener: NWListener?

    init(port: UInt16, lanInterface: NWInterface?, handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.preferredPort = port
        self.lanInterface = lanInterface
        self.handler = handler
    }

    func start() throws -> (port: UInt16, boundToLAN: Bool) {
        var attempts: [(interface: NWInterface?, port: UInt16)] = []
        if let iface = lanInterface {
            attempts.append((iface, preferredPort))
        }
        attempts.append((nil, preferredPort))
        attempts.append((nil, preferredPort + 1))
        attempts.append((nil, preferredPort + 2))

        var lastError = "unknown"
        for attempt in attempts {
            do {
                let port = try startListener(port: attempt.port, interface: attempt.interface)
                return (port, attempt.interface != nil)
            } catch {
                lastError = "\(error)"
            }
        }
        throw UnixSocketError.failure("HTTP server failed on all attempts: \(lastError)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func startListener(port: UInt16, interface: NWInterface?) throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let interface {
            params.requiredInterface = interface
        }
        guard let listenerPort = NWEndpoint.Port(rawValue: port) else {
            throw UnixSocketError.failure("invalid port \(port)")
        }
        let listener = try NWListener(using: params, on: listenerPort)
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        var failure: String?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                failure = "\(error)"
                ready.signal()
            case .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        listener.start(queue: DispatchQueue(label: "BrewPing HTTP listener"))

        if ready.wait(timeout: .now() + 3) == .timedOut {
            listener.cancel()
            throw UnixSocketError.failure("HTTP listener timed out on port \(port)")
        }
        if let failure {
            throw UnixSocketError.failure("HTTP listener failed on port \(port): \(failure)")
        }
        return port
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed = state {
                connection.cancel()
            }
        }
        connection.start(queue: DispatchQueue(label: "BrewPing HTTP connection"))
        receiveHead(connection, buffer: Data(), peer: Self.peerAddress(connection))
    }

    // MARK: - Reading

    private func receiveHead(_ connection: NWConnection, buffer: Data, peer: String?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data {
                buf.append(data)
            }
            if let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                // headData 的长度上限由 parseHead 统一校验 —— 无论 header 与 body
                // 是否在同一个数据包里到达，都走这一条判定。
                let headData = buf.subdata(in: buf.startIndex..<headerEnd.lowerBound)
                let head: ParsedHead
                switch Self.parseHead(headData) {
                case .success(let parsed):
                    head = parsed
                case .failure(let failure):
                    self.respond(connection, failure.response)
                    return
                }
                let body = buf.subdata(in: headerEnd.upperBound..<buf.endIndex)
                if body.count >= head.contentLength {
                    // contentLength 已在 parseHead 中校验为非负且 <= maxBodyBytes，
                    // 这里的 prefix 不会再出现负数长度。
                    let request = HTTPRequest(
                        method: head.method, path: head.path, query: head.query,
                        body: Data(body.prefix(head.contentLength)), headers: head.headers,
                        remoteAddress: peer
                    )
                    self.respond(connection, self.handler(request))
                } else {
                    self.receiveBody(connection, head: head, buffer: body, peer: peer)
                }
                return
            }
            if error == nil, !isComplete, buf.count <= Self.maxHeadBytes {
                self.receiveHead(connection, buffer: buf, peer: peer)
            } else if error == nil, !isComplete {
                // 1MB 内都没等到 CRLFCRLF：拒绝而不是继续缓存
                self.respond(connection, HeadParseFailure.headerTooLarge.response)
            } else {
                connection.cancel()
            }
        }
    }

    private func receiveBody(
        _ connection: NWConnection,
        head: ParsedHead,
        buffer: Data,
        peer: String?
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data {
                buf.append(data)
            }
            if buf.count >= head.contentLength {
                let request = HTTPRequest(
                    method: head.method, path: head.path, query: head.query,
                    body: Data(buf.prefix(head.contentLength)), headers: head.headers,
                    remoteAddress: peer
                )
                self.respond(connection, self.handler(request))
                return
            }
            if error == nil, !isComplete, buf.count <= Self.maxBodyBytes {
                self.receiveBody(connection, head: head, buffer: buf, peer: peer)
            } else {
                connection.cancel()
            }
        }
    }

    // MARK: - Head parsing

    struct ParsedHead {
        let method: String
        let path: String
        let query: String?
        let contentLength: Int
        let headers: [String: String]
    }

    /// 请求头解析失败的原因。每一种都映射到一个明确的 4xx，绝不静默降级成
    /// `Content-Length: 0`（那样会把「有 body 的请求」读成空 body，产生歧义）。
    enum HeadParseFailure: Error, Equatable {
        case malformed
        case headerTooLarge
        case invalidContentLength
        case duplicateContentLength
        case unsupportedTransferEncoding
        case payloadTooLarge

        var status: Int {
            switch self {
            case .headerTooLarge: return 431
            case .payloadTooLarge: return 413
            default: return 400
            }
        }

        var reason: String {
            switch self {
            case .headerTooLarge: return "Request Header Fields Too Large"
            case .payloadTooLarge: return "Payload Too Large"
            default: return "Bad Request"
            }
        }

        /// 对外错误文案：只说「哪一类解析失败」，不回显任何请求内容。
        var message: String {
            switch self {
            case .malformed: return "malformed request"
            case .headerTooLarge: return "request head too large"
            case .invalidContentLength: return "invalid content-length"
            case .duplicateContentLength: return "duplicate content-length"
            case .unsupportedTransferEncoding: return "transfer-encoding is not supported"
            case .payloadTooLarge: return "request body too large"
            }
        }

        var response: HTTPResponse {
            .json(status, reason, ["success": false, "error": message])
        }
    }

    static func parseHead(_ headData: Data) -> Result<ParsedHead, HeadParseFailure> {
        guard headData.count <= maxHeadBytes else { return .failure(.headerTooLarge) }
        guard !headData.isEmpty, let head = String(data: headData, encoding: .utf8) else {
            return .failure(.malformed)
        }

        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { return .failure(.malformed) }
        lines.removeFirst()

        // 请求行：`METHOD SP request-target SP HTTP-version`
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3 else { return .failure(.malformed) }
        let method = String(parts[0])
        guard Self.isValidToken(method) else { return .failure(.malformed) }
        guard parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return .failure(.malformed) }

        var path = String(parts[1])
        guard path.hasPrefix("/"), !Self.containsControlCharacters(path) else {
            return .failure(.malformed)
        }
        var query: String?
        if let queryStart = path.firstIndex(of: "?") {
            query = String(path[path.index(after: queryStart)...])
            path = String(path[..<queryStart])
        }

        var contentLength = 0
        var sawContentLength = false
        var headers: [String: String] = [:]

        for line in lines {
            // 头部区块里不该再出现空行（CRLFCRLF 已在调用方切走）；容忍末尾空串。
            if line.isEmpty { continue }
            // obs-fold（换行续行）已废弃，且会让解析歧义 —— 直接拒绝。
            if line.hasPrefix(" ") || line.hasPrefix("\t") { return .failure(.malformed) }
            guard let colon = line.firstIndex(of: ":") else { return .failure(.malformed) }

            let rawName = String(line[line.startIndex..<colon])
            guard Self.isValidToken(rawName) else { return .failure(.malformed) }
            let name = rawName.lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard !Self.containsControlCharacters(value) else { return .failure(.malformed) }

            // 本项目不支持分块传输：任何 Transfer-Encoding 都拒绝，
            // 绝不让它退化成「按 Content-Length 读」或「读成空 body」。
            if name == "transfer-encoding" {
                return .failure(.unsupportedTransferEncoding)
            }

            if name == "content-length" {
                // 重复的 Content-Length 一律拒绝（即使两个值相同）：单一、严格的策略，
                // 不给「谁生效」留解释空间。
                guard !sawContentLength else { return .failure(.duplicateContentLength) }
                sawContentLength = true
                switch Self.parseContentLength(value) {
                case .success(let parsed): contentLength = parsed
                case .failure(let failure): return .failure(failure)
                }
            }

            headers[name] = value
        }

        return .success(ParsedHead(
            method: method, path: path, query: query,
            contentLength: contentLength, headers: headers
        ))
    }

    /// 严格解析 `Content-Length`：只接受 ASCII 数字；负数、正号、小数点、空值全部拒绝。
    /// 一旦超过 `maxBodyBytes` 立刻返回 413 —— 既避免溢出，也不给「先分配再判断」的机会。
    private static func parseContentLength(_ value: String) -> Result<Int, HeadParseFailure> {
        guard !value.isEmpty else { return .failure(.invalidContentLength) }
        var total = 0
        for byte in value.utf8 {
            guard byte >= 0x30, byte <= 0x39 else { return .failure(.invalidContentLength) }
            total = total * 10 + Int(byte - 0x30)
            if total > maxBodyBytes { return .failure(.payloadTooLarge) }
        }
        return .success(total)
    }

    /// RFC 7230 token：用作方法名与头字段名的字符集。
    private static func isValidToken(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.utf8.allSatisfy { byte in
            switch byte {
            case 0x21, 0x23...0x27, 0x2A...0x2B, 0x2D...0x2E,
                 0x30...0x39, 0x41...0x5A, 0x5E...0x7A, 0x7C, 0x7E:
                return true
            default:
                return false
            }
        }
    }

    private static func containsControlCharacters(_ text: String) -> Bool {
        text.utf8.contains { $0 < 0x20 || $0 == 0x7F }
    }

    // MARK: - Peer address

    /// 从连接对象取对端地址：`endpoint` 对入站连接即远端；再兜底 `currentPath`。
    /// 两者都拿不到就返回 nil（例如中继隧道），调用方会归入同一个限速桶。
    static func peerAddress(_ connection: NWConnection) -> String? {
        if case let .hostPort(host, _) = connection.endpoint {
            return normalize(host)
        }
        if let remote = connection.currentPath?.remoteEndpoint,
           case let .hostPort(host, _) = remote {
            return normalize(host)
        }
        return nil
    }

    private static func normalize(_ host: NWEndpoint.Host) -> String {
        var text = "\(host)"
        if let zone = text.firstIndex(of: "%") {
            text = String(text[..<zone])
        }
        if text.hasPrefix("::ffff:") {
            text = String(text.dropFirst("::ffff:".count))
        }
        return text
    }

    // MARK: - Responding

    private func respond(_ connection: NWConnection, _ response: HTTPResponse) {
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(response.body.count)\r\n"
        for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) {
            guard !name.contains("\r"), !name.contains("\n"),
                  !value.contains("\r"), !value.contains("\n") else { continue }
            head += "\(name): \(value)\r\n"
        }
        head += "Connection: close\r\n\r\n"

        var out = Data(head.utf8)
        out.append(response.body)
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
