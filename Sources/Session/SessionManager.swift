import Foundation

enum SessionStatus: String, Codable {
    case starting, running, exited, failed
}

struct SessionInfo: Codable {
    var id: UUID
    var pid: Int32
    var agentPID: Int32
    var cwd: String
    var status: SessionStatus
    var createdAt: Date
    var exitCode: Int32?
    var httpPort: Int?
    var httpIP: String?
}

final class SessionManager {
    static let shared = SessionManager()

    let directory: URL
    weak var activeAgent: TerminalAgent?

    var stateFileURL: URL { directory.appendingPathComponent("session.json") }
    var socketPath: String { directory.appendingPathComponent("agent.sock").path }
    var openCodeLogURL: URL { directory.appendingPathComponent("opencode.log") }
    var agentLogURL: URL { directory.appendingPathComponent("agent.log") }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        directory = home.appendingPathComponent(".brewping", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func load() -> SessionInfo? {
        guard let data = try? Data(contentsOf: stateFileURL) else { return nil }
        return try? JSONDecoder().decode(SessionInfo.self, from: data)
    }

    func save(_ info: SessionInfo) {
        guard let data = try? JSONEncoder().encode(info) else { return }
        try? data.write(to: stateFileURL, options: .atomic)
    }

    func setActiveAgent(_ agent: TerminalAgent) {
        activeAgent = agent
    }

    func currentStatus() -> AgentResponse {
        guard let agent = activeAgent else {
            return .failure("No active OpenCode session.")
        }
        return AgentResponse(
            ok: true,
            status: agent.isRunning ? SessionStatus.running.rawValue : SessionStatus.exited.rawValue,
            pid: agent.pid,
            sessionID: agent.sessionID.uuidString,
            cwd: agent.cwd,
            message: nil,
            error: nil
        )
    }

    func sendMessage(_ text: String) -> AgentResponse {
        guard let agent = activeAgent else {
            return .failure("No active OpenCode session.")
        }
        guard agent.isRunning else {
            return .failure("OpenCode is not running.")
        }
        do {
            try agent.sendMessage(text)
            return .success("Message sent")
        } catch {
            return .failure("\(error)")
        }
    }

    func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    func effectiveStatus(_ info: SessionInfo) -> SessionStatus {
        guard info.status == .running else { return info.status }
        return isAlive(info.pid) ? .running : .exited
    }
}
