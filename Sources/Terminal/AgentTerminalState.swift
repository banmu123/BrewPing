import Foundation
import Combine

/// 输出类型
public enum OutputType: String, Codable {
    case normal
    case error
    case system
}

/// 单行输出
public struct OutputLine: Identifiable {
    public let id = UUID()
    public let text: String
    public let type: OutputType
    public let timestamp: Date

    public init(text: String, type: OutputType = .normal, timestamp: Date = Date()) {
        self.text = text
        self.type = type
        self.timestamp = timestamp
    }
}

/// 每个 Agent 的独立终端状态
public final class AgentTerminalState: ObservableObject {
    public let agentId: String
    @Published public var outputLines: [OutputLine] = []
    @Published public var status: AgentStatus = .idle

    /// 最大输出行数，超出时裁剪头部
    public static let maxLines = 5000

    public init(agentId: String) {
        self.agentId = agentId
    }

    public func appendLine(_ text: String, type: OutputType = .normal) {
        outputLines.append(OutputLine(text: text, type: type))
        if outputLines.count > Self.maxLines {
            outputLines.removeFirst(outputLines.count - Self.maxLines)
        }
    }

    public func setStatus(_ newStatus: AgentStatus) {
        status = newStatus
    }

    public func clearOutput() {
        outputLines.removeAll()
    }
}
