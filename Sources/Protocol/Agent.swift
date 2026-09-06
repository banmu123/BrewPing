import Foundation

extension BrewPingProtocol {
    /// Agent 的执行模式。
    /// 迁移映射：与 CodingAgent.swift 的 session 型（OpenCode PTY）/ headless 型
    /// （HeadlessCLIAgent）划分一一对应。
    public enum AgentExecutionMode: String, Codable, Sendable {
        case session
        case headless
    }

    /// Agent 在协议层的运行状态。
    /// 迁移映射：现有 `AgentExecutionStatus`（queued/running/thinking/completed/failed）
    /// 描述的是"单次命令"；本状态描述"Agent 自身"。AgentManager/AgentDiscovery
    /// 上报时映射到此枚举。
    public enum AgentStatus: String, Codable, Sendable {
        case unknown
        case installed
        case idle
        case running
        case working
        case stopped
        case unavailable
    }

    /// 一个 AI Coding Agent（OpenCode / Claude Code / Codex / Aider / …）。
    ///
    /// 迁移映射：
    /// - `DetectedAgent`（AgentDiscovery）→ 本模型的静态发现视图
    ///   （installed/version/path）
    /// - `AgentManager.defaultAgentID` → 本模型的"被选中"状态
    public struct Agent: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        /// Agent 类型标识，与 discovery catalog 的 id 一致（opencode / claude-code / …）。
        public var type: String
        public var executionMode: AgentExecutionMode
        public var status: AgentStatus
        public var version: String?
        /// 扩展信息（如可执行文件路径、所属设备）。
        public var metadata: [String: String]

        public init(
            id: String,
            name: String,
            type: String,
            executionMode: AgentExecutionMode,
            status: AgentStatus,
            version: String? = nil,
            metadata: [String: String] = [:]
        ) {
            self.id = id
            self.name = name
            self.type = type
            self.executionMode = executionMode
            self.status = status
            self.version = version
            self.metadata = metadata
        }
    }
}
