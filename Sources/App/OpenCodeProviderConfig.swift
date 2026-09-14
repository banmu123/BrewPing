import Foundation

// ─── OpenCode 厂商配置（对齐 Windows `services/opencode_config.rs`）───────────
//
// 路径：`~/.config/opencode/opencode.json`
//      （Windows 另有 `%APPDATA%\opencode\opencode.json` 回落；macOS 不存在该路
//        径，故只保留官方位置 —— 与 `AgentConfigDiscovery.configPaths` 同一顺序。）
//
// 🔴 与 Windows 逐条对齐的契约：
//   ① **唯一真相 = 该文件**（无二次存储）：厂商列表直接读它，不落 BrewPing 自己的库。
//   ② **深合并铁律**：读全文 → **只把 `provider` 归一化成对象** → `provider[id] = cfg`
//      → 写回。**绝不重建根节点** —— 根上的 `$schema` / `mcp` / `theme` / `model`
//      必须原样保留。
//   ③ 读取：文件缺失 / 空白 → 返回 `{"$schema": …}` **骨架**（首次添加是合法场景，
//      不报错）；**根不是对象 → 报错**（静默重置会无声清空用户整份配置）。
//   ④ key 规则：`^[a-z0-9]+(-[a-z0-9]+)*$`（这个 key 会成为对象键，
//      大写 / 空格 / 中文会在别处炸开）。
//   ⑤ 保存时 `baseURL` **去掉尾部 `/`**；`options` 只写非空字段
//      （opencode 对空 baseURL 会报错）。
//   ⑥ `provider` 段存在但非对象 → 归一化成空对象（只动这一个键，不碰根）。
//   ⑦ 与 Windows 的**有意差异**：前端从不编辑 `options.headers`，Windows 的
//      "替换整个节点"写法会把它静默删掉；这里**显式保留**原节点的 headers。
//      （UI 从不展示该字段，故不构成行为差异，只是少一次数据丢失。）

/// 一个模型条目（opencode `provider.<id>.models.<modelId>`）。
public struct OpenCodeModelEntry: Codable, Equatable {
    /// 模型 id（即 models 对象的 key；写入时作 key）。
    public var id: String
    /// 展示名（空则 opencode 回落 id）。
    public var name: String
    public init(id: String = "", name: String = "") { self.id = id; self.name = name }
}

/// 一个 provider 的完整配置（表单 ↔ opencode.json 段落）。
///
/// 🔴 `baseURL` 的**大写 URL** 是 opencode 的既有约定，不能"顺手改成 baseUrl"。
public struct OpenCodeProviderEntry: Codable, Equatable {
    /// provider key（`provider` 对象的 key），形如 `my-deepseek`。
    public var id: String
    /// 展示名（opencode `provider.<id>.name`）。
    public var name: String
    /// npm 接口包；空则回落 `@ai-sdk/openai-compatible`。
    public var npm: String
    /// API 基址（opencode `provider.<id>.options.baseURL`）。
    public var baseURL: String
    /// API Key（opencode `provider.<id>.options.apiKey`）。
    public var apiKey: String
    /// 模型清单。
    public var models: [OpenCodeModelEntry]

    public init(
        id: String = "", name: String = "", npm: String = "",
        baseURL: String = "", apiKey: String = "", models: [OpenCodeModelEntry] = []
    ) {
        self.id = id; self.name = name; self.npm = npm
        self.baseURL = baseURL; self.apiKey = apiKey; self.models = models
    }
}

/// npm 接口包选项。
public struct NpmPackageOption: Codable, Equatable {
    public var value: String
    public var label: String
    public init(value: String, label: String) { self.value = value; self.label = label }
}

/// `getOpenCodeProviders` 等的返回。
public struct OpenCodeProvidersInfo: Codable, Equatable {
    public var configFile: String
    public var exists: Bool
    public var providers: [OpenCodeProviderEntry]
    public var npmPackages: [NpmPackageOption]

    public init(
        configFile: String, exists: Bool,
        providers: [OpenCodeProviderEntry], npmPackages: [NpmPackageOption]
    ) {
        self.configFile = configFile; self.exists = exists
        self.providers = providers; self.npmPackages = npmPackages
    }
}

public enum OpenCodeProviderConfigStore {

    /// opencode.json 的官方 schema 地址（新建骨架时写入）。
    public static let schemaURL = "https://opencode.ai/config.json"

    /// 默认 npm 接口包（兼容 OpenAI 协议的中转站 / 厂商最常见）。
    public static let defaultNpm = "@ai-sdk/openai-compatible"

    /// 可选的 npm 接口包（顺序与 cc-switch 一致）。
    public static let npmPackages: [NpmPackageOption] = [
        NpmPackageOption(value: "@ai-sdk/openai-compatible", label: "OpenAI 兼容"),
        NpmPackageOption(value: "@ai-sdk/openai", label: "OpenAI Responses"),
        NpmPackageOption(value: "@ai-sdk/anthropic", label: "Anthropic"),
        NpmPackageOption(value: "@ai-sdk/google", label: "Google"),
        NpmPackageOption(value: "@ai-sdk/amazon-bedrock", label: "Amazon Bedrock"),
    ]

    private static let writeLock = CLIConfigLock()

    // ─── key 校验 / 派生（与 codex/pi 同一套规则）────────────────────────────

    public static func isValidProviderKey(_ key: String) -> Bool {
        CodexProviderConfigStore.isValidProviderKey(key)
    }

    public static func slugifyProviderKey(_ name: String) -> String {
        CodexProviderConfigStore.slugifyProviderKey(name)
    }

    // ─── 路径 ────────────────────────────────────────────────────────────────

    public static func configPaths() -> [URL] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/opencode/opencode.json")]
    }

    public static func resolveConfigPath() -> URL {
        let paths = configPaths()
        return paths.first { FileManager.default.fileExists(atPath: $0.path) } ?? paths[0]
    }

    // ─── 对外 API ────────────────────────────────────────────────────────────

    public static func list() -> OpenCodeProvidersInfo { list(at: resolveConfigPath()) }

    public static func list(at path: URL) -> OpenCodeProvidersInfo {
        let exists = FileManager.default.fileExists(atPath: path.path)
        var providers: [OpenCodeProviderEntry] = []
        // 解析失败（非法 JSON / 根非对象）→ 空清单 + exists，让界面提示"配置有问题"
        // 而不是整个功能挂掉。
        if let root = try? readConfig(at: path),
           let dict = root["provider"] as? [String: Any] {
            providers = dict.map { valueToEntry(id: $0.key, value: $0.value) }
        }
        providers.sort { $0.id < $1.id }
        return OpenCodeProvidersInfo(
            configFile: path.path, exists: exists, providers: providers, npmPackages: npmPackages
        )
    }

    @discardableResult
    public static func save(_ entry: OpenCodeProviderEntry) throws -> OpenCodeProvidersInfo {
        try save(entry, at: resolveConfigPath())
    }

    @discardableResult
    public static func save(_ entry: OpenCodeProviderEntry, at path: URL) throws -> OpenCodeProvidersInfo {
        let id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidProviderKey(id) else {
            throw CLIConfigError(
                "invalid provider key '\(id)': use lowercase letters, digits and single dashes (e.g. my-deepseek)"
            )
        }
        guard !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIConfigError("provider name must not be empty")
        }
        let base = entry.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw CLIConfigError("baseURL must not be empty") }
        guard base.hasPrefix("http://") || base.hasPrefix("https://") else {
            throw CLIConfigError("baseURL must start with http:// or https://")
        }
        guard entry.models.contains(where: { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw CLIConfigError("at least one model is required")
        }

        return try writeLock.withLock {
            // 读全文 → 只动 provider.<id> → 写回（其余键原样保留）
            var root = try readConfig(at: path)
            var providers = (root["provider"] as? [String: Any]) ?? [:]

            // 保留原节点的 options.headers（前端从不编辑它，见文件头 ⑦）
            let previousHeaders = ((providers[id] as? [String: Any])?["options"] as? [String: Any])?["headers"]

            var normalized = entry
            normalized.id = id
            normalized.baseURL = base.hasSuffix("/") ? String(base.dropLast()) : base
            providers[id] = entryToValue(normalized, preservedHeaders: previousHeaders)
            root["provider"] = providers

            try CLIConfigIO.writeJSONObject(root, at: path)

            var info = list(at: path)
            info.exists = true
            return info
        }
    }

    @discardableResult
    public static func delete(id: String) throws -> OpenCodeProvidersInfo {
        try delete(id: id, at: resolveConfigPath())
    }

    @discardableResult
    public static func delete(id rawId: String, at path: URL) throws -> OpenCodeProvidersInfo {
        let id = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw CLIConfigError("provider id must not be empty") }

        return try writeLock.withLock {
            guard FileManager.default.fileExists(atPath: path.path) else { return list(at: path) }
            var root = try readConfig(at: path)
            if var providers = root["provider"] as? [String: Any],
               providers.removeValue(forKey: id) != nil {
                root["provider"] = providers
                try CLIConfigIO.writeJSONObject(root, at: path)
            }
            return list(at: path)
        }
    }

    // ─── 核心 ────────────────────────────────────────────────────────────────

    /// 读整份配置。文件缺失 / 空白 → `$schema` 骨架；**根非对象 → 报错**。
    static func readConfig(at path: URL) throws -> [String: Any] {
        let skeleton: [String: Any] = ["$schema": schemaURL]
        guard FileManager.default.fileExists(atPath: path.path) else { return skeleton }
        let text = CLIConfigIO.readText(at: path) ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return skeleton }
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            throw CLIConfigError("\(path.path) is not valid JSON")
        }
        guard let object = value as? [String: Any] else {
            throw CLIConfigError("\(path.path) root must be a JSON object (found \(CLIConfigIO.typeName(value)))")
        }
        return object
    }

    /// 把 DTO 转成 opencode 磁盘格式的 provider 段落。
    static func entryToValue(
        _ entry: OpenCodeProviderEntry, preservedHeaders: Any? = nil
    ) -> [String: Any] {
        var provider: [String: Any] = [:]
        provider["name"] = entry.name

        let npm = entry.npm.trimmingCharacters(in: .whitespacesAndNewlines)
        provider["npm"] = npm.isEmpty ? defaultNpm : npm

        // options：只写非空字段，避免留下空串（opencode 对空 baseURL 会报错）
        var options: [String: Any] = [:]
        let base = entry.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty { options["baseURL"] = base }
        let key = entry.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { options["apiKey"] = key }
        if let headers = preservedHeaders as? [String: Any], !headers.isEmpty {
            options["headers"] = headers
        }
        if !options.isEmpty { provider["options"] = options }

        var models: [String: Any] = [:]
        for model in entry.models {
            let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
            models[id] = ["name": name.isEmpty ? id : name]
        }
        if !models.isEmpty { provider["models"] = models }

        return provider
    }

    /// 把磁盘上的 provider 段落还原成 DTO。
    static func valueToEntry(id: String, value: Any) -> OpenCodeProviderEntry {
        let dict = value as? [String: Any] ?? [:]
        let options = dict["options"] as? [String: Any]

        var models: [OpenCodeModelEntry] = []
        if let modelsDict = dict["models"] as? [String: Any] {
            for (modelId, modelValue) in modelsDict {
                let name = ((modelValue as? [String: Any])?["name"] as? String) ?? modelId
                models.append(OpenCodeModelEntry(id: modelId, name: name))
            }
        }
        models.sort { $0.id < $1.id }

        return OpenCodeProviderEntry(
            id: id,
            name: (dict["name"] as? String) ?? id,
            npm: (dict["npm"] as? String) ?? defaultNpm,
            baseURL: (options?["baseURL"] as? String) ?? "",
            apiKey: (options?["apiKey"] as? String) ?? "",
            models: models
        )
    }
}
