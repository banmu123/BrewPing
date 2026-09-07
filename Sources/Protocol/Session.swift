import Foundation

extension BrewPingProtocol {
    /// Session 生命周期（协议层统一口径）。
    /// 迁移映射：
    /// - 旧 `CommandStatus`（queued/sent/working/completed/failed）→ 单次命令状态，
    ///   映射规则：sent+working → running，completed → completed，failed → failed
    /// - 旧 `SessionStatus`（starting/running/exited/failed）→ OpenCode PTY 会话状态，
    ///   映射规则：starting → created，running → running，exited → stopped，failed → failed
    public enum SessionLifecycle: String, Codable, Sendable {
        case created
        case queued
        case running
        case completed
        case failed
        case stopped
    }

    /// Session 运行模式。
    public enum SessionMode: String, Codable, Sendable {
        /// 常驻交互会话（OpenCode PTY，支持 attach）
        case interactive
        /// 挂载到常驻会话观察（brewping attach）
        case attach
        /// 一次性无头执行（Claude Code / Codex / Aider）
        case headless
    }

    /// 失败原因分类。从 CLI 输出中识别，不是猜测。
    public enum FailureReason: String, Codable, Sendable {
        case quotaExceeded = "quota_exceeded"
        case authenticationFailed = "authentication_failed"
        case rateLimited = "rate_limited"
        case networkError = "network_error"
        case providerError = "provider_error"
        case processExited = "process_exited"
        case timeout = "timeout"
        case modelUnavailable = "model_unavailable"
        case unknown = "unknown"

        /// 人机友好的说明文字。
        public var message: String {
            switch self {
            case .quotaExceeded: return "Model quota has been exceeded."
            case .authenticationFailed: return "API key authentication failed."
            case .rateLimited: return "Too many requests. Please wait and retry."
            case .networkError: return "Network connection to provider failed."
            case .providerError: return "Provider returned an error."
            case .processExited: return "Agent process exited unexpectedly."
            case .timeout: return "Command timed out."
            case .modelUnavailable: return "Selected model is not available."
            case .unknown: return "An unknown error occurred."
            }
        }
    }

    /// 一次 AI 执行上下文——BrewPing 最核心的数据。
    ///
    /// 例：用户说"修复登录页面"
    ///   → Device: MacBook Pro
    ///   → Agent: OpenCode
    ///   → Session: running
    ///
    /// 迁移映射：当前由 `SessionManager.SessionInfo`（PTY 会话）+
    /// `CommandStore.CommandInfo`（单次命令）两处分别表达；
    /// 未来统一为本模型，两处各自作为本模型的投影。
    public struct Session: Codable, Equatable, Sendable {
        public var id: String
        public var deviceId: String
        public var agentId: String
        /// 使用的模型 id（可选，兼容旧命令）。
        public var modelId: String?
        /// 会话所属工作目录 / 项目名（如 /Users/x/BrewPing → "BrewPing"）。
        public var project: String?
        public var status: SessionLifecycle
        public var mode: SessionMode
        /// 失败原因（仅当 status == .failed 时有值）。
        public var failureReason: FailureReason?
        public var createdAt: Date
        public var updatedAt: Date

        public init(
            id: String,
            deviceId: String,
            agentId: String,
            project: String? = nil,
            status: SessionLifecycle,
            mode: SessionMode,
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.deviceId = deviceId
            self.agentId = agentId
            self.project = project
            self.status = status
            self.mode = mode
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }
}
