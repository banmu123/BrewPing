import Foundation
import Darwin

enum UnixSocketError: Error {
    case failure(String)
}

final class UnixSocketServer {
    let path: String
    private let fd: Int32

    init(path: String) throws {
        self.path = path
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw UnixSocketError.failure("socket(): errno=\(errno)")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(103))
        let offset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 2
        withUnsafeMutableBytes(of: &addr) { raw in
            raw.baseAddress!.advanced(by: offset).copyMemory(from: bytes, byteCount: bytes.count)
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw UnixSocketError.failure("bind(): errno=\(errno)")
        }
        guard Darwin.listen(fd, 8) == 0 else {
            close(fd)
            throw UnixSocketError.failure("listen(): errno=\(errno)")
        }
    }

    func acceptConnection(timeoutSeconds: TimeInterval) -> Int32? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, Int32(timeoutSeconds * 1000)) > 0 else { return nil }
        let conn = Darwin.accept(fd, nil, nil)
        return conn >= 0 ? conn : nil
    }

    func closeServer() {
        unlink(path)
        close(fd)
    }
}

enum UnixSocketIO {
    static func recvLine(fd: Int32, timeoutSeconds: TimeInterval, maxBytes: Int = 1 << 20) -> Data? {
        var tv = timeval(tv_sec: Int(timeoutSeconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { return nil }
            if let idx = buf[0..<n].firstIndex(of: UInt8(ascii: "\n")) {
                data.append(contentsOf: buf[0..<idx])
                return data
            }
            data.append(contentsOf: buf[0..<n])
            if data.count > maxBytes { return nil }
        }
    }

    @discardableResult
    static func sendAll(fd: Int32, _ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return true }
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                send(fd, raw.baseAddress! + sent, bytes.count - sent, 0)
            }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
}

enum UnixSocketClient {
    static func request(path: String, payload: Data, timeoutSeconds: TimeInterval = 30) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(103))
        let offset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 2
        withUnsafeMutableBytes(of: &addr) { raw in
            raw.baseAddress!.advanced(by: offset).copyMemory(from: bytes, byteCount: bytes.count)
        }
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return nil }
        var line = payload
        line.append(UInt8(ascii: "\n"))
        guard UnixSocketIO.sendAll(fd: fd, line) else { return nil }
        return UnixSocketIO.recvLine(fd: fd, timeoutSeconds: timeoutSeconds)
    }
}
