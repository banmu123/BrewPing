import Foundation

extension BrewPingProtocol {
    /// 统一事件负载：四个域（device / agent / session / conversation）共用，
    /// 字段全部可选，按事件类型取用；未覆盖的扩展信息放 `extra`。
    public struct EventPayload: Codable, Equatable, Sendable {
        public var deviceId: String?
        public var agentId: String?
        public var sessionId: String?
        public var conversationId: String?
        public var messageId: String?
        public var status: String?
        public var content: String?
        public var extra: [String: String]

        public init(
            deviceId: String? = nil,
            agentId: String? = nil,
            sessionId: String? = nil,
            conversationId: String? = nil,
            messageId: String? = nil,
            status: String? = nil,
            content: String? = nil,
            extra: [String: String] = [:]
        ) {
            self.deviceId = deviceId
            self.agentId = agentId
            self.sessionId = sessionId
            self.conversationId = conversationId
            self.messageId = messageId
            self.status = status
            self.content = content
            self.extra = extra
        }
    }

    /// 统一事件信封。type 使用 EventType 常量（如 "session.updated"）。
    ///
    /// 为未来实时同步（WebSocket / Push / Relay）预留；
    /// 当前阶段仅定义结构，不改变任何现有同步方式。
    public struct Event: Codable, Equatable, Sendable {
        public var type: String
        public var timestamp: Date
        public var payload: EventPayload

        public init(type: String, payload: EventPayload, timestamp: Date = Date()) {
            self.type = type
            self.payload = payload
            self.timestamp = timestamp
        }

        // 便捷构造
        public static func deviceStatusChanged(
            deviceId: String, status: DeviceStatus
        ) -> Event {
            Event(
                type: EventType.deviceStatusChanged,
                payload: EventPayload(deviceId: deviceId, status: status.rawValue)
            )
        }

        public static func agentStatusChanged(
            agentId: String, status: AgentStatus
        ) -> Event {
            Event(
                type: EventType.agentStatusChanged,
                payload: EventPayload(agentId: agentId, status: status.rawValue)
            )
        }

        public static func sessionUpdated(
            sessionId: String, status: SessionLifecycle
        ) -> Event {
            Event(
                type: EventType.sessionUpdated,
                payload: EventPayload(sessionId: sessionId, status: status.rawValue)
            )
        }

        public static func sessionCompleted(sessionId: String, summary: String?) -> Event {
            Event(
                type: EventType.sessionCompleted,
                payload: EventPayload(sessionId: sessionId, status: SessionLifecycle.completed.rawValue, content: summary)
            )
        }

        public static func sessionFailed(sessionId: String, reason: String?) -> Event {
            Event(
                type: EventType.sessionFailed,
                payload: EventPayload(sessionId: sessionId, status: SessionLifecycle.failed.rawValue, content: reason)
            )
        }

        public static func messageAppended(
            conversationId: String, messageId: String, role: MessageRole, content: String
        ) -> Event {
            Event(
                type: EventType.messageAppended,
                payload: EventPayload(
                    conversationId: conversationId,
                    messageId: messageId,
                    content: content,
                    extra: ["role": role.rawValue]
                )
            )
        }
    }
}
