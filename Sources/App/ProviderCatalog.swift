import Foundation

// ─── 厂商预设目录（对齐 Windows `services/provider_catalog.rs`）─────────────────
//
// 纯静态表、零 IO：用于「添加厂商」表单的预设填充、models_url（拉取模型）匹配、
// 以及控制台/官网链接。**与 Windows 端 CATALOG 逐条对齐**（id / baseUrl /
// modelsUrl / category / models 列表 / per-agent endpoints），改一处必须两端同批。
//
// 🔴 **端点按 agent 分派**（2026-09-14 对齐 cc-switch 源码实证，与 Windows 同批）：
// 同一厂商在不同 agent 下 baseURL 与协议不同 ——
//   - `/anthropic` 子路径**只属于 Claude Code**（Anthropic Messages 兼容层）；
//   - Codex 一律 OpenAI 系端点，且 `wire_api="responses"`（新版 Codex 已废弃 chat）；
//   - OpenCode / pi 走 OpenAI 兼容 Chat 端点（`@ai-sdk/openai-compatible` /
//     `openai-completions`）。
// 顶层 `baseUrl`/`apiFormat` 是**转发代理语义**（Anthropic 端点），只有
// 「BrewPing 自有库」表单（ModelProviderFormView）使用；四个 CLI 表单一律用
// `resolvePresetEndpoint` 按 agent 解析。

/// 单个 agent 的端点形态（= Windows `AgentEndpoint`）。
public struct ProviderCatalogEndpoint: Codable, Equatable {
    /// agent 标识：`claude-code` / `codex` / `opencode` / `pi`。
    public var agent: String
    /// 该 agent 应使用的 base_url。
    public var baseUrl: String
    /// Codex 专属：`wire_api` 取值（其余 agent 为空串）。
    public var wireApi: String
    /// OpenCode 专属：npm SDK 包名（其余 agent 为空串）。
    public var npm: String
    /// pi 专属：`api` 协议值（其余 agent 为空串）。
    public var piApi: String

    public init(agent: String, baseUrl: String, wireApi: String = "", npm: String = "", piApi: String = "") {
        self.agent = agent
        self.baseUrl = baseUrl
        self.wireApi = wireApi
        self.npm = npm
        self.piApi = piApi
    }
}

public struct ProviderCatalogEntry: Codable, Identifiable, Equatable {
    public let id: String
    /// 英文名（Windows `name`）
    public let name: String
    /// 中文名（Windows `displayName`）
    public let displayName: String
    /// 预填 base_url（**转发代理语义** = Anthropic 端点；CLI 表单应改用 endpoints）。
    public let baseUrl: String
    public let apiFormat: String
    public let authStyle: String
    /// 各 agent 专属端点（custom 为空表；缺失时回落顶层模板）。
    public let endpoints: [ProviderCatalogEndpoint]
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

    /// 便捷构造：一个厂商的四个 agent 端点一次写齐（协议字段按 agent 固定，
    /// 与 Windows `agent_endpoints!` 宏同款）。
    private static func endpoints(_ claude: String, _ codex: String,
                                  _ opencode: String, _ pi: String) -> [ProviderCatalogEndpoint] {
        [
            ProviderCatalogEndpoint(agent: "claude-code", baseUrl: claude),
            ProviderCatalogEndpoint(agent: "codex", baseUrl: codex, wireApi: "responses"),
            ProviderCatalogEndpoint(agent: "opencode", baseUrl: opencode, npm: "@ai-sdk/openai-compatible"),
            ProviderCatalogEndpoint(agent: "pi", baseUrl: pi, piApi: "openai-completions"),
        ]
    }

    public static let all: [ProviderCatalogEntry] = [
        ProviderCatalogEntry(
            id: "kimi", name: "Kimi (Moonshot)", displayName: "Kimi（月之暗面）",
            baseUrl: "https://api.moonshot.cn/anthropic", apiFormat: "anthropic", authStyle: "bearer",
            endpoints: endpoints(
                "https://api.moonshot.cn/anthropic",
                "https://api.moonshot.cn/v1",
                "https://api.moonshot.cn/v1",
                "https://api.moonshot.cn/v1"
            ),
            models: ["kimi-k3", "kimi-k2-turbo-preview", "kimi-latest"],
            modelsUrl: "https://api.moonshot.cn/v1/models",
            consoleUrl: "https://platform.moonshot.cn/console/api-keys",
            websiteUrl: "https://www.moonshot.cn", category: "cn_official"
        ),
        ProviderCatalogEntry(
            id: "deepseek", name: "DeepSeek", displayName: "DeepSeek（深度求索）",
            // 🔴 codex 用**裸域**（官方 Codex 接入文档：deepseek-v4 系原生
            // Responses，wire_api="responses" 直连裸域，无需 /v1 也无需 /anthropic）
            baseUrl: "https://api.deepseek.com/anthropic", apiFormat: "anthropic", authStyle: "bearer",
            endpoints: endpoints(
                "https://api.deepseek.com/anthropic",
                "https://api.deepseek.com",
                "https://api.deepseek.com/v1",
                "https://api.deepseek.com/v1"
            ),
            models: ["deepseek-v4-pro[1m]", "deepseek-chat", "deepseek-reasoner"],
            modelsUrl: "https://api.deepseek.com/models",
            consoleUrl: "https://platform.deepseek.com/api_keys",
            websiteUrl: "https://platform.deepseek.com", category: "cn_official"
        ),
        ProviderCatalogEntry(
            id: "zhipu", name: "GLM (Zhipu)", displayName: "GLM（智谱）",
            // 🔴 智谱三端点分立（官方明示「错误配置端点将无法使用套餐额度」）：
            // Anthropic=/api/anthropic、OpenAI Responses(codex)=/api/v1、
            // OpenAI Chat(opencode/pi)=/api/coding/paas/v4
            baseUrl: "https://open.bigmodel.cn/api/anthropic", apiFormat: "anthropic", authStyle: "bearer",
            endpoints: endpoints(
                "https://open.bigmodel.cn/api/anthropic",
                "https://open.bigmodel.cn/api/v1",
                "https://open.bigmodel.cn/api/coding/paas/v4",
                "https://open.bigmodel.cn/api/coding/paas/v4"
            ),
            models: ["glm-5.1", "glm-4.7", "glm-4.6"],
            modelsUrl: "https://open.bigmodel.cn/api/paas/v4/models",
            consoleUrl: "https://open.bigmodel.cn/usercenter/apikeys",
            websiteUrl: "https://open.bigmodel.cn", category: "cn_official"
        ),
        ProviderCatalogEntry(
            id: "xiaomi", name: "MiMo (Xiaomi)", displayName: "MiMo（小米）",
            baseUrl: "https://api.xiaomimimo.com/anthropic", apiFormat: "anthropic", authStyle: "bearer",
            endpoints: endpoints(
                "https://api.xiaomimimo.com/anthropic",
                "https://api.xiaomimimo.com/v1",
                "https://api.xiaomimimo.com/v1",
                "https://api.xiaomimimo.com/v1"
            ),
            models: ["mimo-v2.5-pro"],
            modelsUrl: "https://api.xiaomimimo.com/v1/models",
            consoleUrl: "https://platform.xiaomimimo.com/console/api-keys",
            websiteUrl: "https://platform.xiaomimimo.com", category: "cn_official"
        ),
        ProviderCatalogEntry(
            id: "minimax", name: "MiniMax", displayName: "MiniMax（稀宇）",
            // 国内正式域名 api.minimaxi.com（多一个 i；api.minimax.chat 是旧域名）
            baseUrl: "https://api.minimaxi.com/anthropic", apiFormat: "anthropic", authStyle: "bearer",
            endpoints: endpoints(
                "https://api.minimaxi.com/anthropic",
                "https://api.minimaxi.com/v1",
                "https://api.minimaxi.com/v1",
                "https://api.minimaxi.com/v1"
            ),
            models: ["MiniMax-M3"],
            modelsUrl: "https://api.minimaxi.com/v1/models",
            consoleUrl: "https://platform.minimaxi.com/user-center/basic-information/interface-key",
            websiteUrl: "https://www.minimaxi.com", category: "cn_official"
        ),
        ProviderCatalogEntry(
            id: "custom", name: "Custom", displayName: "自定义 / 中转站",
            baseUrl: "", apiFormat: "anthropic", authStyle: "auto",
            endpoints: [],
            models: [], modelsUrl: "",
            consoleUrl: "", websiteUrl: "", category: "custom"
        ),
    ]

    /// 解析某 agent 在该厂商下的端点：优先命中 `endpoints` 表（按 agent 分派），
    /// 缺失时回落顶层模板（兼容 custom / 旧数据）。= Windows `resolvePresetEndpoint`。
    public static func resolvePresetEndpoint(
        _ entry: ProviderCatalogEntry, agentId: String
    ) -> ProviderCatalogEndpoint {
        if let hit = entry.endpoints.first(where: { $0.agent == agentId }) { return hit }
        return ProviderCatalogEndpoint(agent: agentId, baseUrl: entry.baseUrl)
    }

    /// 按 baseURL 匹配预设（用于「拉取模型」找 models_url；匹配不到就不猜端点）。
    ///
    /// 🔴 匹配范围 = **顶层 baseUrl + 各 agent 端点的 baseUrl**。
    /// Windows 只匹配顶层 —— CLI 表单按 agent 端点预填的地址（如 `/v1`）必然
    /// 匹配失败，这是 Windows 端的存量 bug；本端先修，待两端同批。
    public static func matchByBaseUrl(_ baseUrl: String) -> ProviderCatalogEntry? {
        let normalized = normalizeBase(baseUrl)
        guard !normalized.isEmpty else { return nil }
        return all.first { entry in
            guard !entry.modelsUrl.isEmpty else { return false }
            if normalizeBase(entry.baseUrl) == normalized { return true }
            return entry.endpoints.contains { normalizeBase($0.baseUrl) == normalized }
        }
    }

    private static func normalizeBase(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    /// 生效端点预览（镜像 Windows `previewEndpoint` / 后端拼接逻辑）。
    public static func previewEndpoint(baseUrl: String, apiFormat: String, isFullUrl: Bool) -> String {
        let base = normalizeBase(baseUrl)
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
