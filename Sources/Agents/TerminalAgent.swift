import Foundation

enum AgentError: Error, CustomStringConvertible {
    case ptyFailure(String)
    case startupTimeout
    case childDied(String)
    case notStarted
    case sendWriteFailed
    case echoNotConfirmed(String)
    case stopFailed(String)

    var description: String {
        switch self {
        case .ptyFailure(let m): return "PTY failure: \(m)"
        case .startupTimeout: return "OpenCode did not reach interactive state in time"
        case .childDied(let m): return "OpenCode exited unexpectedly: \(m)"
        case .notStarted: return "No active OpenCode session."
        case .sendWriteFailed: return "Failed to write message to PTY"
        case .echoNotConfirmed(let m): return "Message delivery could not be confirmed: \(m)"
        case .stopFailed(let m): return "Stop failed: \(m)"
        }
    }
}

protocol TerminalAgent: AnyObject {
    var sessionID: UUID { get }
    var pid: Int32? { get }
    var cwd: String { get }
    var isRunning: Bool { get }
    func start() throws
    func sendMessage(_ text: String) throws
    func stop() throws
}
