import Foundation

// ─── Codex 厂商配置（对齐 Windows `services/codex_provider_config.rs`）────────
//
// 路径：`~/.codex/config.toml`
//
// 🔴 与 Windows 逐条对齐的契约：
//   ① 只动这几个位置：顶层 `model_provider` / `[model_providers.<key>]` 表
//      （`name` / `base_url` / `wire_api` / `experimental_bearer_token`）/ 顶层 `model`。
//   ② `name` **必填非空** —— Codex 0.149 会对无 name 的自定义表**整份拒载**。
//   ③ `experimental_bearer_token` **优先写在 provider 表内**（provider 作用域，
//      不污染顶层）；读取时若表内没有则回落顶层（那是我们旧版的回落位置）。
//   ④ **保留 id 不可覆盖**：`openai` / `ollama` / `lmstudio`（**大小写精确**，
//      `OpenAI` 是合法自定义 id）—— 覆盖它们的表会让 Codex 0.148+ 拒绝加载整份配置。
//   ⑤ 🔴 **绝不读写 `~/.codex/auth.json`**（用户 ChatGPT 登录缓存）；第三方 Key
//      走 `experimental_bearer_token` 即可，不需要碰 auth.json。
//   ⑥ 删除：表内 token 随表一起删；**顶层 token 是我们写的回落位，一并清**；
//      若删的是当前生效项则同时清顶层 `model_provider` 与 `model`；
//      `[model_providers.*]` 全空后把空壳父表头也摘掉。
//   ⑦ 读取：文件缺失/空白 → 空清单（不报错）；解析失败 → 空清单（不抛错，
//      避免设置页整个炸掉；写路径才抛错）。

/// 一个 Codex 厂商配置（表单 ↔ `[model_providers.<key>]`）。
public struct CodexProviderEntry: Codable, Equatable {
    /// provider key（表名），形如 `my-deepseek`。
    public var id: String
    /// 展示名（`name`，**必填非空**）。
    public var name: String
    /// API 基址（`base_url`）。
    public var baseURL: String
    /// 协议（`wire_api`）：`chat` / `responses`；空则回落 `chat`。
    public var wireApi: String
    /// API Key（写 `experimental_bearer_token`）。
    public var apiKey: String
    /// 默认模型（顶层 `model`）；空则不写。
    public var model: String
    /// 是否为当前生效的 provider（`model_provider == id`）。
    public var active: Bool

    public init(
        id: String = "", name: String = "", baseURL: String = "", wireApi: String = "",
        apiKey: String = "", model: String = "", active: Bool = false
    ) {
        self.id = id; self.name = name; self.baseURL = baseURL
        self.wireApi = wireApi; self.apiKey = apiKey; self.model = model; self.active = active
    }
}

/// `wire_api` 选项。
public struct WireApiOption: Codable, Equatable {
    public var value: String
    public var label: String
    public init(value: String, label: String) { self.value = value; self.label = label }
}

/// `getCodexProviders` 等的返回。
public struct CodexProvidersInfo: Codable, Equatable {
    public var configFile: String
    public var exists: Bool
    /// 当前生效的 provider key（顶层 `model_provider`）。
    public var activeId: String
    /// 已配置的厂商（按 key 排序）。
    public var providers: [CodexProviderEntry]
    /// 可选 `wire_api` 清单（值 + 标签）。
    public var wireApis: [WireApiOption]

    public init(
        configFile: String, exists: Bool, activeId: String,
        providers: [CodexProviderEntry], wireApis: [WireApiOption]
    ) {
        self.configFile = configFile; self.exists = exists; self.activeId = activeId
        self.providers = providers; self.wireApis = wireApis
    }
}

public enum CodexProviderConfigStore {

    /// Codex 内置（保留）provider id —— 覆盖其表会导致 Codex 拒载整份配置。
    /// 判定是**大小写精确**的。
    public static let reservedProviderIds = ["openai", "ollama", "lmstudio"]

    /// `wire_api` 取值（Codex 只认这两个）。
    public static let wireApis: [WireApiOption] = [
        WireApiOption(value: "chat", label: "Chat Completions"),
        WireApiOption(value: "responses", label: "Responses"),
    ]

    /// 默认 `wire_api`：国内厂商的兼容端点绝大多数走 chat。
    public static let defaultWireApi = "chat"

    private static let tablePrefix = "model_providers"

    private static let writeLock = CLIConfigLock()

    // ─── key 校验 / 派生 ─────────────────────────────────────────────────────

    /// 校验 provider key：只允许小写字母数字，可用连字符分组（`my-deepseek`）。
    public static func isValidProviderKey(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        guard !key.hasPrefix("-"), !key.hasSuffix("-") else { return false }
        var previousDash = false
        for ch in key {
            let ok = (ch.isASCII && ch.isLowercase && ch.isLetter)
                || (ch.isASCII && ch.isNumber)
                || ch == "-"
            guard ok else { return false }
            if ch == "-" && previousDash { return false }
            previousDash = (ch == "-")
        }
        return true
    }

    public static func isReservedProviderKey(_ key: String) -> Bool {
        reservedProviderIds.contains(key)
    }

    /// 由展示名派生合法 key：`My DeepSeek` → `my-deepseek`。
    public static func slugifyProviderKey(_ name: String) -> String {
        var out = ""
        var previousDash = false
        for ch in name.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
                previousDash = false
            } else if !previousDash && !out.isEmpty {
                out.append("-")
                previousDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "provider" : out
    }

    // ─── 路径 ────────────────────────────────────────────────────────────────

    public static func configPaths() -> [URL] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")]
    }

    public static func resolveConfigPath() -> URL {
        let paths = configPaths()
        return paths.first { FileManager.default.fileExists(atPath: $0.path) } ?? paths[0]
    }

    // ─── 对外 API ────────────────────────────────────────────────────────────

    public static func list() -> CodexProvidersInfo { list(at: resolveConfigPath()) }

    public static func list(at path: URL) -> CodexProvidersInfo {
        let exists = FileManager.default.fileExists(atPath: path.path)
        let empty = CodexProvidersInfo(
            configFile: path.path, exists: exists, activeId: "",
            providers: [], wireApis: wireApis
        )
        guard let text = CLIConfigIO.readText(at: path) else { return empty }
        return collect(text: text, path: path, exists: exists)
    }

    @discardableResult
    public static func save(_ entry: CodexProviderEntry) throws -> CodexProvidersInfo {
        try save(entry, at: resolveConfigPath())
    }

    @discardableResult
    public static func save(_ entry: CodexProviderEntry, at path: URL) throws -> CodexProvidersInfo {
        let id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidProviderKey(id) else {
            throw CLIConfigError(
                "invalid provider key '\(id)': use lowercase letters, digits and single dashes (e.g. my-deepseek)"
            )
        }
        guard !isReservedProviderKey(id) else {
            throw CLIConfigError(
                "cannot override Codex built-in provider `\(id)` (Codex 0.148+ rejects the whole config); pick a custom id"
            )
        }
        let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw CLIConfigError("provider name must not be empty (Codex rejects unnamed provider tables)")
        }
        let base = entry.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw CLIConfigError("base_url must not be empty") }
        guard base.hasPrefix("http://") || base.hasPrefix("https://") else {
            throw CLIConfigError("base_url must start with http:// or https://")
        }
        let rawWire = entry.wireApi.trimmingCharacters(in: .whitespacesAndNewlines)
        let wireApi = rawWire.isEmpty ? defaultWireApi : rawWire
        guard wireApis.contains(where: { $0.value == wireApi }) else {
            throw CLIConfigError(
                "invalid wire_api '\(wireApi)': expected one of \(wireApis.map(\.value).joined(separator: ", "))"
            )
        }

        return try writeLock.withLock {
            let text = CLIConfigIO.readText(at: path) ?? ""
            var doc = MiniTOML(text: text)

            // ① 顶层 model_provider 指向这家
            doc.setTopString("model_provider", id)

            // ② `model_providers` 若被写成了顶层标量（非法），先清掉那一行
            if doc.hasTopKey(tablePrefix) { doc.removeTopLine(forKey: tablePrefix) }

            // ③ 写 `[model_providers.<id>]`（保留该表上用户手加的其他字段）
            let table = "\(tablePrefix).\(id)"
            doc.ensureTable(table)
            doc.setTableString(table, "name", name)
            doc.setTableString(table, "base_url", base)
            doc.setTableString(table, "wire_api", wireApi)

            let token = entry.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty {
                doc.removeTableField(table, "experimental_bearer_token")
            } else {
                doc.setTableString(table, "experimental_bearer_token", token)
            }

            // ④ 顶层 model（可选）—— 留空则不动用户原有的
            let model = entry.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.isEmpty { doc.setTopString("model", model) }

            try writeText(doc.text, to: path)
            return list(at: path)
        }
    }

    @discardableResult
    public static func delete(id: String) throws -> CodexProvidersInfo {
        try delete(id: id, at: resolveConfigPath())
    }

    @discardableResult
    public static func delete(id rawId: String, at path: URL) throws -> CodexProvidersInfo {
        let id = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw CLIConfigError("provider id must not be empty") }

        return try writeLock.withLock {
            guard FileManager.default.fileExists(atPath: path.path) else { return list(at: path) }
            let text = CLIConfigIO.readText(at: path) ?? ""
            var doc = MiniTOML(text: text)

            let table = "\(tablePrefix).\(id)"
            let wasActive = doc.topString("model_provider") == id
            let removed = doc.hasTable(table)
            doc.removeTable(table)

            if wasActive {
                doc.removeTopKey("model_provider")
                doc.removeTopKey("model")
            }
            // 顶层 token 是我们写的回落位置，随删除一起清（表内的已随表删除）
            doc.removeTopKey("experimental_bearer_token")
            // 子表全空 → 把空壳父表头也摘掉，别留噪音
            if doc.tableNames(withPrefix: tablePrefix).isEmpty, doc.hasTable(tablePrefix) {
                doc.removeTable(tablePrefix)
            }

            if removed || wasActive { try writeText(doc.text, to: path) }
            return list(at: path)
        }
    }

    @discardableResult
    public static func activate(id: String) throws -> CodexProvidersInfo {
        try activate(id: id, at: resolveConfigPath())
    }

    @discardableResult
    public static func activate(id rawId: String, at path: URL) throws -> CodexProvidersInfo {
        let id = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw CLIConfigError("provider id must not be empty") }

        return try writeLock.withLock {
            let text = CLIConfigIO.readText(at: path) ?? ""
            var doc = MiniTOML(text: text)
            guard doc.hasTable("\(tablePrefix).\(id)") else {
                throw CLIConfigError("provider '\(id)' not found in config.toml")
            }
            doc.setTopString("model_provider", id)
            try writeText(doc.text, to: path)
            return list(at: path)
        }
    }

    // ─── 核心 ────────────────────────────────────────────────────────────────

    private static func collect(text: String, path: URL, exists: Bool) -> CodexProvidersInfo {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CodexProvidersInfo(
                configFile: path.path, exists: exists, activeId: "",
                providers: [], wireApis: wireApis
            )
        }
        let doc = MiniTOML(text: text)
        let activeId = doc.topString("model_provider") ?? ""
        let topModel = doc.topString("model") ?? ""

        var providers: [CodexProviderEntry] = []
        for fullName in doc.tableNames(withPrefix: tablePrefix) {
            // 🚨 必须剥掉 `model_providers.` 前缀才是 provider key ——
            //    否则 id 会变成 "model_providers.my-deepseek"，后续按 id 查表全部落空。
            let key = String(fullName.dropFirst(tablePrefix.count + 1))
            guard !key.isEmpty else { continue }
            let table = "\(tablePrefix).\(key)"
            let name = doc.tableString(table, "name") ?? key
            let baseURL = doc.tableString(table, "base_url") ?? ""
            let wireApi = doc.tableString(table, "wire_api") ?? defaultWireApi
            // token：优先表内，回落顶层（我们旧版的回落位）
            let apiKey = doc.tableString(table, "experimental_bearer_token")
                ?? doc.topString("experimental_bearer_token") ?? ""
            providers.append(CodexProviderEntry(
                id: key, name: name, baseURL: baseURL, wireApi: wireApi,
                apiKey: apiKey,
                // 顶层 model 只属于当前生效的那家
                model: key == activeId ? topModel : "",
                active: key == activeId
            ))
        }
        providers.sort { $0.id < $1.id }

        return CodexProvidersInfo(
            configFile: path.path, exists: exists, activeId: activeId,
            providers: providers, wireApis: wireApis
        )
    }

    /// 写文本（非原子，保留文件原权限 —— 见 `CLIConfigIO.writeJSONObject` 的说明）。
    private static func writeText(_ text: String, to path: URL) throws {
        let parent = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        do {
            try Data(text.utf8).write(to: path)
        } catch {
            throw CLIConfigError("write \(path.path) failed: \(error.localizedDescription)")
        }
    }
}
