import Foundation

// ─── 厂商预设目录（对齐 Windows `services/provider_catalog.rs`）─────────────────
//
// 纯静态表、零 IO：用于「添加厂商」表单的预设填充、models_url（拉取模型）匹配、
// 以及控制台/官网链接。**与 Windows 端 CATALOG 逐条对齐**（id / baseUrl /
// modelsUrl / category / models 列表），改一处必须两端同批。

public struct ProviderCatalogEntry: Codable, Identifiable, Equatable {
    public let id: String
    /// 英文名（Windows `name`）
    public let name: String
    /// 中文名（Windows `displayName`）
    public let displayName: String
    public let baseUrl: String
    public let apiFormat: String
    public let authStyle: String
    public let models: [String]
    public let modelsUrl: String
    public let consoleUrl: String
    public let websiteUrl: String
    public let category: String
}

public enum ProviderCatalog {
    /// 分类排序权重（custom 恒最后；未识别分类居中）
    public static func categoryOrder(_ category: String) -> Int {
        switch category {
        case "official": return 0
        case "cn_official": return 1
        case "aggregator": return 2
        case "third_party": return 3
        case "custom": return 99
        default: return 50
        }
    }

    public static let all: [ProviderCatalogEntry] = [
        ProviderCatalogEntry(
            id: "kimi", name: "Kimi (Moonshot)", displayName: "Kimi（月之暗面）",
            baseUrl: "https://api.moonshot.cn/anthropic", apiFormat: "anthropic", authStyle: "bearer",
            models: ["kimi-k3", "kimi-k2-turbo-preview", "kimi-latest"],
            modelsUrl: "https://api.moonshot.cn/v1/models",
            consoleUrl: "https://platform.moonshot.cn/console/api-keys",
            websiteUrl: "https://platform.moonshot.cn", category: "cn_official"
        ),
        ProviderCatalogEntry(
            id: "deepseek", name: "DeepSeek", displayName: "DeepSeek（深度求索）",
            baseUrl: "https://api.deepseek.com/anthropic", apiFormat: "anthropic", authStyle: "bearer",
            models: ["deepseek-v4-pro[1m]", "deepseek-chat", "deepseek-reasoner"],
            modelsUrl: "https://api.deepseek.com/models",
            consoleUrl: "https://platform.deepseek.com/api_keys",
            websiteUrl: "https://platform.deepseek.com", category: "cn_official"
        ),
        ProviderCatalogEntry(
            id: "zhipu", name: "GLM (Zhipu)", displayName: "GLM（智谱）",
            baseUrl: "https://open.bigmodel.cn/api/anthropic", apiFormat: "anthropic", authStyle: "bearer",
            models: ["glm-5.1", "glm-4.7", "glm-4.6"],
            modelsUrl: "https://open.bigmodel.cn/api/paas/v4/models",
            consoleUrl: "https://open.bigmodel.cn/usercenter/apikeys",
            websiteUrl: "https://open.bigmodel.cn", category: "cn_official"
        ),
        ProviderCatalogEntry(
            id: "xiaomi", name: "MiMo (Xiaomi)", displayName: "MiMo（小米）",
            baseUrl: "https://api.xiaomimimo.com/anthropic", apiFormat: "anthropic", authStyle: "bearer",
            models: ["mimo-v2.5-pro"],
            modelsUrl: "https://api.xiaomimimo.com/v1/models",
            consoleUrl: "https://platform.xiaomimimo.com/console/api-keys",
            websiteUrl: "https://platform.xiaomimimo.com", category: "cn_official"
        ),
        ProviderCatalogEntry(
            id: "minimax", name: "MiniMax", displayName: "MiniMax（稀宇）",
            baseUrl: "https://api.minimaxi.com/anthropic", apiFormat: "anthropic", authStyle: "bearer",
            models: ["MiniMax-M3"],
            modelsUrl: "https://api.minimaxi.com/v1/models",
            consoleUrl: "https://platform.minimaxi.com/user-center/basic-information/interface-key",
            websiteUrl: "https://platform.minimaxi.com", category: "cn_official"
        ),
        ProviderCatalogEntry(
            id: "custom", name: "Custom", displayName: "自定义 / 中转站",
            baseUrl: "", apiFormat: "anthropic", authStyle: "auto",
            models: [], modelsUrl: "",
            consoleUrl: "", websiteUrl: "", category: "custom"
        ),
    ]

    /// 按 baseURL 匹配预设（用于「拉取模型」找 models_url；匹配不到就不猜端点）。
    public static func matchByBaseUrl(_ baseUrl: String) -> ProviderCatalogEntry? {
        let normalized = baseUrl.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard !normalized.isEmpty else { return nil }
        return all.first { entry in
            guard !entry.modelsUrl.isEmpty else { return false }
            let entryBase = entry.baseUrl.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            return entryBase.caseInsensitiveCompare(normalized) == .orderedSame
        }
    }

    /// 生效端点预览（镜像 Windows `previewEndpoint` / 后端拼接逻辑）。
    public static func previewEndpoint(baseUrl: String, apiFormat: String, isFullUrl: Bool) -> String {
        let base = baseUrl.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        if base.isEmpty { return "—" }
        if isFullUrl { return base }
        switch apiFormat {
        case "openai_chat":
            if base.hasSuffix("/chat/completions") { return base }
            if base.hasSuffix("/v1") { return base + "/chat/completions" }
            return base + "/v1/chat/completions"
        case "openai_responses":
            return base + "/v1/responses"
        default:
            return base + "/v1/messages"
        }
    }
}
