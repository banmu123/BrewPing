import Foundation
import Darwin

nonisolated(unsafe) private var attachOriginalTermios: termios?
nonisolated(unsafe) private var attachTerminalIsRaw = false

private func attachRestoreTerminal() {
    if attachTerminalIsRaw, var original = attachOriginalTermios {
        _ = tcsetattr(0, TCSANOW, &original)
        attachTerminalIsRaw = false
    }
}

private func attachSignalHandler(_ signal: Int32) {
    attachRestoreTerminal()
    _exit(1)
}

enum AttachCLI {
    static let detachByte: UInt8 = 0x04

    static func run() -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        guard let status = BrewPingCLI.requestStatus(), status.ok,
              status.status == SessionStatus.running.rawValue else {
            if let info = SessionManager.shared.load(),
               SessionManager.shared.effectiveStatus(info) == .starting {
                print("OpenCode session is starting. Try again shortly.")
            } else {
                print("No active OpenCode session.")
            }
            return 1
        }

        guard let fd = UnixSocketClient.connect(path: SessionManager.shared.socketPath) else {
            print("No active OpenCode session.")
            return 1
        }
        defer { close(fd) }

        var request = Data("{\"cmd\":\"attach\"}".utf8)
        request.append(UInt8(ascii: "\n"))
        guard UnixSocketIO.sendAll(fd: fd, request) else {
            print("ERROR: failed to send attach request")
            return 1
        }
        let ackData = UnixSocketIO.recvLine(fd: fd, timeoutSeconds: 10)
        let ackObject = ackData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard let ackObject, ackObject["ok"] as? Bool == true else {
            if let error = ackObject?["error"] as? String {
                print("ERROR: \(error)")
            } else {
                print("ERROR: attach request rejected")
            }
            return 1
        }
        let sessionID = ackObject["sessionId"] as? String ?? "?"

        let interactive = isatty(0) == 1
        if interactive {
            var original = termios()
            guard tcgetattr(0, &original) == 0 else {
                print("ERROR: failed to read terminal attributes")
                return 1
            }
            attachOriginalTermios = original
            var raw = original
            cfmakeraw(&raw)
            tcsetattr(0, TCSANOW, &raw)
            attachTerminalIsRaw = true
            signal(SIGHUP, attachSignalHandler)
            signal(SIGTERM, attachSignalHandler)
            signal(SIGINT, SIG_IGN)
        }

        let header = "Attached to session \(String(sessionID.prefix(8))) (Ctrl+D to detach)\r\n"
        _ = header.withCString { bytes -> Int in
            Darwin.write(1, bytes, strlen(bytes))
        }

        let exitMessage = streamLoop(fd: fd)
        attachRestoreTerminal()
        print("")
        print(exitMessage)
        return exitMessage == "Detached." ? 0 : 1
    }

    private static func streamLoop(fd: Int32) -> String {
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            var pfds = [
                pollfd(fd: 0, events: Int16(POLLIN), revents: 0),
                pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            ]
            let ready = poll(&pfds, 2, -1)
            if ready <= 0 {
                if errno == EINTR { continue }
                return "[attach error: poll failed]"
            }
            if pfds[0].revents & (Int16(POLLIN) | Int16(POLLHUP) | Int16(POLLERR)) != 0 {
                let n = read(0, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return "Detached." }
                let input = Array(buf[0..<n])
                if let eot = input.firstIndex(of: AttachCLI.detachByte) {
                    if eot > 0 {
                        _ = UnixSocketIO.sendAll(fd: fd, Data(input[0..<eot]))
                    }
                    return "Detached."
                }
                guard UnixSocketIO.sendAll(fd: fd, Data(input)) else {
                    return "[attach error: connection to agent lost]"
                }
            }
            if pfds[1].revents & (Int16(POLLIN) | Int16(POLLHUP) | Int16(POLLERR)) != 0 {
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 {
                    return "[OpenCode session exited or agent stopped]"
                }
                var written = 0
                while written < n {
                    let w = buf.withUnsafeBytes { raw -> Int in
                        Darwin.write(1, raw.baseAddress! + written, n - written)
                    }
                    if w <= 0 { return "[attach error: stdout write failed]" }
                    written += w
                }
            }
        }
    }
}
