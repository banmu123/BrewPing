import Foundation

/// Agent 运行状态（Terminal UI 层使用）
public enum AgentStatus: String, Codable {
    case idle
    case running
    case error
    case stopped
}

/// Agent 基本信息
public struct AgentInfo: Codable, Identifiable {
    public let id: String
    public let name: String
    public var status: AgentStatus

    public init(id: String, name: String, status: AgentStatus = .idle) {
        self.id = id
        self.name = name
        self.status = status
    }
}
