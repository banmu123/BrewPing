import Foundation

// ─── pi 厂商配置（对齐 Windows `services/pi_config.rs`）───────────────────────
//
// 路径：`~/.pi/agent/models.json`（provider 定义）+ `~/.pi/agent/settings.json`
//      （默认项 `defaultProvider` / `defaultModel`，**成对生效**）。
//      settings.json 从 models.json **同目录**派生 —— 否则用户把 models.json
//      放在非常规位置时，默认项会写到另一处去。
//
// 🔴 与 Windows 逐条对齐的契约：
//   ① **增量模式**：只动 `providers.<key>` 这一个节点，**绝不重建根节点** ——
//      用户 models.json 里的其它键原样保留。
//   ② `providers` 段：缺失 → 视为空对象（首次添加即此场景）；
//      **存在但非对象 → 报错**（拒绝优于猜）；根非对象 → 报错。
//   ③ 字段：`baseUrl`（注意不是 `baseURL`）/ `apiKey` / `api` / `models[]{id,name}`。
//   ④ 🔴 **绝不读写 `~/.pi/agent/auth.json`**（pi 自己的 /login 凭据）。
//   ⑤ **provider key 不可改名**：改 key = 新建 + 删旧。
//   ⑥ 写入是**原子替换**（先写临时文件再 rename），避免半截 JSON；
//      并**保留原文件权限**（Windows 的 temp+rename 会新建文件，Swift 侧顺手修好）。
//   ⑦ `defaultProvider` / `defaultModel` 必须**成对**：
//      · 保存的这家正是默认 provider 时，若原 defaultModel 已不在新模型清单里，
//        自动对齐到第一个模型；
//      · 删除默认 provider 时把两个键一起清掉，不留悬空引用。

/// 一个模型条目（pi `providers.<key>.models[]` 的元素）。
public struct PiModelEntry: Codable, Equatable {
    public var id: String
    public var name: String
    public init(id: String = "", name: String = "") { self.id = id; self.name = name }
}

/// 一个 pi 厂商配置（表单 ↔ models.json 的 `providers.<key>`）。
public struct PiProviderEntry: Codable, Equatable {
    /// provider key（`providers` 对象的 key）。**不可改名**。
    public var id: String
    /// 展示名（可空）。
    public var name: String
    /// API 基址（pi `baseUrl`，不是 `baseURL`）。
    public var baseURL: String
    /// API Key（pi `apiKey`）。
    public var apiKey: String
    /// 协议（pi `api`）；空则回落 `anthropic-messages`。
    public var api: String
    /// 模型清单。
    public var models: [PiModelEntry]
    /// 是否为当前默认 provider。
    public var isDefault: Bool

    public init(
        id: String = "", name: String = "", baseURL: String = "", apiKey: String = "",
        api: String = "", models: [PiModelEntry] = [], isDefault: Bool = false
    ) {
        self.id = id; self.name = name; self.baseURL = baseURL
        self.apiKey = apiKey; self.api = api; self.models = models; self.isDefault = isDefault
    }
}

/// `api` 选项。
public struct PiApiOption: Codable, Equatable {
    public var value: String
    public var label: String
    public init(value: String, label: String) { self.value = value; self.label = label }
}

/// `getPiProviders` 等的返回。
public struct PiProvidersInfo: Codable, Equatable {
    public var configFile: String
    public var exists: Bool
    public var settingsFile: String
    public var defaultProvider: String
    public var defaultModel: String
    public var providers: [PiProviderEntry]
    public var apis: [PiApiOption]

    public init(
        configFile: String, exists: Bool, settingsFile: String,
        defaultProvider: String, defaultModel: String,
        providers: [PiProviderEntry], apis: [PiApiOption]
    ) {
        self.configFile = configFile; self.exists = exists; self.settingsFile = settingsFile
        self.defaultProvider = defaultProvider; self.defaultModel = defaultModel
        self.providers = providers; self.apis = apis
    }
}

public enum PiProviderConfigStore {

    /// pi 的 `api` 取值（Anthropic Messages 优先 —— 转发链路零协议转换的那一支）。
    public static let apis: [PiApiOption] = [
        PiApiOption(value: "anthropic-messages", label: "Anthropic Messages"),
        PiApiOption(value: "openai-completions", label: "OpenAI Completions"),
        PiApiOption(value: "openai-responses", label: "OpenAI Responses"),
    ]

    public static let defaultAPI = "anthropic-messages"

    private static let writeLock = CLIConfigLock()

    // ─── key 校验 / 派生（与 codex/opencode 同一套规则）───────────────────────

    public static func isValidProviderKey(_ key: String) -> Bool {
        CodexProviderConfigStore.isValidProviderKey(key)
    }

    public static func slugifyProviderKey(_ name: String) -> String {
        CodexProviderConfigStore.slugifyProviderKey(name)
    }

    // ─── 路径 ────────────────────────────────────────────────────────────────

    public static func modelsPaths() -> [URL] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/models.json")]
    }

    public static func resolveModelsPath() -> URL {
        let paths = modelsPaths()
        return paths.first { FileManager.default.fileExists(atPath: $0.path) } ?? paths[0]
    }

    /// settings.json 与 models.json **同目录**派生。
    public static func resolveSettingsPath(modelsPath: URL) -> URL {
        modelsPath.deletingLastPathComponent().appendingPathComponent("settings.json")
    }

    // ─── 对外 API ────────────────────────────────────────────────────────────

    public static func list() -> PiProvidersInfo {
        let models = resolveModelsPath()
        return list(modelsPath: models, settingsPath: resolveSettingsPath(modelsPath: models))
    }

    public static func list(modelsPath: URL, settingsPath: URL) -> PiProvidersInfo {
        let exists = FileManager.default.fileExists(atPath: modelsPath.path)
        let settings = readSettings(at: settingsPath)
        let defaultProvider = (settings["defaultProvider"] as? String) ?? ""
        let defaultModel = (settings["defaultModel"] as? String) ?? ""

        var providers: [PiProviderEntry] = []
        if let root = try? CLIConfigIO.readJSONObject(at: modelsPath),
           let dict = root["providers"] as? [String: Any] {
            providers = dict.map { valueToEntry(key: $0.key, value: $0.value) }
        }
        for index in providers.indices {
            providers[index].isDefault = !defaultProvider.isEmpty && providers[index].id == defaultProvider
        }
        providers.sort { $0.id < $1.id }

        return PiProvidersInfo(
            configFile: modelsPath.path, exists: exists, settingsFile: settingsPath.path,
            defaultProvider: defaultProvider, defaultModel: defaultModel,
            providers: providers, apis: apis
        )
    }

    @discardableResult
    public static func save(_ entry: PiProviderEntry) throws -> PiProvidersInfo {
        let models = resolveModelsPath()
        return try save(entry, modelsPath: models, settingsPath: resolveSettingsPath(modelsPath: models))
    }

    @discardableResult
    public static func save(
        _ entry: PiProviderEntry, modelsPath: URL, settingsPath: URL
    ) throws -> PiProvidersInfo {
        let id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidProviderKey(id) else {
            throw CLIConfigError(
                "invalid provider key '\(id)': use lowercase letters, digits and single dashes (e.g. my-deepseek)"
            )
        }
        let base = entry.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw CLIConfigError("baseUrl must not be empty") }
        guard base.hasPrefix("http://") || base.hasPrefix("https://") else {
            throw CLIConfigError("baseUrl must start with http:// or https://")
        }
        let rawApi = entry.api.trimmingCharacters(in: .whitespacesAndNewlines)
        let api = rawApi.isEmpty ? defaultAPI : rawApi
        guard apis.contains(where: { $0.value == api }) else {
            throw CLIConfigError(
                "invalid api '\(api)': expected one of \(apis.map(\.value).joined(separator: ", "))"
            )
        }
        guard entry.models.contains(where: { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw CLIConfigError("at least one model is required")
        }

        return try writeLock.withLock {
            // 读全文 → 只动 providers.<id> → 写回（其余键原样保留）
            var root = try CLIConfigIO.readJSONObject(at: modelsPath)
            var providers = try providersSection(&root, modelsPath: modelsPath)
            providers[id] = entryToValue(entry)
            root["providers"] = providers
            try CLIConfigIO.writeJSONObjectAtomic(root, at: modelsPath)

            // 默认项：只有当这家已是默认 provider 时才动 settings
            let settings = readSettings(at: settingsPath)
            let currentDefault = (settings["defaultProvider"] as? String) ?? ""
            if currentDefault == id {
                let firstModel = entry.models
                    .map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                if let firstModel {
                    let currentModel = (settings["defaultModel"] as? String) ?? ""
                    let stillExists = entry.models.contains {
                        $0.id.trimmingCharacters(in: .whitespacesAndNewlines) == currentModel
                    }
                    if !stillExists {
                        var next = settings
                        next["defaultModel"] = firstModel
                        try CLIConfigIO.writeJSONObjectAtomic(next, at: settingsPath)
                    }
                }
            }

            return list(modelsPath: modelsPath, settingsPath: settingsPath)
        }
    }

    @discardableResult
    public static func delete(id: String) throws -> PiProvidersInfo {
        let models = resolveModelsPath()
        return try delete(id: id, modelsPath: models, settingsPath: resolveSettingsPath(modelsPath: models))
    }

    @discardableResult
    public static func delete(
        id rawId: String, modelsPath: URL, settingsPath: URL
    ) throws -> PiProvidersInfo {
        let id = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw CLIConfigError("provider id must not be empty") }

        return try writeLock.withLock {
            if FileManager.default.fileExists(atPath: modelsPath.path) {
                var root = try CLIConfigIO.readJSONObject(at: modelsPath)
                if var providers = root["providers"] as? [String: Any] {
                    let removed = providers.removeValue(forKey: id) != nil
                    if removed {
                        root["providers"] = providers
                        try CLIConfigIO.writeJSONObjectAtomic(root, at: modelsPath)
                    }
                }
            }

            // 默认项清理：只在默认 provider 正是被删的这家时动手（按值判定，不误删）
            let settings = readSettings(at: settingsPath)
            if (settings["defaultProvider"] as? String) == id {
                var next = settings
                next.removeValue(forKey: "defaultProvider")
                next.removeValue(forKey: "defaultModel")
                try CLIConfigIO.writeJSONObjectAtomic(next, at: settingsPath)
            }

            return list(modelsPath: modelsPath, settingsPath: settingsPath)
        }
    }

    @discardableResult
    public static func activate(id: String, model: String? = nil) throws -> PiProvidersInfo {
        let models = resolveModelsPath()
        return try activate(id: id, model: model, modelsPath: models,
                            settingsPath: resolveSettingsPath(modelsPath: models))
    }

    @discardableResult
    public static func activate(
        id rawId: String, model: String?, modelsPath: URL, settingsPath: URL
    ) throws -> PiProvidersInfo {
        let id = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw CLIConfigError("provider id must not be empty") }

        return try writeLock.withLock {
            let root = try CLIConfigIO.readJSONObject(at: modelsPath)
            guard let providers = root["providers"] as? [String: Any],
                  let provider = providers[id] as? [String: Any] else {
                throw CLIConfigError("provider '\(id)' not found in models.json")
            }

            // 模型：显式传入优先；否则取该 provider 的第一个模型（成对，不留悬空）
            let modelId: String
            if let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                modelId = model.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let first = (provider["models"] as? [[String: Any]])?
                .compactMap({ $0["id"] as? String }).first {
                modelId = first
            } else {
                throw CLIConfigError("provider '\(id)' has no models to select")
            }

            var settings = readSettings(at: settingsPath)
            settings["defaultProvider"] = id
            settings["defaultModel"] = modelId
            try CLIConfigIO.writeJSONObjectAtomic(settings, at: settingsPath)

            return list(modelsPath: modelsPath, settingsPath: settingsPath)
        }
    }

    // ─── 核心 ────────────────────────────────────────────────────────────────

    /// 读 settings.json（宽容：读不到就用空对象 —— 默认项是可选增强）。
    static func readSettings(at url: URL) -> [String: Any] {
        guard let text = CLIConfigIO.readText(at: url),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else { return [:] }
        return object
    }

    /// 取 `providers` 对象；缺失则创建，**非对象则报错**（不静默重置）。
    static func providersSection(_ root: inout [String: Any], modelsPath: URL) throws -> [String: Any] {
        if let existing = root["providers"] {
            guard let object = existing as? [String: Any] else {
                throw CLIConfigError(
                    "\(modelsPath.path) 'providers' must be an object (found \(CLIConfigIO.typeName(existing)))"
                )
            }
            return object
        }
        return [:]
    }

    /// 把 DTO 转成 pi 磁盘格式的 provider 节点。
    static func entryToValue(_ entry: PiProviderEntry) -> [String: Any] {
        var provider: [String: Any] = [:]
        let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { provider["name"] = name }
        provider["baseUrl"] = entry.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = entry.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { provider["apiKey"] = key }
        let rawApi = entry.api.trimmingCharacters(in: .whitespacesAndNewlines)
        provider["api"] = rawApi.isEmpty ? defaultAPI : rawApi

        let models: [[String: Any]] = entry.models.compactMap { model in
            let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return ["id": id, "name": name.isEmpty ? id : name]
        }
        provider["models"] = models
        return provider
    }

    /// 把磁盘上的 provider 节点还原成 DTO。
    static func valueToEntry(key: String, value: Any) -> PiProviderEntry {
        let dict = value as? [String: Any] ?? [:]
        var models: [PiModelEntry] = []
        for item in (dict["models"] as? [[String: Any]]) ?? [] {
            guard let id = item["id"] as? String else { continue }
            models.append(PiModelEntry(id: id, name: (item["name"] as? String) ?? id))
        }
        models.sort { $0.id < $1.id }
        return PiProviderEntry(
            id: key,
            name: (dict["name"] as? String) ?? "",
            baseURL: (dict["baseUrl"] as? String) ?? "",
            apiKey: (dict["apiKey"] as? String) ?? "",
            api: (dict["api"] as? String) ?? defaultAPI,
            models: models,
            isDefault: false   // 由调用方按 settings 填
        )
    }
}
