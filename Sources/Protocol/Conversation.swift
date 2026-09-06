import Foundation

extension BrewPingProtocol {
    public enum MessageRole: String, Codable, Sendable {
        case user
        case assistant
        case system
    }

    /// 会话中的一条消息。
    public struct Message: Codable, Equatable, Sendable {
        public var id: String
        public var role: MessageRole
        public var content: String
        public var createdAt: Date

        public init(
            id: String = "msg_" + UUID().uuidString,
            role: MessageRole,
            content: String,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.role = role
            self.content = content
            self.createdAt = createdAt
        }
    }

    /// 用户与 AI 的一段交流记录（对应未来 iPhone 的 Chats 列表）。
    ///
    /// 迁移映射：当前命令文本（CommandInfo.text）与回复（response/rawOutput）
    /// 隐式构成"一问一答"；未来 Conversation 承载多轮，CommandStore 演进为投影。
    public struct Conversation: Codable, Equatable, Sendable {
        public var id: String
        public var sessionId: String
        public var title: String
        public var messages: [Message]
        public var createdAt: Date
        public var updatedAt: Date

        public init(
            id: String = "conv_" + UUID().uuidString,
            sessionId: String,
            title: String,
            messages: [Message] = [],
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.sessionId = sessionId
            self.title = title
            self.messages = messages
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        public mutating func append(role: MessageRole, content: String) {
            messages.append(Message(role: role, content: content))
            updatedAt = Date()
        }
    }
}
