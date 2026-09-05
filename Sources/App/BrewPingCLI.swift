import Foundation
import Darwin

enum BrewPingCLI {
    static func run(_ args: [String]) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        guard let cmd = args.first else { return usage() }
        switch cmd {
        case "start":
            return cmdStart()
        case "status":
            return cmdStatus()
        case "send":
            let text = args.dropFirst().joined(separator: " ")
            guard !text.isEmpty else {
                print("Usage: swift run BrewPing send \"<message>\"")
                return 1
            }
            return cmdSend(text)
        case "stop":
            return cmdStop()
        case "agent":
            BrewPingAgent.run()
        default:
            return usage()
        }
    }

    private static func usage() -> Int32 {
        print("""
        Usage: swift run BrewPing <command>
        Commands:
          start         Start OpenCode in a PTY session
          status        Show current session status
          send <text>   Send a message to the current OpenCode session
          stop          Stop the current OpenCode session
        """)
        return 1
    }

    private static func encodeRequest(_ request: AgentRequest) -> Data? {
        try? JSONEncoder().encode(request)
    }

    private static func decodeResponse(_ data: Data) -> AgentResponse? {
        try? JSONDecoder().decode(AgentResponse.self, from: data)
    }

    private static func requestStatus() -> AgentResponse? {
        guard let payload = encodeRequest(AgentRequest(cmd: "status", text: nil)) else { return nil }
        guard let data = UnixSocketClient.request(
            path: SessionManager.shared.socketPath,
            payload: payload,
            timeoutSeconds: 5
        ) else { return nil }
        return decodeResponse(data)
    }

    private static func cmdStart() -> Int32 {
        let store = SessionManager.shared

        if let resp = requestStatus(), resp.ok {
            if resp.status == SessionStatus.running.rawValue {
                print("OpenCode session already running.")
                print("Session: \(resp.sessionID ?? "?")")
                print("PID: \(resp.pid ?? 0)")
                return 0
            }
            let deadline = Date().addingTimeInterval(3)
            while requestStatus() != nil && Date() < deadline {
                usleep(200_000)
            }
        }

        if let info = store.load(), info.status == .starting, store.isAlive(info.agentPID) {
            print("OpenCode session is starting. Try again shortly.")
            return 0
        }

        try? FileManager.default.removeItem(at: store.stateFileURL)
        guard spawnDetachedAgent() else {
            print("ERROR: failed to launch BrewPing agent, see \(store.agentLogURL.path)")
            return 1
        }

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let info = store.load() {
                switch info.status {
                case .running:
                    print("OpenCode started")
                    print("Session: \(info.id.uuidString)")
                    print("PID: \(info.pid)")
                    if let port = info.httpPort {
                        print("HTTP API: http://\(info.httpIP ?? "127.0.0.1"):\(port) (dev use only)")
                    }
                    return 0
                case .failed:
                    print("ERROR: OpenCode failed to start, see \(store.agentLogURL.path)")
                    return 1
                default:
                    break
                }
            }
            usleep(200_000)
        }
        print("ERROR: agent did not report a running session in time, see \(store.agentLogURL.path)")
        return 1
    }

    private static func cmdStatus() -> Int32 {
        let store = SessionManager.shared

        if let resp = requestStatus(), resp.ok {
            print("OpenCode")
            print("Status: \(resp.status ?? "?")")
            print("PID: \(resp.pid ?? 0)")
            print("Session: \(resp.sessionID ?? "?")")
            if let info = store.load(), let port = info.httpPort {
                print("HTTP: http://\(info.httpIP ?? "127.0.0.1"):\(port) (dev use only)")
            }
            return resp.status == SessionStatus.running.rawValue ? 0 : 1
        }

        guard let info = store.load() else {
            print("No active OpenCode session.")
            return 1
        }
        let status = store.effectiveStatus(info)
        print("OpenCode")
        print("Status: \(status.rawValue)")
        print("PID: \(info.pid)")
        print("Session: \(info.id.uuidString)")
        return status == .running ? 0 : 1
    }

    private static func cmdSend(_ text: String) -> Int32 {
        let store = SessionManager.shared
        guard let payload = encodeRequest(AgentRequest(cmd: "send", text: text)) else {
            print("ERROR: failed to encode request")
            return 1
        }
        guard let responseData = UnixSocketClient.request(
            path: store.socketPath,
            payload: payload,
            timeoutSeconds: 60
        ) else {
            if let info = store.load(), store.effectiveStatus(info) == .starting {
                print("OpenCode session is starting. Try again shortly.")
            } else {
                print("No active OpenCode session.")
            }
            return 1
        }
        guard let resp = decodeResponse(responseData) else {
            print("ERROR: invalid agent response")
            return 1
        }
        guard resp.ok else {
            print("ERROR: \(resp.error ?? "unknown error")")
            return 1
        }
        print(resp.message ?? "Message sent")
        return 0
    }

    private static func cmdStop() -> Int32 {
        let store = SessionManager.shared
        guard let payload = encodeRequest(AgentRequest(cmd: "stop", text: nil)) else {
            print("ERROR: failed to encode request")
            return 1
        }
        guard let responseData = UnixSocketClient.request(
            path: store.socketPath,
            payload: payload,
            timeoutSeconds: 30
        ) else {
            print("No active OpenCode session.")
            return 1
        }
        guard let resp = decodeResponse(responseData), resp.ok else {
            print("ERROR: stop request rejected")
            return 1
        }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let info = store.load(), info.status == .exited {
                print("Session stopped")
                print("OpenCode exit code: \(info.exitCode.map(String.init) ?? "?")")
                return 0
            }
            usleep(200_000)
        }
        print("Session stopped, but exit confirmation timed out")
        return 1
    }

    private static func spawnDetachedAgent() -> Bool {
        let store = SessionManager.shared
        let execPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path

        var attr: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attr) == 0 else { return false }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            posix_spawnattr_destroy(&attr)
            return false
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, store.agentLogURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_addopen(&actions, 2, store.agentLogURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)

        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(execPath), strdup("agent"), nil]
        defer {
            for case let p? in argv { free(p) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, execPath, &actions, &attr, &argv, environ)
        posix_spawnattr_destroy(&attr)
        posix_spawn_file_actions_destroy(&actions)
        return rc == 0
    }
}
