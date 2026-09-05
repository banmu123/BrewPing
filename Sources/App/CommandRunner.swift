import Foundation
import Darwin

final class CommandRunner {
    static let idleSeconds: TimeInterval = 2.5
    static let minResponseSeconds: TimeInterval = 3.0
    static let maxWaitSeconds: TimeInterval = 600
    static let pollIntervalMicros: useconds_t = 250_000

    private let sessionManager: SessionManager
    private let store: CommandStore
    private let queue = DispatchQueue(label: "BrewPing command runner", qos: .userInitiated)

    init(sessionManager: SessionManager, store: CommandStore = .shared) {
        self.sessionManager = sessionManager
        self.store = store
    }

    func submit(_ text: String) -> AgentResponse {
        guard let agent = sessionManager.activeAgent, agent.isRunning, let oc = agent as? OpenCodeAgent else {
            return AgentResponse.failure("OpenCode session is unavailable.")
        }
        let info = store.create(text: text, sessionId: agent.sessionID.uuidString)
        queue.async { [weak self] in
            self?.run(info, agent: oc)
        }
        var response = AgentResponse.success()
        response.status = CommandStatus.queued.rawValue
        response.sessionID = agent.sessionID.uuidString
        response.commandId = info.commandId
        return response
    }

    private func run(_ info: CommandInfo, agent: OpenCodeAgent) {
        guard agent.isRunning else {
            finish(info.commandId, status: .failed, error: "OpenCode session is unavailable.")
            return
        }
        guard let startOffset = agent.ptyOutputLength else {
            finish(info.commandId, status: .failed, error: "OpenCode session is unavailable.")
            return
        }
        store.update(info.commandId) { $0.status = .sent }
        do {
            try agent.sendMessage(info.text)
        } catch {
            finish(info.commandId, status: .failed, error: CommandRunner.friendly(error))
            return
        }
        store.update(info.commandId) { $0.status = .working }
        watch(commandId: info.commandId, text: info.text, agent: agent, startOffset: startOffset)
    }

    private func watch(commandId: String, text: String, agent: OpenCodeAgent, startOffset: Int) {
        let renderer = ScreenRenderer(rows: Int(PTYSession.rows), columns: Int(PTYSession.columns))
        var fed = startOffset
        var lastSnapshot: String? = nil
        var lastChange = Date()
        var sawChange = false
        let sentAt = Date()

        while true {
            guard agent.isRunning else {
                finish(commandId, status: .failed, error: "OpenCode session exited.")
                return
            }
            let newLength = agent.ptyOutputLength ?? fed
            if newLength > fed, let delta = agent.ptyText(from: fed) {
                var chunk = delta
                while let last = chunk.unicodeScalars.last, last == "\u{fffd}" {
                    chunk.unicodeScalars.removeLast()
                }
                renderer.feed(chunk)
            }
            fed = newLength

            let snapshot = renderer.snapshot
            if snapshot != lastSnapshot {
                lastSnapshot = snapshot
                lastChange = Date()
                sawChange = true
            }

            let extracted = ResponseExtractor.extract(rows: renderer.lines, sentText: text)
            if sawChange,
               Date().timeIntervalSince(lastChange) >= CommandRunner.idleSeconds,
               Date().timeIntervalSince(sentAt) >= CommandRunner.minResponseSeconds {
                if let result = extracted, !result.text.isEmpty {
                    finish(commandId, status: .completed, response: result.text)
                } else {
                    finish(commandId, status: .failed, error: "No readable OpenCode response was captured for this command.")
                }
                return
            }
            if Date().timeIntervalSince(sentAt) > CommandRunner.maxWaitSeconds {
                if let result = extracted, !result.text.isEmpty {
                    finish(commandId, status: .completed, response: result.text)
                } else {
                    finish(commandId, status: .failed, error: "Timed out waiting for OpenCode to finish.")
                }
                return
            }
            usleep(CommandRunner.pollIntervalMicros)
        }
    }

    private func finish(_ commandId: String, status: CommandStatus, response: String? = nil, error: String? = nil) {
        store.update(commandId) { info in
            info.status = status
            info.response = response
            info.error = error
            info.completedAt = (status == .completed || status == .failed) ? Date() : nil
        }
    }

    static func friendly(_ error: Error) -> String {
        guard let agentError = error as? AgentError else { return "\(error)" }
        switch agentError {
        case .notStarted:
            return "OpenCode session is unavailable."
        case .childDied:
            return "OpenCode session exited."
        default:
            return agentError.description
        }
    }
}
