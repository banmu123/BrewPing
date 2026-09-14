import Foundation

// ─── Claude Code 厂商配置（对齐 Windows `services/claude_config.rs`）──────────
//
// 路径：`~/.claude/settings.json`
//
// 🔴 与 Windows 逐条对齐的契约：
//   ① 厂商信息落在 **`env` 段**：`ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN`，
//      以及可选的 `ANTHROPIC_DEFAULT_{SONNET,OPUS,HAIKU}_MODEL`（+ `_NAME` 展示名）。
//   ② 🚨 `env` 段必须**就地合并**，绝不能用空字典重建 —— 重建会静默清掉用户
//      env 里的其它键（实测影响 `DISABLE_TELEMETRY` / `MCP_TIMEOUT` /
//      `ANTHROPIC_API_KEY` / `CLAUDE_CODE_MAX_OUTPUT_TOKENS`）。
//   ③ 写前 `sanitize`：剥离 cc-switch 的内部元字段（`api_format` 等四种写法），
//      它们不属于 Claude Code 的 settings 语义，留着是脏数据。
//   ④ "清空 = 删除"：baseURL / apiKey / 某档 model 或 name 为空 → **删掉该键**，
//      而不是跳过写入（否则用户清空某档后旧值还在）。
//   ⑤ 读取：文件缺失/空白 → 空配置（不报错）；**根非对象 → 报错**（整体覆盖的
//      前提是我们知道根长什么样，静默重建会清空用户配置）。
//   ⑥ `settings.json` **只有一份**（不像 opencode 能装多个 provider），
//      所以这里是"当前这一份"，`configured` 标记是否已配好。
//   ⑦ 删除厂商 = 摘掉 env 里指向厂商的键，**不删文件**（删文件会连
//      `model` / `permissions` / `hooks` 一起带走）；env 摘空后整个 `env` 键也摘掉。

/// 一个模型档位（Claude Code 的 sonnet / opus / haiku 三档映射）。
public struct ClaudeTierEntry: Codable, Equatable {
    /// 档位名：`sonnet` / `opus` / `haiku`。
    public var tier: String
    /// 映射到的真实模型 id（写 `ANTHROPIC_DEFAULT_<TIER>_MODEL`）。
    public var model: String
    /// 展示名（写 `ANTHROPIC_DEFAULT_<TIER>_MODEL_NAME`，空则跳过）。
    public var name: String

    public init(tier: String = "", model: String = "", name: String = "") {
        self.tier = tier; self.model = model; self.name = name
    }
}

/// Claude Code 的一份厂商配置（前端表单 ↔ settings.json 的 env 段）。
public struct ClaudeProviderEntry: Codable, Equatable {
    /// 展示名（**仅 UI 用**；Claude Code 的 settings.json 里没有厂商名字段）。
    public var name: String
    /// API 基址（`env.ANTHROPIC_BASE_URL`）。
    public var baseURL: String
    /// API Key（`env.ANTHROPIC_AUTH_TOKEN`）。
    public var apiKey: String
    /// 三档模型映射（空 = 不写这三组键，Claude Code 用官方默认）。
    public var tiers: [ClaudeTierEntry]
    /// 除 `env` 之外被保留的顶层键（只读，让用户知道哪些配置被一起带上了）。
    public var otherKeys: [String]

    public init(
        name: String = "", baseURL: String = "", apiKey: String = "",
        tiers: [ClaudeTierEntry] = [], otherKeys: [String] = []
    ) {
        self.name = name; self.baseURL = baseURL; self.apiKey = apiKey
        self.tiers = tiers; self.otherKeys = otherKeys
    }
}

/// `getClaudeProvider` 等的返回。
public struct ClaudeProvidersInfo: Codable, Equatable {
    /// 配置文件绝对路径（展示用，让用户知道东西写到哪了）。
    public var configFile: String
    /// 配置文件当前是否存在。
    public var exists: Bool
    /// 是否已配置厂商（baseURL 非空）。
    public var configured: Bool
    /// 当前配置（未配置时为空 entry）。
    public var provider: ClaudeProviderEntry

    public init(
        configFile: String, exists: Bool, configured: Bool, provider: ClaudeProviderEntry
    ) {
        self.configFile = configFile; self.exists = exists
        self.configured = configured; self.provider = provider
    }
}

public enum ClaudeConfigStore {

    /// cc-switch 内部元字段 —— 写 Claude Code settings.json 前必须剥离。
    static let internalFields = [
        "api_format", "apiFormat", "openrouter_compat_mode", "openrouterCompatMode",
    ]

    /// 三档模型映射的 env 键（顺序 = 读取时的输出顺序）。
    public static let tierEnvKeys: [(tier: String, env: String)] = [
        ("sonnet", "ANTHROPIC_DEFAULT_SONNET_MODEL"),
        ("opus",   "ANTHROPIC_DEFAULT_OPUS_MODEL"),
        ("haiku",  "ANTHROPIC_DEFAULT_HAIKU_MODEL"),
    ]

    private static let writeLock = CLIConfigLock()

    // ─── 路径 ────────────────────────────────────────────────────────────────

    /// 配置文件候选路径（顺序即优先级，与 `AgentConfigDiscovery.configPaths` 一致）。
    public static func configPaths() -> [URL] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")]
    }

    /// 实际用于读写的路径：已存在的第一个；都不存在则用第一个（新建落这里）。
    public static func resolveConfigPath() -> URL {
        let paths = configPaths()
        return paths.first { FileManager.default.fileExists(atPath: $0.path) } ?? paths[0]
    }

    // ─── 对外 API ────────────────────────────────────────────────────────────
    //
    // 每个能力两个入口：`*()` 用本机真实路径（命令面消费），
    // `*_at(path)` 显式指定路径（测试隔离 —— 不碰用户真实配置）。

    public static func get() -> ClaudeProvidersInfo {
        get(at: resolveConfigPath())
    }

    public static func get(at path: URL) -> ClaudeProvidersInfo {
        let exists = FileManager.default.fileExists(atPath: path.path)
        guard let root = try? CLIConfigIO.readJSONObject(at: path) else {
            // 解析失败 / 根非对象：与 Windows 一致地降级成"未配置"，不抛错
            //（读取路径不该让设置页整个炸掉；写入路径才需要报错）。
            return ClaudeProvidersInfo(
                configFile: path.path, exists: exists, configured: false,
                provider: ClaudeProviderEntry()
            )
        }
        let provider = valueToEntry(root)
        return ClaudeProvidersInfo(
            configFile: path.path, exists: exists,
            configured: !provider.baseURL.isEmpty, provider: provider
        )
    }

    @discardableResult
    public static func save(_ entry: ClaudeProviderEntry) throws -> ClaudeProvidersInfo {
        try save(entry, at: resolveConfigPath())
    }

    @discardableResult
    public static func save(_ entry: ClaudeProviderEntry, at path: URL) throws -> ClaudeProvidersInfo {
        let base = entry.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            throw CLIConfigError("ANTHROPIC_BASE_URL must not be empty")
        }
        guard base.hasPrefix("http://") || base.hasPrefix("https://") else {
            throw CLIConfigError("base url must start with http:// or https://")
        }
        return try writeLock.withLock {
            var root = try CLIConfigIO.readJSONObject(at: path)
            sanitize(&root)
            applyEntry(&root, entry)
            try CLIConfigIO.writeJSONObject(root, at: path)
            return get(at: path)
        }
    }

    @discardableResult
    public static func delete() throws -> ClaudeProvidersInfo {
        try delete(at: resolveConfigPath())
    }

    @discardableResult
    public static func delete(at path: URL) throws -> ClaudeProvidersInfo {
        try writeLock.withLock {
            guard FileManager.default.fileExists(atPath: path.path) else { return get(at: path) }
            var root = try CLIConfigIO.readJSONObject(at: path)
            sanitize(&root)
            if var env = root["env"] as? [String: Any] {
                env.removeValue(forKey: "ANTHROPIC_BASE_URL")
                env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
                for tier in tierEnvKeys {
                    env.removeValue(forKey: tier.env)
                    env.removeValue(forKey: "\(tier.env)_NAME")
                }
                if env.isEmpty {
                    root.removeValue(forKey: "env")   // 别留 `"env": {}` 噪音
                } else {
                    root["env"] = env
                }
            }
            try CLIConfigIO.writeJSONObject(root, at: path)
            return get(at: path)
        }
    }

    // ─── 核心 ────────────────────────────────────────────────────────────────

    /// 剥离 cc-switch 内部元字段（顶层与 `env` 内都清）。
    static func sanitize(_ root: inout [String: Any]) {
        for field in internalFields { root.removeValue(forKey: field) }
        if var env = root["env"] as? [String: Any] {
            for field in internalFields { env.removeValue(forKey: field) }
            root["env"] = env
        }
    }

    /// 把 DTO 写进 settings.json：**只覆盖我们管辖的键**，
    /// 其余用户键（顶层 `model` / `permissions` / `hooks`…，以及 `env` 段里的
    /// `DISABLE_TELEMETRY` / `MCP_TIMEOUT` / `ANTHROPIC_API_KEY`…）**原样保留**。
    static func applyEntry(_ root: inout [String: Any], _ entry: ClaudeProviderEntry) {
        // 🚨 关键：在现有 env 段基础上改，**不能用空字典重建**。
        if root["env"] != nil, !(root["env"] is [String: Any]) {
            // 用户把 env 写成了非对象（罕见）：无法安全合并 → 替换为对象。
            root["env"] = [String: Any]()
        }
        if root["env"] == nil { root["env"] = [String: Any]() }
        var env = (root["env"] as? [String: Any]) ?? [:]

        setOrRemove(&env, "ANTHROPIC_BASE_URL", entry.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        setOrRemove(&env, "ANTHROPIC_AUTH_TOKEN", entry.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))

        for tier in entry.tiers {
            let key = tier.tier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let envKey = tierEnvKeys.first(where: { $0.tier == key })?.env else { continue }
            setOrRemove(&env, envKey, tier.model.trimmingCharacters(in: .whitespacesAndNewlines))
            setOrRemove(&env, "\(envKey)_NAME", tier.name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        root["env"] = env
    }

    /// 非空则写入，为空则**删除该键**（"清空"语义 = 移除，而非留旧值）。
    static func setOrRemove(_ env: inout [String: Any], _ key: String, _ value: String) {
        if value.isEmpty { env.removeValue(forKey: key) } else { env[key] = value }
    }

    /// 把 settings.json 的 env 段还原成 DTO。
    static func valueToEntry(_ root: [String: Any]) -> ClaudeProviderEntry {
        let env = root["env"] as? [String: Any]
        func envString(_ key: String) -> String {
            (env?[key] as? String) ?? ""
        }

        var tiers: [ClaudeTierEntry] = []
        for tier in tierEnvKeys {
            let model = envString(tier.env)
            if model.isEmpty { continue }
            tiers.append(ClaudeTierEntry(
                tier: tier.tier, model: model, name: envString("\(tier.env)_NAME")
            ))
        }

        // 顶层除 env 之外的键（让用户知道"写入时哪些东西被一起带上了"）
        let otherKeys = root.keys.filter { $0 != "env" }.sorted()

        return ClaudeProviderEntry(
            name: "",
            baseURL: envString("ANTHROPIC_BASE_URL"),
            apiKey: envString("ANTHROPIC_AUTH_TOKEN"),
            tiers: tiers,
            otherKeys: otherKeys
        )
    }
}
