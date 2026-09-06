import Foundation

enum AgentExecutionStatus: String {
    case queued
    case running
    case thinking
    case completed
    case failed
}

struct AgentResult {
    let id: String
    let agentID: String
    let agentName: String
    let status: AgentExecutionStatus
    let summary: String
    let filesChanged: [String]
    let durationSeconds: TimeInterval
    let output: String
}

/// 统一的 Coding Agent 抽象（Adapter Pattern）。
/// - session 型 Provider（OpenCode）：常驻 PTY 会话，由 SessionManager/CommandRunner 既有链路负责。
/// - headless 型 Provider（Claude/Codex/Aider）：一次性 CLI 调用，execute 同步阻塞返回。
protocol CodingAgent: AnyObject {
    var id: String { get }
    var name: String { get }
    var isSessionCapable: Bool { get }
    var executionTimeoutSeconds: TimeInterval { get }

    /// 通过 AgentDiscovery 检测安装情况，返回 nil 表示未安装。
    func detect() -> DetectedAgent?

    /// 执行一条命令，同步阻塞直到完成或超时。
    func execute(_ command: String) -> AgentResult
}

extension CodingAgent {
    var isSessionCapable: Bool { false }
    var executionTimeoutSeconds: TimeInterval { 600 }
}
