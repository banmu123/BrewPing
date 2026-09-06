import Foundation

/// BrewPing Protocol Layer（协议层统一入口 / index）
///
/// 所有端（iPhone / Apple Watch / macOS Agent / 未来 Windows·Linux Agent）
/// 共用的核心数据结构。目标数据关系：
///
///     Device → Agent → Session → Conversation → Messages
///
/// 命名空间设计：所有类型嵌套在 `BrewPingProtocol` 之下（各文件通过
/// extension 展开），避免与 Mac Agent 既有同名类型冲突
/// （如 SessionManager.swift 的 `SessionStatus`、CommandStore.swift 的
/// `CommandStatus`、CodingAgent.swift 的 `AgentExecutionStatus`）。
///
/// 迁移原则：本层只新增类型，不替换旧类型；旧类型到协议类型的映射
/// 见各模型文件的迁移注释与 Migration Plan。
public enum BrewPingProtocol {}

/// 事件类型常量（"domain.action" 命名）。
/// 供未来实时同步通道（WebSocket / Push / Relay）直接复用。
extension BrewPingProtocol {
    public enum EventType {
        // device.*
        public static let deviceStatusChanged = "device.statusChanged"

        // agent.*
        public static let agentDiscovered = "agent.discovered"
        public static let agentStatusChanged = "agent.statusChanged"

        // session.*
        public static let sessionCreated = "session.created"
        public static let sessionUpdated = "session.updated"
        public static let sessionCompleted = "session.completed"
        public static let sessionFailed = "session.failed"

        // conversation.*
        public static let conversationCreated = "conversation.created"
        public static let conversationUpdated = "conversation.updated"
        public static let messageAppended = "message.appended"
    }
}
