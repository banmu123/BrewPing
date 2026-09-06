import Foundation
import Darwin

final class CommandRunner {
    static let idleSeconds: TimeInterval = 4.5
    static let minResponseSeconds: TimeInterval = 3.0
    static let maxWaitSeconds: TimeInterval = 600
    static let pollIntervalMicros: useconds_t = 250_000

    private let sessionManager: SessionManager
    private let store: CommandStore
    private let queue = DispatchQueue(label: "BrewPing command runner", qos: .userInitiated)
    private let headlessQueue = DispatchQueue(label: "BrewPing headless agent runner", qos: .userInitiated)

    init(sessionManager: SessionManager, store: CommandStore = .shared) {
        self.sessionManager = sessionManager
        self.store = store
    }

    func submit(_ text: String) -> AgentResponse {
        let defaultID = AgentManager.shared.defaultAgentID
        if defaultID != AgentManager.sessionAgentID {
            return submitHeadless(text: text, agentID: defaultID)
        }
        return submitOpenCodeSession(text: text)
    }

    private func submitOpenCodeSession(text: String) -> AgentResponse {
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

    private func submitHeadless(text: String, agentID: String) -> AgentResponse {
        guard let provider = AgentManager.shared.provider(for: agentID) else {
            return AgentResponse.failure("Unknown agent: \(agentID)")
        }
        guard provider.detect() != nil else {
            return AgentResponse.failure("Agent \(provider.name) is not installed on this Mac.")
        }
        let info = store.create(text: text, sessionId: "headless-\(agentID)")
        headlessQueue.async { [weak self] in
            self?.runHeadless(info, provider: provider)
        }
        var response = AgentResponse.success()
        response.status = CommandStatus.queued.rawValue
        response.sessionID = info.sessionId
        response.commandId = info.commandId
        return response
    }

    private func runHeadless(_ info: CommandInfo, provider: CodingAgent) {
        store.update(info.commandId) { $0.status = .working }
        let result = provider.execute(info.text)
        switch result.status {
        case .completed:
            store.update(info.commandId) { update in
                update.status = .completed
                update.response = result.output
                update.duration = result.durationSeconds
                update.completedAt = Date()
            }
        default:
            store.update(info.commandId) { update in
                update.status = .failed
                update.error = result.output.isEmpty ? "Agent execution failed." : String(result.output.prefix(2000))
                update.duration = result.durationSeconds
                update.completedAt = Date()
            }
        }
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
            let sessionDuration = ResponseExtractor.extractDuration(rows: renderer.lines)
            guard agent.isRunning else {
                finish(commandId, status: .failed, error: "OpenCode session exited.", duration: sessionDuration)
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

            let extracted = ResponseExtractor.extract(rows: renderer.lines, sentText: text, cwd: agent.cwd)
            if sawChange,
               Date().timeIntervalSince(lastChange) >= CommandRunner.idleSeconds,
               Date().timeIntervalSince(sentAt) >= CommandRunner.minResponseSeconds {
                finishAfterWait(commandId: commandId, extracted: extracted, renderer: renderer, cwd: agent.cwd)
                return
            }
            if Date().timeIntervalSince(sentAt) > CommandRunner.maxWaitSeconds {
                finishAfterWait(commandId: commandId, extracted: extracted, renderer: renderer, cwd: agent.cwd)
                return
            }
            usleep(CommandRunner.pollIntervalMicros)
        }
    }

    private func finishAfterWait(commandId: String, extracted: (text: String, complete: Bool)?, renderer: ScreenRenderer, cwd: String) {
        let duration = ResponseExtractor.extractDuration(rows: renderer.lines)
        if let result = extracted, !result.text.isEmpty {
            finish(commandId, status: .completed, response: result.text, duration: duration)
            return
        }
        if let raw = ResponseExtractor.fallbackRaw(rows: renderer.lines, cwd: cwd), !raw.isEmpty {
            finish(commandId, status: .completedWithRaw, rawOutput: raw, duration: duration)
            return
        }
        finish(commandId, status: .failed, error: "No readable OpenCode response was captured for this command.", duration: duration)
    }

    private func finish(_ commandId: String, status: CommandStatus, response: String? = nil, rawOutput: String? = nil, error: String? = nil, duration: TimeInterval? = nil) {
        store.update(commandId) { info in
            info.status = status
            info.response = response
            info.rawOutput = rawOutput
            info.error = error
            if let duration { info.duration = duration }
            info.completedAt = (status == .completed || status == .completedWithRaw || status == .failed) ? Date() : nil
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
