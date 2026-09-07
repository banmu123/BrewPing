import Foundation
import Darwin

struct AgentRequest: Codable {
    var cmd: String
    var text: String?
}

struct AgentResponse: Codable {
    var ok: Bool
    var status: String?
    var pid: Int32?
    var sessionID: String?
    var cwd: String?
    var message: String?
    var error: String?
    var commandId: String? = nil

    static func success(_ message: String? = nil) -> AgentResponse {
        AgentResponse(ok: true, status: nil, pid: nil, sessionID: nil, cwd: nil, message: message, error: nil)
    }

    static func failure(_ error: String) -> AgentResponse {
        AgentResponse(ok: false, status: nil, pid: nil, sessionID: nil, cwd: nil, message: nil, error: error)
    }
}

enum BrewPingAgent {
    static let httpPort: UInt16 = 8787

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        setbuf(stdout, nil)
        let store = SessionManager.shared
        let agent = OpenCodeAgent()
        let router = CommandRouter()
        store.setActiveAgent(agent)

        var info = SessionInfo(
            id: agent.sessionID,
            pid: 0,
            agentPID: getpid(),
            cwd: agent.cwd,
            status: .starting,
            createdAt: Date(),
            exitCode: nil,
            httpPort: nil,
            httpIP: nil
        )
        store.save(info)

        do {
            try agent.start()
        } catch {
            info.status = .failed
            store.save(info)
            exit(1)
        }

        info.pid = agent.pid ?? 0
        info.status = .running
        store.save(info)

        let http: HTTPServer?
        do {
            let lan = LANAddress.primaryLAN()
            let server = HTTPServer(port: httpPort, lanInterface: lan?.nwInterface) { request in
                HTTPAPI.handle(request, router: router)
            }
            let result = try server.start()
            info.httpPort = Int(result.port)
            info.httpIP = result.boundToLAN ? lan?.ip : nil
            store.save(info)
            let identity = DeviceIdentity.loadOrCreate()
            let deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            print("HTTP API: http://\(lan?.ip ?? "0.0.0.0"):\(result.port) (dev use only, bound: \(result.boundToLAN ? "LAN interface \(lan?.interfaceName ?? "?")" : "all interfaces"))")
            http = server
            BonjourAdvertiser.start(port: result.port, deviceId: identity.deviceId, deviceName: deviceName)
        } catch {
            print("WARNING: HTTP API unavailable: \(error)")
            http = nil
        }

        let server: UnixSocketServer
        do {
            server = try UnixSocketServer(path: store.socketPath)
        } catch {
            info.status = .failed
            store.save(info)
            http?.stop()
            exit(1)
        }

        var stopRequested = false
        var sessionDownReported = false
        while !stopRequested {
            if let current = store.activeAgent, !current.isRunning {
                if !sessionDownReported {
                    var latest = store.load() ?? info
                    latest.status = .exited
                    latest.exitCode = (current as? OpenCodeAgent)?.currentExitCode
                    store.save(latest)
                    info = latest
                    sessionDownReported = true
                    print("OpenCode session exited (code \(latest.exitCode.map(String.init) ?? "?")); agent standing by")
                }
            } else if store.activeAgent?.isRunning == true {
                sessionDownReported = false
            }
            guard let conn = server.acceptConnection(timeoutSeconds: 1) else { continue }
            guard let requestData = UnixSocketIO.recvLine(fd: conn, timeoutSeconds: 120) else {
                close(conn)
                continue
            }
            if AttachService.isAttachRequest(requestData) {
                if let current = store.activeAgent as? OpenCodeAgent {
                    AttachService.spawn(fd: conn, agent: current)
                } else {
                    _ = UnixSocketIO.sendAll(fd: conn, Data("{\"ok\":false,\"error\":\"OpenCode session is unavailable.\"}\n".utf8))
                    close(conn)
                }
                continue
            }
            defer { close(conn) }
            let response = handle(requestData: requestData, router: router, stopRequested: &stopRequested)
            guard let responseData = try? JSONEncoder().encode(response) else { continue }
            var line = responseData
            line.append(UInt8(ascii: "\n"))
            UnixSocketIO.sendAll(fd: conn, line)
        }

        if let current = store.activeAgent as? OpenCodeAgent {
            try? current.stop()
        }
        BonjourAdvertiser.stop()
        var latest = store.load() ?? info
        latest.status = .exited
        latest.exitCode = (store.activeAgent as? OpenCodeAgent)?.lastExitCode
        store.save(latest)
        server.closeServer()
        http?.stop()
        exit(0)
    }

    private static func handle(
        requestData: Data,
        router: CommandRouter,
        stopRequested: inout Bool
    ) -> AgentResponse {
        guard let request = try? JSONDecoder().decode(AgentRequest.self, from: requestData) else {
            return .failure("bad request")
        }
        switch request.cmd {
        case "status":
            return router.route(.status)
        case "send":
            guard let text = request.text, !text.isEmpty else {
                return .failure("missing message text")
            }
            return router.route(.send(text: text))
        case "start":
            return router.route(.startSession)
        case "stop":
            stopRequested = true
            return .success("stopping")
        default:
            return .failure("unknown command: \(request.cmd)")
        }
    }
}
