import Foundation

enum AgentCommand {
    case status
    case send(text: String)
    case submit(text: String)
    case stopSession
    case startSession
}

final class CommandRouter {
    private let sessionManager: SessionManager
    private let runner: CommandRunner
    private let workQueue = DispatchQueue(label: "BrewPing command router")

    init(sessionManager: SessionManager = .shared) {
        self.sessionManager = sessionManager
        self.runner = CommandRunner(sessionManager: sessionManager)
    }

    func route(_ command: AgentCommand) -> AgentResponse {
        switch command {
        case .status:
            return sessionManager.currentStatus()
        case .send(let text):
            return workQueue.sync { sessionManager.sendMessage(text) }
        case .submit(let text):
            return runner.submit(text)
        case .stopSession:
            return sessionManager.stopSession()
        case .startSession:
            return sessionManager.startSession()
        }
    }
}
