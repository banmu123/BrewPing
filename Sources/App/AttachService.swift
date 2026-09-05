import Foundation
import Darwin

enum AttachService {
    static let replayBytes = 131072
    static let pollMillis: Int32 = 20

    static func isAttachRequest(_ data: Data) -> Bool {
        guard let request = try? JSONDecoder().decode(AgentRequest.self, from: data) else { return false }
        return request.cmd == "attach"
    }

    static func spawn(fd: Int32, agent: OpenCodeAgent) {
        let thread = Thread {
            run(fd: fd, agent: agent)
        }
        thread.name = "BrewPing attach stream"
        thread.start()
    }

    private static func run(fd: Int32, agent: OpenCodeAgent?) {
        defer { close(fd) }
        guard let agent else {
            _ = UnixSocketIO.sendAll(fd: fd, attachError("OpenCode session is unavailable."))
            return
        }
        guard agent.isRunning, let session = agent.ptySessionRef, session.masterFD >= 0 else {
            _ = UnixSocketIO.sendAll(fd: fd, attachError("OpenCode session is unavailable."))
            return
        }
        var ack = Data("{\"ok\":true,\"sessionId\":\"".utf8)
        ack.append(contentsOf: agent.sessionID.uuidString.utf8)
        ack.append(contentsOf: Data("\",\"message\":\"attached\"}".utf8))
        ack.append(UInt8(ascii: "\n"))
        guard UnixSocketIO.sendAll(fd: fd, ack) else { return }

        var fed = session.outputLength
        let replayFrom = max(0, fed - replayBytes)
        if replayFrom < fed {
            guard UnixSocketIO.sendAll(fd: fd, Data(session.bytes(from: replayFrom))) else { return }
        }

        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            guard agent.isRunning else {
                _ = UnixSocketIO.sendAll(fd: fd, Data("\r\n[OpenCode session exited]\r\n".utf8))
                return
            }
            let newLength = session.outputLength
            if newLength > fed {
                let chunk = session.bytes(from: fed)
                fed = newLength
                guard UnixSocketIO.sendAll(fd: fd, Data(chunk)) else { return }
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, pollMillis)
            if ready > 0 {
                if pfd.revents & (Int16(POLLHUP) | Int16(POLLERR) | Int16(POLLNVAL)) != 0 { return }
                if pfd.revents & Int16(POLLIN) != 0 {
                    let n = recv(fd, &buf, buf.count, 0)
                    if n <= 0 { return }
                    let input = buf[0..<n]
                    if input.contains(0x04) {
                        _ = UnixSocketIO.sendAll(fd: fd, Data("\r\n".utf8))
                        return
                    }
                    guard forwardToPTY(session: session, bytes: Array(input)) else { return }
                }
            }
        }
    }

    private static func forwardToPTY(session: PTYSession, bytes: [UInt8]) -> Bool {
        return bytes.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var written = 0
            while written < bytes.count {
                let n = Darwin.write(session.masterFD, base + written, bytes.count - written)
                if n <= 0 { return false }
                written += n
            }
            return true
        }
    }

    private static func attachError(_ message: String) -> Data {
        var data = Data("{\"ok\":false,\"error\":\"".utf8)
        data.append(contentsOf: message.utf8)
        data.append(contentsOf: Data("\"}".utf8))
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
