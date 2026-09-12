import Foundation

enum AgentCommand {
    case status
    case send(text: String)
    /// 提交一条命令执行（`context` 携带对话上下文：绑定对话 / 工作目录 / 模型覆盖）。
    case submit(text: String, context: CommandContext?)
    case stopSession
    case startSession
}

/// 一条命令的对话上下文（与 Windows 端 command_runner 的解析语义一致）：
/// workdir / 模型覆盖均按「对话级覆盖 ?? Agent 全局偏好」在调用方解析后传入。
struct CommandContext {
    var conversationID: String?
    var workdir: String?
    var modelID: String?
    var providerID: String?
}

final class CommandRouter {
    /// 进程内唯一实例：HTTP 端与桌面端共用同一条串行执行队列，
    /// 命令不会因为入口不同而被乱序执行。
    static let shared = CommandRouter()

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
        case let .submit(text, context):
            return runner.submit(text, context: context)
        case .stopSession:
            return sessionManager.stopSession()
        case .startSession:
            return sessionManager.startSession()
        }
    }
}
