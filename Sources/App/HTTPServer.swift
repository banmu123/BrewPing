import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let body: Data
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
                guard let (method, path, contentLength) = Self.parseHead(headData) else {
                    self.respond(connection, .json(400, "Bad Request", ["success": false, "error": "malformed request"]))
                    return
                }
                var body = buf.subdata(in: headerEnd.upperBound..<buf.endIndex)
                if body.count >= contentLength {
                    body = body.prefix(contentLength)
                    let request = HTTPRequest(method: method, path: path, body: body)
                    self.respond(connection, self.handler(request))
                } else {
                    self.receiveBody(connection, method: method, path: path, contentLength: contentLength, buffer: body)
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

    private func receiveBody(
        _ connection: NWConnection,
        method: String,
        path: String,
        contentLength: Int,
        buffer: Data
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data {
                buf.append(data)
            }
            if buf.count >= contentLength {
                let body = buf.prefix(contentLength)
                let request = HTTPRequest(method: method, path: path, body: Data(body))
                self.respond(connection, self.handler(request))
                return
            }
            if error == nil, !isComplete {
                self.receiveBody(connection, method: method, path: path, contentLength: contentLength, buffer: buf)
            } else {
                connection.cancel()
            }
        }
    }

    private static func parseHead(_ headData: Data) -> (method: String, path: String, contentLength: Int)? {
        guard let head = String(data: headData, encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        var path = String(parts[1])
        if let queryStart = path.firstIndex(of: "?") {
            path = String(path[..<queryStart])
        }
        var contentLength = 0
        for line in lines {
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            if kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return (method, path, contentLength)
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
