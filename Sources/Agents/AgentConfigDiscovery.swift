import Foundation

/// 读取本机各 Agent 的真实配置文件，发现 Provider / Model。
/// 只读，不修改任何配置，不伪造信息。
enum AgentConfigDiscovery {
    struct AgentProviders {
        let agentId: String
        let providers: [BrewPingProtocol.Provider]
        let activeModelId: String?
        let error: String?
    }

    static func discover(agentId: String) -> AgentProviders {
        switch agentId {
        case "opencode":       return discoverOpenCode()
        case "claude-code":    return discoverClaudeCode()
        case "codex":          return discoverCodex()
        case "pi":             return discoverPi()
        default:               return AgentProviders(agentId: agentId, providers: [], activeModelId: nil, error: nil)
        }
    }

    // MARK: - 配置指纹

    /// 该 Agent 所读配置文件的指纹（`mtimeNanos:size`，多文件用 `|` 连接、缺失记 `-`）。
    ///
    /// 用途：让 iPhone 侧的模型列表缓存能感知"电脑上这份配置被改过了"。
    /// iPhone 每 5 秒轮询 `/api/agents/<id>/models`，把本值并进缓存键 ——
    /// 指纹一变就说明该重拉列表，用户在这边加完厂商不必等切设备/切 Agent。
    ///
    /// 与 Windows 端 `agent_config::config_version_for` **语义一致**（同为
    /// `mtime_nanos:size`、多文件 `|`、缺失 `-`），两端接口逐字段对齐。
    /// 纳入"全部候选路径"而非只有实际读到的那份：文件在候选路径间搬动时，
    /// 指纹也必须跟着变，否则移动端会继续用旧列表。
    static func configVersion(agentId: String) -> String {
        configPaths(for: agentId).map { url in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.intValue else {
                return "-"
            }
            let mtime = (attrs[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? 0
            return "\(Int64(mtime * 1_000_000_000)):\(size)"
        }.joined(separator: "|")
    }

    /// 读一个文本配置文件，并剥掉行首的 UTF-8 BOM。
    ///
    /// 为什么要单独做：Windows 上编辑器常带 BOM 保存，用户把配置同步/拷贝到 Mac
    /// 时 BOM 会一起带过来。`JSONSerialization` 对 BOM 是宽容的，但 **TOML / YAML
    /// 那两条是按行 + `hasPrefix` 解析的** —— 行首多一个 `U+FEFF` 后
    /// `hasPrefix("[")` / `hasPrefix("model:")` 直接判否，整段配置被静默丢掉。
    ///
    /// 只剥开头那一个（BOM 按规范只允许出现在文件最前），中间的 `U+FEFF`
    /// 可能是用户内容里的零宽不换行空格，不该动。
    private static func readText(at path: URL) -> String? {
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
    }

    /// 各 Agent 的候选配置文件路径（顺序与各 `discover*` 实际读取的保持一致）。
    private static func configPaths(for agentId: String) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch agentId {
        case "opencode":
            return [home.appendingPathComponent(".config/opencode/opencode.json")]
        case "claude-code":
            return [home.appendingPathComponent(".claude/settings.json")]
        case "codex":
            return [home.appendingPathComponent(".codex/config.toml")]
        case "pi":
            // pi 是「settings + models」两份，任一变化都要重拉（顺序与 Windows
            // `config_version_for` 的 "pi" 分支一致：settings 在前、models 在后）。
            return piSettingsPaths() + piModelsPaths()
        default:
            return []
        }
    }

    // MARK: - OpenCode
    // 配置：~/.config/opencode/opencode.json
    // 格式：{ "provider": { "<providerId>": { "name": "...", "models": { "<modelId>": { "name": "..." } }, "options": { "baseURL": "..." } } } }

    private static func discoverOpenCode() -> AgentProviders {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode/opencode.json")
        guard let data = try? Data(contentsOf: path) else {
            return AgentProviders(agentId: "opencode", providers: [], activeModelId: nil, error: "config not found")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providersDict = root["provider"] as? [String: Any] else {
            return AgentProviders(agentId: "opencode", providers: [], activeModelId: nil, error: "invalid config format")
        }

        var providers: [BrewPingProtocol.Provider] = []
        for (providerId, providerValue) in providersDict {
            guard let providerDict = providerValue as? [String: Any] else { continue }
            let providerName = providerDict["name"] as? String ?? providerId
            let baseURL = (providerDict["options"] as? [String: Any])?["baseURL"] as? String

            var models: [BrewPingProtocol.Model] = []
            if let modelsDict = providerDict["models"] as? [String: Any] {
                for (modelId, modelValue) in modelsDict {
                    guard let modelDict = modelValue as? [String: Any] else { continue }
                    let modelName = modelDict["name"] as? String ?? modelId
                    models.append(BrewPingProtocol.Model(
                        id: modelId, name: modelName, providerId: providerId, available: true, isActive: false
                    ))
                }
            }
            providers.append(BrewPingProtocol.Provider(
                id: providerId, name: providerName, baseURL: baseURL, models: models.sorted { $0.id < $1.id }
            ))
        }

        let firstProvider = providers.first
        let activeModelId = firstProvider?.models.first?.id
        return AgentProviders(agentId: "opencode", providers: providers.sorted { $0.id < $1.id }, activeModelId: activeModelId, error: nil)
    }

    // MARK: - Claude Code
    // 配置：~/.claude/settings.json
    // 格式：
    //   env: { ANTHROPIC_BASE_URL, ANTHROPIC_DEFAULT_SONNET_MODEL, ... }
    //   model: "sonnet" | "opus" | "haiku" (tier name)
    // 本机发现：通过环境变量找出实际 Proxy → 模型映射

    private static func discoverClaudeCode() -> AgentProviders {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = root["env"] as? [String: String] else {
            return AgentProviders(agentId: "claude-code", providers: [], activeModelId: nil, error: "config not found")
        }

        let baseURL = env["ANTHROPIC_BASE_URL"]
        let activeTier = root["model"] as? String ?? "sonnet"

        // Claude Code 通过环境变量映射 tier → model：
        // ANTHROPIC_DEFAULT_SONNET_MODEL = claude-sonnet-4-6
        // ANTHROPIC_DEFAULT_SONNET_MODEL_NAME = glm-5.3-flash (实际模型名)
        let tiers: [(envId: String, envName: String, tierName: String)] = [
            ("ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME", "sonnet"),
            ("ANTHROPIC_DEFAULT_OPUS_MODEL",   "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME",   "opus"),
            ("ANTHROPIC_DEFAULT_HAIKU_MODEL",  "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME",  "haiku"),
            ("ANTHROPIC_DEFAULT_FABLE_MODEL",  "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME",  "fable"),
        ]

        var models: [BrewPingProtocol.Model] = []
        for tier in tiers {
            guard let modelId = env[tier.envId] else { continue }
            let displayName = env[tier.envName] ?? modelId
            let isActive = (activeTier == tier.tierName)
            models.append(BrewPingProtocol.Model(
                id: modelId, name: displayName, providerId: "claude-proxy", available: true, isActive: isActive
            ))
        }

        let providerName: String
        if let baseURL {
            providerName = "Claude Proxy (\(baseURL))"
        } else {
            providerName = "Anthropic"
        }

        let provider = BrewPingProtocol.Provider(
            id: "claude-proxy", name: providerName, baseURL: baseURL, models: models
        )
        let activeModelId = models.first(where: { $0.isActive })?.id ?? models.first?.id
        return AgentProviders(agentId: "claude-code", providers: [provider], activeModelId: activeModelId, error: nil)
    }

    // MARK: - Codex CLI
    // 配置：~/.codex/config.toml
    // 格式：
    //   model_provider = "custom"
    //   model = "glm-5.2"
    //   [model_providers.custom]
    //   base_url = "http://..."

    private static func discoverCodex() -> AgentProviders {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
        // 必须走 readText：TOML 是按行 + hasPrefix 解析的，行首 BOM 会让
        // `hasPrefix("[")` 判否，整段 [model_providers.*] 被静默丢掉。
        guard let content = readText(at: path) else {
            return AgentProviders(agentId: "codex", providers: [], activeModelId: nil, error: "config not found")
        }

        let lines = content.components(separatedBy: "\n")
        var currentSection = ""
        var topLevel: [String: String] = [:]
        var sections: [String: [String: String]] = [:]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
            if trimmed.hasPrefix("["), let end = trimmed.firstIndex(of: "]") {
                currentSection = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
                continue
            }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let val = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if currentSection.isEmpty {
                topLevel[key] = val
            } else {
                sections[currentSection, default: [:]][key] = val
            }
        }

        let providerId = topLevel["model_provider"] ?? "custom"
        let activeModelId = topLevel["model"]
        let providerSection = sections["model_providers.\(providerId)"]
        let baseURL = providerSection?["base_url"]
        let providerName = providerSection?["name"] ?? providerId

        var models: [BrewPingProtocol.Model] = []
        if let modelId = activeModelId {
            models.append(BrewPingProtocol.Model(
                id: modelId, name: modelId, providerId: providerId, available: true, isActive: true
            ))
        }

        let provider = BrewPingProtocol.Provider(
            id: providerId, name: providerName, baseURL: baseURL, models: models
        )
        return AgentProviders(agentId: "codex", providers: [provider], activeModelId: activeModelId, error: nil)
    }

    // MARK: - pi
    // 配置：~/.pi/agent/settings.json（defaultProvider / defaultModel，成对生效）
    //      + ~/.pi/agent/models.json（providers.<id>.baseUrl / .models[].id|name）
    // 代理接管时 settings.defaultProvider = "brewping"（cli_takeover 写入），
    // 这里只读不改，把真实默认如实暴露给移动端。
    // 与 Windows `agent_config::read_pi` / `parse_pi` 逐分支对齐。

    private static func discoverPi() -> AgentProviders {
        guard let settingsText = readText(at: piSettingsPaths()[0]),
              let settingsData = settingsText.data(using: .utf8),
              let settings = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any] else {
            return AgentProviders(agentId: "pi", providers: [], activeModelId: nil, error: "config not found")
        }
        // 当前正在用的模型 = settings.defaultModel（未设置则 None）。
        // defaultProvider 只作定位用，不进返回结构（与 Windows 一致）。
        let activeModelId = settings["defaultModel"] as? String

        guard let modelsText = readText(at: piModelsPaths()[0]),
              let modelsData = modelsText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: modelsData) as? [String: Any],
              let providersDict = root["providers"] as? [String: Any] else {
            return AgentProviders(agentId: "pi", providers: [], activeModelId: nil, error: "config not found")
        }

        var providers: [BrewPingProtocol.Provider] = []
        for (providerId, providerValue) in providersDict {
            guard let providerDict = providerValue as? [String: Any] else { continue }
            // pi 的字段名是 `baseUrl`（小写 u），不是 `baseURL`。
            let baseURL = providerDict["baseUrl"] as? String

            var models: [BrewPingProtocol.Model] = []
            if let modelsArray = providerDict["models"] as? [[String: Any]] {
                for modelValue in modelsArray {
                    guard let modelId = modelValue["id"] as? String else { continue }
                    // 无 id 的条目直接跳过（与 Windows 的 `continue` 一致）。
                    let modelName = modelValue["name"] as? String ?? modelId
                    models.append(BrewPingProtocol.Model(
                        id: modelId,
                        name: modelName,
                        providerId: providerId,
                        available: true,
                        isActive: activeModelId == modelId
                    ))
                }
            }
            providers.append(BrewPingProtocol.Provider(
                // provider 展示名 = key 本身（pi 的 providers.<key> 没有独立 name）。
                id: providerId, name: providerId, baseURL: baseURL,
                models: models.sorted { $0.id < $1.id }
            ))
        }
        return AgentProviders(
            agentId: "pi",
            providers: providers.sorted { $0.id < $1.id },
            activeModelId: activeModelId,
            error: nil
        )
    }

    private static func piSettingsPaths() -> [URL] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/settings.json")]
    }

    private static func piModelsPaths() -> [URL] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/models.json")]
    }
}
