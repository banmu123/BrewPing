import Foundation

public enum AgentExecutionStatus: String {
    case queued
    case running
    case thinking
    case completed
    case failed
}

public struct AgentResult {
    public let id: String
    public let agentID: String
    public let agentName: String
    public let status: AgentExecutionStatus
    public let summary: String
    public let filesChanged: [String]
    public let durationSeconds: TimeInterval
    public let output: String
}

public protocol CodingAgent: AnyObject {
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
