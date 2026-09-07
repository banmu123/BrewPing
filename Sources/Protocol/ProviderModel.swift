import Foundation

// MARK: - Provider

extension BrewPingProtocol {
    /// 一个模型提供方（如 Xiaomi MiMo、OpenRouter、自定义代理）。
    /// 嵌套在 Agent 下：Agent → Providers → Models。
    public struct Provider: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var baseURL: String?
        public var models: [Model]

        public init(
            id: String,
            name: String,
            baseURL: String? = nil,
            models: [Model] = []
        ) {
            self.id = id
            self.name = name
            self.baseURL = baseURL
            self.models = models
        }
    }

    /// 一个具体模型。
    public struct Model: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var providerId: String
        public var available: Bool
        /// 是否是该 Provider 当前活跃的模型。
        public var isActive: Bool

        public init(
            id: String,
            name: String,
            providerId: String,
            available: Bool = true,
            isActive: Bool = false
        ) {
            self.id = id
            self.name = name
            self.providerId = providerId
            self.available = available
            self.isActive = isActive
        }
    }
}
