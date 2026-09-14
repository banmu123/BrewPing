import Foundation

// ─── 模型供应商存储（对齐 Windows `services/model_provider_store.rs`）──────────
//
// 持久化：`~/.brewping/model_providers.json`（pretty JSON，权限 0600）。
//
// 🔴 与 Windows 端一致的不变量：
//   ① 全字段可缺省（旧版/损坏文件→默认值），**绝不 panic**；
//   ② `id` 空 = 新建（生成 uuid，带 createdAtMs 与 sortIndex=count）；
//   ③ 编辑时**保留原 agentId（创建即锁定）/ createdAtMs / sortIndex**；
//   ④ apiKey 提交空或等于掩码 → 保留旧 Key；
//   ⑤ 首条自动成为 current；
//   ⑥ 删当前项 → 清 currentId，并从 currentByAgent 的所有槽位里摘除；
//   ⑦ `switchCurrent(agentId:)` 跨归属防护：目标归属他人 → 不写槽（不报错）；
//   ⑧ baseUrl 必须 http(s) 且去尾 `/`，name 非空；
//   ⑨ 掩码 = 前 3 + 8 个 `•` + 后 4；长度 < 12 时整体 8 个 `•`。

/// 盘上完整记录（含明文 Key）。
public struct ModelProviderConfig: Codable, Identifiable, Equatable {
    public var id: String
    /// 归属：`""` = 通用（所有 Agent 可用）；否则为专属 Agent id。
    public var agentId: String
    public var name: String
    public var baseUrl: String
    public var apiKey: String
    /// `anthropic` | `openai_chat` | `openai_responses`
    public var apiFormat: String
    /// `auto` | `bearer` | `x-api-key`
    public var authStyle: String
    public var isFullUrl: Bool
    public var model: String?
    public var notes: String?
    public var createdAtMs: Double
    public var sortIndex: Int

    enum CodingKeys: String, CodingKey {
        case id, agentId, name, baseUrl, apiKey, apiFormat, authStyle, isFullUrl
        case model, notes, createdAtMs, sortIndex
    }

    public init(
        id: String = "", agentId: String = "", name: String = "", baseUrl: String = "",
        apiKey: String = "", apiFormat: String = "anthropic", authStyle: String = "auto",
        isFullUrl: Bool = false, model: String? = nil, notes: String? = nil,
        createdAtMs: Double = 0, sortIndex: Int = 0
    ) {
        self.id = id; self.agentId = agentId; self.name = name; self.baseUrl = baseUrl
        self.apiKey = apiKey; self.apiFormat = apiFormat; self.authStyle = authStyle
        self.isFullUrl = isFullUrl; self.model = model; self.notes = notes
        self.createdAtMs = createdAtMs; self.sortIndex = sortIndex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        agentId = (try? c.decodeIfPresent(String.self, forKey: .agentId)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        baseUrl = (try? c.decodeIfPresent(String.self, forKey: .baseUrl)) ?? ""
        apiKey = (try? c.decodeIfPresent(String.self, forKey: .apiKey)) ?? ""
        apiFormat = (try? c.decodeIfPresent(String.self, forKey: .apiFormat)) ?? "anthropic"
        authStyle = (try? c.decodeIfPresent(String.self, forKey: .authStyle)) ?? "auto"
        isFullUrl = (try? c.decodeIfPresent(Bool.self, forKey: .isFullUrl)) ?? false
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        createdAtMs = (try? c.decodeIfPresent(Double.self, forKey: .createdAtMs)) ?? 0
        sortIndex = (try? c.decodeIfPresent(Int.self, forKey: .sortIndex)) ?? 0
    }

    /// 出参视图：Key 掩码 + hasKey（**下发给 UI 的永远是掩码**）。
    public func masked() -> ModelProviderView {
        ModelProviderView(
            id: id, agentId: agentId, name: name, baseUrl: baseUrl,
            apiKeyMasked: Self.mask(apiKey), hasKey: !apiKey.isEmpty,
            apiFormat: apiFormat, authStyle: authStyle, isFullUrl: isFullUrl,
            model: model, notes: notes, createdAtMs: createdAtMs, sortIndex: sortIndex
        )
    }

    public static func mask(_ key: String) -> String {
        if key.isEmpty { return "" }
        if key.count < 12 { return String(repeating: "•", count: 8) }
        let prefix = key.prefix(3)
        let suffix = key.suffix(4)
        return "\(prefix)\(String(repeating: "•", count: 8))\(suffix)"
    }
}

/// 出参（掩码版）。
public struct ModelProviderView: Codable, Identifiable, Equatable {
    public let id: String
    public let agentId: String
    public let name: String
    public let baseUrl: String
    public let apiKeyMasked: String
    public let hasKey: Bool
    public let apiFormat: String
    public let authStyle: String
    public let isFullUrl: Bool
    public let model: String?
    public let notes: String?
    public let createdAtMs: Double
    public let sortIndex: Int
}

/// 命令返回：列表 + 当前项 + 代理状态（一次给全，UI 无需推导）。
public struct ModelProvidersInfo: Codable {
    public let providers: [ModelProviderView]
    public let currentId: String?
    public let currentByAgent: [String: String]
    public let proxyEnabled: Bool
    public let proxyPort: Int
    public let proxyRunning: Bool
    public let failoverEnabled: Bool
    public let proxyError: String?
}

public enum ModelProviderStoreError: LocalizedError {
    case invalidName
    case invalidBaseUrl

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "provider name is required"
        case .invalidBaseUrl: return "base URL must start with http:// or https://"
        }
    }
}

/// 存储 + 语义（单例；Mutex 串行化读写，语义与 Windows `model_provider_store.rs` 对齐）。
public final class ModelProviderStore {
    public static let shared = ModelProviderStore()

    private let lock = NSLock()
    private let fileURL: URL
    /// 代理运行状态由代理模块注入（Phase 2）；未实现时恒为 false。
    public var proxyRunningProvider: (() -> Bool)?
    public var proxyErrorProvider: (() -> String?)?

    private struct FileShape: Codable {
        var providers: [ModelProviderConfig] = []
        var currentId: String?
        var currentByAgent: [String: String] = [:]
        var proxyEnabled: Bool = false
        var proxyPort: Int = 15721
        var failoverEnabled: Bool = false

        enum CodingKeys: String, CodingKey {
            case providers, currentId, currentByAgent, proxyEnabled, proxyPort, failoverEnabled
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            providers = (try? c.decodeIfPresent([ModelProviderConfig].self, forKey: .providers)) ?? []
            currentId = try? c.decodeIfPresent(String.self, forKey: .currentId)
            currentByAgent = (try? c.decodeIfPresent([String: String].self, forKey: .currentByAgent)) ?? [:]
            proxyEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .proxyEnabled)) ?? false
            proxyPort = (try? c.decodeIfPresent(Int.self, forKey: .proxyPort)) ?? 15721
            failoverEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .failoverEnabled)) ?? false
        }
    }

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.fileURL = home.appendingPathComponent(".brewping/model_providers.json")
        }
    }

    // MARK: - 读

    public func info() -> ModelProvidersInfo {
        lock.lock()
        defer { lock.unlock() }
        let shape = load()
        return snapshot(shape)
    }

    /// 解析某 Agent 当前生效的 provider id（`currentByAgent[agent] → currentId → nil`）。
    public func currentId(forAgent agentId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return Self.resolveCurrent(load(), agentId: agentId)
    }

    private static func resolveCurrent(_ shape: FileShape, agentId: String) -> String? {
        let ids = Set(shape.providers.map(\.id))
        var candidate: String?
        if !agentId.isEmpty, let slot = shape.currentByAgent[agentId] { candidate = slot }
        if candidate == nil { candidate = shape.currentId }
        guard let id = candidate, ids.contains(id) else { return nil }
        return id
    }

    private func snapshot(_ shape: FileShape) -> ModelProvidersInfo {
        let sorted = shape.providers.sorted { $0.sortIndex < $1.sortIndex }
        return ModelProvidersInfo(
            providers: sorted.map { $0.masked() },
            currentId: shape.currentId.flatMap { id in shape.providers.contains { $0.id == id } ? id : nil },
            currentByAgent: shape.currentByAgent,
            proxyEnabled: shape.proxyEnabled,
            proxyPort: shape.proxyPort,
            proxyRunning: proxyRunningProvider?() ?? false,
            failoverEnabled: shape.failoverEnabled,
            proxyError: proxyErrorProvider?()
        )
    }

    // MARK: - 写（全部返回最新快照，与 Windows 一致）

    /// 新建或更新。`id` 空 = 新建；编辑时保留 agentId / createdAtMs / sortIndex。
    @discardableResult
    public func save(_ draft: ModelProviderConfig) throws -> ModelProvidersInfo {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw ModelProviderStoreError.invalidName }
        let baseUrl = draft.baseUrl.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard baseUrl.lowercased().hasPrefix("http://") || baseUrl.lowercased().hasPrefix("https://") else {
            throw ModelProviderStoreError.invalidBaseUrl
        }

        lock.lock()
        defer { lock.unlock() }
        var shape = load()

        if draft.id.isEmpty {
            let record = ModelProviderConfig(
                id: UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""),
                agentId: draft.agentId, name: name, baseUrl: baseUrl,
                apiKey: draft.apiKey.trimmingCharacters(in: .whitespaces),
                apiFormat: draft.apiFormat, authStyle: draft.authStyle, isFullUrl: draft.isFullUrl,
                model: draft.model?.isEmpty == true ? nil : draft.model,
                notes: draft.notes?.isEmpty == true ? nil : draft.notes,
                createdAtMs: Date().timeIntervalSince1970 * 1000,
                sortIndex: shape.providers.count
            )
            shape.providers.append(record)
            if shape.currentId == nil { shape.currentId = record.id }   // ⑤ 首条自动设为当前
        } else if let idx = shape.providers.firstIndex(where: { $0.id == draft.id }) {
            var record = shape.providers[idx]
            // ③ 归属创建即锁定 + 保留 createdAtMs / sortIndex
            record.name = name
            record.baseUrl = baseUrl
            let submittedKey = draft.apiKey.trimmingCharacters(in: .whitespaces)
            // ④ 空或等于掩码 → 保留旧 Key
            if !submittedKey.isEmpty, submittedKey != ModelProviderConfig.mask(record.apiKey) {
                record.apiKey = submittedKey
            }
            record.apiFormat = draft.apiFormat
            record.authStyle = draft.authStyle
            record.isFullUrl = draft.isFullUrl
            record.model = draft.model?.isEmpty == true ? nil : draft.model
            record.notes = draft.notes?.isEmpty == true ? nil : draft.notes
            shape.providers[idx] = record
        }

        save(shape)
        return snapshot(shape)
    }

    @discardableResult
    public func delete(id: String) -> ModelProvidersInfo {
        lock.lock()
        defer { lock.unlock() }
        var shape = load()
        shape.providers.removeAll { $0.id == id }
        if shape.currentId == id { shape.currentId = nil }              // ⑥ 删当前项 → 清槽
        shape.currentByAgent = shape.currentByAgent.filter { $0.value != id }
        if shape.currentId == nil { shape.currentId = shape.providers.first?.id }
        save(shape)
        return snapshot(shape)
    }

    /// 设为当前。跨归属防护：目标归属他人 → 不写槽（与 Windows `switch_current_for` 一致）。
    @discardableResult
    public func switchCurrent(id: String, agentId: String) -> ModelProvidersInfo {
        lock.lock()
        defer { lock.unlock() }
        var shape = load()
        guard let provider = shape.providers.first(where: { $0.id == id }) else { return snapshot(shape) }
        if agentId.isEmpty {
            shape.currentId = provider.id
        } else if provider.agentId.isEmpty || provider.agentId == agentId {
            shape.currentByAgent[agentId] = provider.id
        } else {
            // 目标不属于该 Agent 且不是通用 → 拒绝写槽（不报错，保持原状）
            return snapshot(shape)
        }
        save(shape)
        return snapshot(shape)
    }

    // MARK: - 代理开关（运行态由 Phase 2 的代理模块接管）

    @discardableResult
    public func setProxy(enabled: Bool, port: Int) -> ModelProvidersInfo {
        lock.lock()
        defer { lock.unlock() }
        var shape = load()
        shape.proxyEnabled = enabled
        if port > 0 { shape.proxyPort = port }
        save(shape)
        return snapshot(shape)
    }

    @discardableResult
    public func setFailover(enabled: Bool) -> ModelProvidersInfo {
        lock.lock()
        defer { lock.unlock() }
        var shape = load()
        shape.failoverEnabled = enabled
        save(shape)
        return snapshot(shape)
    }

    /// 供代理模块（Phase 2）读取当前配置。
    public func proxyConfig() -> (enabled: Bool, port: Int, failover: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let shape = load()
        return (shape.proxyEnabled, shape.proxyPort, shape.failoverEnabled)
    }

    // MARK: - 磁盘

    private func load() -> FileShape {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return FileShape() }
        return (try? JSONDecoder().decode(FileShape.self, from: data)) ?? FileShape()
    }

    private func save(_ shape: FileShape) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(shape) else { return }
        try? data.write(to: fileURL, options: .atomic)
        // Key 属于敏感信息：文件权限收紧到 0600（Windows 端为 icacls）
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
