import Foundation

final class AgentManager {
    static let shared = AgentManager()

    static let sessionAgentID = "opencode"

    private let lock = NSLock()
    private var _defaultAgentID: String = AgentManager.sessionAgentID

    private var configFileURL: URL {
        SessionManager.shared.directory.appendingPathComponent("config.json")
    }

    private struct ConfigFile: Codable {
        var defaultAgent: String
        var defaultModels: [String: String]?
    }

    private init() {
        loadConfig()
    }

    private func loadConfig() {
        guard let data = try? Data(contentsOf: configFileURL),
              let config = try? JSONDecoder().decode(ConfigFile.self, from: data),
              !config.defaultAgent.isEmpty else { return }
        _defaultAgentID = config.defaultAgent
        _defaultModels = config.defaultModels ?? [:]
    }

    private func saveConfig() {
        var config = ConfigFile(defaultAgent: _defaultAgentID, defaultModels: _defaultModels)
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: configFileURL, options: .atomic)
    }

    private var _defaultModels: [String: String] = [:]

    var defaultAgentID: String {
        lock.lock()
        defer { lock.unlock() }
        return _defaultAgentID
    }

    var isDefaultSessionCapable: Bool {
        defaultAgentID == AgentManager.sessionAgentID
    }

    /// headless Provider 注册表。OpenCode 是 session 型，由既有链路负责，不在此列。
    func provider(for id: String, modelId: String? = nil) -> CodingAgent? {
        let resolved = modelId ?? resolvedModel(for: id)
        switch id {
        case "claude-code": return ClaudeCodeAgent(modelId: resolved)
        case "codex": return CodexAgent(modelId: resolved)
        case "aider": return AiderAgent(modelId: resolved)
        default: return nil
        }
    }

    func agentName(for id: String) -> String {
        if id == AgentManager.sessionAgentID { return "OpenCode" }
        return AgentDiscovery.catalog.first { $0.id == id }?.name ?? id
    }

    func defaultModel(for agentID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return _defaultModels[agentID]
    }

    func resolvedModel(for agentID: String) -> String? {
        if let preferred = defaultModel(for: agentID) { return preferred }
        let config = AgentConfigDiscovery.discover(agentId: agentID)
        return config.activeModelId
    }

    func setDefaultModel(_ modelId: String?, for agentID: String) {
        lock.lock()
        if let modelId {
            _defaultModels[agentID] = modelId
        } else {
            _defaultModels.removeValue(forKey: agentID)
        }
        saveConfig()
        lock.unlock()
    }

    /// 切换默认 Agent。目标必须存在且已安装。
    func setDefaultAgent(_ id: String) -> Result<Void, AgentManagerError> {
        guard AgentDiscovery.catalog.contains(where: { $0.id == id }) else {
            return .failure(.unknownAgent(id))
        }
        if id != AgentManager.sessionAgentID {
            guard let provider = provider(for: id), provider.detect() != nil else {
                return .failure(.notInstalled(id))
            }
        }
        lock.lock()
        _defaultAgentID = id
        saveConfig()
        lock.unlock()
        return .success(())
    }
}

enum AgentManagerError: Error, CustomStringConvertible {
    case unknownAgent(String)
    case notInstalled(String)

    var description: String {
        switch self {
        case .unknownAgent(let id): return "Unknown agent: \(id)"
        case .notInstalled(let id): return "Agent \(id) is not installed on this Mac."
        }
    }
}
