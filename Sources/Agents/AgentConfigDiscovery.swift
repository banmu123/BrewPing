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
        case "aider":          return discoverAider()
        default:               return AgentProviders(agentId: agentId, providers: [], activeModelId: nil, error: nil)
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
        guard let content = try? String(contentsOf: path, encoding: .utf8) else {
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

    // MARK: - Aider
    // 配置：~/.aider.conf.yml 或 ~/.config/aider/config.yml
    // 当前本机未安装/未配置 → 返回空

    private static func discoverAider() -> AgentProviders {
        let paths = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aider.conf.yml"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/aider/config.yml"),
        ]
        for path in paths {
            if FileManager.default.fileExists(atPath: path.path) {
                // 简单提取 model 字段（Aider 的 yaml 配置通常有 model: xxx）
                if let content = try? String(contentsOf: path, encoding: .utf8) {
                    for line in content.components(separatedBy: "\n") {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("model:") {
                            let modelId = trimmed.replacingOccurrences(of: "model:", with: "")
                                .trimmingCharacters(in: .whitespaces)
                                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                            if !modelId.isEmpty {
                                let model = BrewPingProtocol.Model(
                                    id: modelId, name: modelId, providerId: "aider-default", available: true, isActive: true
                                )
                                let provider = BrewPingProtocol.Provider(
                                    id: "aider-default", name: "Aider Default", models: [model]
                                )
                                return AgentProviders(agentId: "aider", providers: [provider], activeModelId: modelId, error: nil)
                            }
                        }
                    }
                }
                return AgentProviders(agentId: "aider", providers: [], activeModelId: nil, error: nil)
            }
        }
        return AgentProviders(agentId: "aider", providers: [], activeModelId: nil, error: "config not found")
    }
}
