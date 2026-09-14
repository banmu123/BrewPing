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

    static func json(_ status: Int, _ reason: String, _ object: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, reason: reason, body: data)
    }
}

final class HTTPServer {
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
        receiveHead(connection, buffer: Data())
    }

    private func receiveHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data {
                buf.append(data)
            }
            if let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headData = buf.subdata(in: buf.startIndex..<headerEnd.lowerBound)
                guard let head = Self.parseHead(headData) else {
                    self.respond(connection, .json(400, "Bad Request", ["success": false, "error": "malformed request"]))
                    return
                }
                var body = buf.subdata(in: headerEnd.upperBound..<buf.endIndex)
                if body.count >= head.contentLength {
                    body = body.prefix(head.contentLength)
                    let request = HTTPRequest(
                        method: head.method, path: head.path, query: head.query,
                        body: body, headers: head.headers
                    )
                    self.respond(connection, self.handler(request))
                } else {
                    self.receiveBody(
                        connection,
                        method: head.method,
                        path: head.path,
                        query: head.query,
                        headers: head.headers,
                        contentLength: head.contentLength,
                        buffer: body
                    )
                }
                return
            }
            if error == nil, !isComplete, buf.count < 1_048_576 {
                self.receiveHead(connection, buffer: buf)
            } else {
                connection.cancel()
            }
        }
    }

    /// 单个请求体上限：防异常/恶意超大 body 导致内存无限增长
    /// （业务上限 = 消息文本，8MB 已远超所需）。头部超过 1MB 同样放弃。
    private static let maxBodyBytes = 8 * 1_048_576

    private func receiveBody(
        _ connection: NWConnection,
        method: String,
        path: String,
        query: String?,
        headers: [String: String],
        contentLength: Int,
        buffer: Data
    ) {
        guard contentLength <= Self.maxBodyBytes, buffer.count <= Self.maxBodyBytes else {
            respond(connection, .json(413, "Payload Too Large", [
                "success": false,
                "error": "request body too large"
            ]))
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data {
                buf.append(data)
            }
            if buf.count > Self.maxBodyBytes {
                self.respond(connection, .json(413, "Payload Too Large", [
                    "success": false,
                    "error": "request body too large"
                ]))
                return
            }
            if buf.count >= contentLength {
                let body = buf.prefix(contentLength)
                let request = HTTPRequest(method: method, path: path, query: query, body: Data(body), headers: headers)
                self.respond(connection, self.handler(request))
                return
            }
            if error == nil, !isComplete {
                self.receiveBody(
                    connection,
                    method: method,
                    path: path,
                    query: query,
                    headers: headers,
                    contentLength: contentLength,
                    buffer: buf
                )
            } else {
                connection.cancel()
            }
        }
    }

    private struct ParsedHead {
        let method: String
        let path: String
        let query: String?
        let contentLength: Int
        let headers: [String: String]
    }

    private static func parseHead(_ headData: Data) -> ParsedHead? {
        guard let head = String(data: headData, encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        var path = String(parts[1])
        var query: String?
        if let queryStart = path.firstIndex(of: "?") {
            query = String(path[path.index(after: queryStart)...])
            path = String(path[..<queryStart])
        }

        var contentLength = 0
        var headers: [String: String] = [:]
        for line in lines {
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let name = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers[name] = value
            if name == "content-length" {
                contentLength = Int(value) ?? 0
            }
        }
        return ParsedHead(method: method, path: path, query: query, contentLength: contentLength, headers: headers)
    }

    private func respond(_ connection: NWConnection, _ response: HTTPResponse) {
        let head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(response.body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(response.body)
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
