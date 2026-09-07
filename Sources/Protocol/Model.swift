import Foundation

extension BrewPingProtocol {
    /// 模型提供商枚举。
    public enum ModelProvider: String, Codable, Sendable {
        case anthropic = "anthropic"
        case openai = "openai"
        case google = "google"
        case mistral = "mistral"
        case deepseek = "deepseek"
        case custom = "custom"
        case unknown = "unknown"
    }

    /// 一个具体的 AI 模型（如 Claude Sonnet、GPT-4o）。
    ///
    /// 与 Agent 概念分开：Agent = 工具（Claude Code），Model = 模型（Claude Sonnet）。
    /// 关系：Agent 可以使用多个 Model；Session 使用 Agent + Model。
    public struct AgentModel: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var provider: ModelProvider
        /// 是否实际可用（已配置 API Key 且可连接）。
        public var available: Bool
        /// 是否是该 Agent 的默认模型。
        public var isDefault: Bool

        public init(
            id: String,
            name: String,
            provider: ModelProvider = .unknown,
            available: Bool = true,
            isDefault: Bool = false
        ) {
            self.id = id
            self.name = name
            self.provider = provider
            self.available = available
            self.isDefault = isDefault
        }
    }
}
