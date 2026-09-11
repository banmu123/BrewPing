import Foundation

/// Demo 模式的后端模拟器。
///
/// 目的很窄：让 App Store 审核员在**没有任何 Mac、也没有任何硬件**的情况下
/// 走通完整链路（添加设备 → 看到 Agent 列表 → Start Session → 发送命令 → 看到结果）。
/// 这同时解决 Guideline 2.1（可测性）、4.2（最小功能性）与"依赖外部设备"三个问题。
///
/// 实现方式是 `URLProtocol` 拦截：只接管主机名为 `demo.brewping.local` 的请求，
/// 真实设备完全不受影响，调用方也无需感知（仍然照常写 URLSession 代码）。
/// Demo 里"用户选过的模型"的存储键。
/// 放在类型外是因为 Swift 不允许在**存储属性的初始化器**里引用 `Self`（covariant 'Self'）。
private let demoPreferredModelsKey = "BrewPing.Demo.PreferredModels"

final class DemoBackend {
    static let shared = DemoBackend()

    /// Demo 设备的固定主机名，`ManagedDevice.isDemo` 据此判定。
    static let host = "demo.brewping.local"
    static let port = "8787"

    /// 模拟的 Agent 列表。名称仅用于说明"可兼容哪些 CLI"，
    /// 界面另有免责声明（见 `BrewPingConfig.trademarkDisclaimer`）。
    private static let agents: [[String: Any]] = [
        ["id": "opencode", "name": "OpenCode", "installed": true, "active": true, "executable": true, "version": "0.4.2 (demo)"],
        ["id": "claude-code", "name": "Claude Code", "installed": true, "active": false, "executable": true, "version": "1.9.0 (demo)"],
        ["id": "codex", "name": "Codex CLI", "installed": false, "active": false, "executable": false]
    ]

    /// 每个 Agent 的模拟可选模型。用真实世界里常见的大模型名做示例，
    /// 让"切换模型"这件事在 Demo 里也能被看见（而不是一个永远为空的入口）。
    private static let models: [String: [[String: Any]]] = [
        "opencode": [
            ["id": "claude-sonnet-4", "name": "Claude Sonnet 4", "available": true],
            ["id": "gpt-5", "name": "GPT-5", "available": true],
            ["id": "glm-4.6", "name": "GLM-4.6", "available": true]
        ],
        "claude-code": [
            ["id": "sonnet", "name": "Sonnet", "available": true],
            ["id": "opus", "name": "Opus", "available": true],
            ["id": "haiku", "name": "Haiku", "available": true]
        ],
        "codex": [
            ["id": "gpt-5", "name": "GPT-5", "available": true],
            ["id": "o4-mini", "name": "o4-mini", "available": true]
        ]
    ]

    private let lock = NSLock()
    private var sessionActive = false
    private var activeAgentID = "opencode"
    private var commands: [String: DemoCommand] = [:]
    /// 记住用户在 Demo 里选过的模型（按 Agent 分别记），
    /// 这样"选择后立刻生效 + 下次进来还是它"能在 Demo 里被真实验证到。
    ///
    /// 落 UserDefaults 而不只放内存：真机上的 Mac 端 `AgentManager` 是持久化的，
    /// Demo 若只在内存里记，重启 App 就会退回第一个模型，与真实行为不一致。
    private var preferredModel: [String: String] =
        (UserDefaults.standard.dictionary(forKey: demoPreferredModelsKey) as? [String: String]) ?? [:]

    private struct DemoCommand {
        let text: String
        let createdAt: Date
    }

    private init() {}

    // MARK: - Entry

    /// 处理一条虚拟请求，返回 (HTTP 状态码, JSON 对象)。
    func handle(method: String, path: String, body: Data) -> (Int, [String: Any]) {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]

        switch (method, path) {
        case ("GET", "/api/status"):
            return (200, statusPayload())

        case ("GET", "/api/agents"):
            return (200, ["agents": Self.agents, "defaultAgent": activeAgent()])

        case ("POST", "/api/agents/default"):
            let agentID = json["agent"] as? String ?? "opencode"
            setActiveAgent(agentID)
            return (200, ["success": true, "defaultAgent": agentID])

        case ("POST", "/api/session/start"):
            lock.lock(); sessionActive = true; lock.unlock()
            return (200, ["success": true, "sessionId": "demo-session-0001", "status": "running"])

        case ("POST", "/api/session/stop"):
            lock.lock(); sessionActive = false; lock.unlock()
            return (200, ["success": true, "status": "stopped"])

        case ("POST", "/api/message"):
            let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return (400, ["success": false, "error": "text is empty"])
            }
            let commandID = "demo-cmd-\(Int(Date().timeIntervalSince1970 * 1000))"
            lock.lock()
            commands[commandID] = DemoCommand(text: text, createdAt: Date())
            lock.unlock()
            return (200, ["success": true, "commandId": commandID, "sessionId": "demo-session-0001", "status": "queued"])

        default:
            break
        }

        if method == "GET", path.hasPrefix("/api/message/") {
            let id = String(path.dropFirst("/api/message/".count))
            return commandStatus(id: id)
        }
        if method == "POST", path.hasPrefix("/api/agents/"), path.hasSuffix("/switch") {
            let agentID = String(path.dropFirst("/api/agents/".count).dropLast("/switch".count))
            setActiveAgent(agentID)
            return (200, ["success": true, "activeAgent": agentID])
        }
        // 模型列表：与 Mac 端 `GET /api/agents/<id>/models` 完全同构
        // （providers → models 两层），这样 iOS 端解析逻辑在 Demo 与真机上一致。
        if method == "GET", path.hasPrefix("/api/agents/"), path.hasSuffix("/models") {
            let agentID = String(path.dropFirst("/api/agents/".count).dropLast("/models".count))
            return (200, modelsPayload(agentID: agentID))
        }
        if method == "POST", path == "/api/agents/models/default" {
            let agentID = json["agentId"] as? String ?? activeAgent()
            let modelID = json["modelId"] as? String
            lock.lock()
            if let modelID { preferredModel[agentID] = modelID }
            UserDefaults.standard.set(preferredModel, forKey: demoPreferredModelsKey)
            let saved = preferredModel[agentID]
            lock.unlock()
            return (200, ["success": true, "agentId": agentID, "modelId": saved ?? NSNull()] as [String: Any])
        }
        return (404, ["success": false, "error": "not found"])
    }

    // MARK: - Payloads

    private func statusPayload() -> [String: Any] {
        let active = activeAgent()
        let running = isSessionActive()
        let session: Any = running
            ? [
                "id": "demo-session-0001",
                "agent": active,
                "agentName": Self.displayName(for: active),
                "status": "running"
              ]
            : NSNull()

        return [
            "status": "online",
            "host": L("Demo Mac (Simulated)"),
            "defaultAgent": active,
            "activeAgent": active,
            "session": session,
            "agents": Self.agents.map { ["id": $0["id"] ?? "", "name": $0["name"] ?? "", "status": "idle"] }
        ]
    }

    /// `GET /api/agents/<id>/models` 的响应，结构与 Mac 端一致。
    private func modelsPayload(agentID: String) -> [String: Any] {
        let list = Self.models[agentID] ?? []
        lock.lock()
        let preferred = preferredModel[agentID]
        lock.unlock()
        let marked = list.map { model -> [String: Any] in
            let id = model["id"] as? String ?? ""
            var m = model
            m["isActive"] = (id == preferred) || (preferred == nil && id == (list.first?["id"] as? String))
            m["isDefault"] = (id == preferred)
            return m
        }
        return [
            "agentId": agentID,
            "providers": [["id": "demo", "name": "Demo Provider", "models": marked]],
            "activeModelId": list.first?["id"] as? String ?? NSNull(),
            "preferredModelId": preferred ?? NSNull()
        ] as [String: Any]
    }

    /// 命令状态随时间推进，让 UI 能真实地走过 queued → working → completed。
    private func commandStatus(id: String) -> (Int, [String: Any]) {
        lock.lock()
        let command = commands[id]
        lock.unlock()

        guard let command else {
            return (404, ["success": false, "error": "unknown commandId"])
        }

        let elapsed = Date().timeIntervalSince(command.createdAt)
        var payload: [String: Any] = [
            "commandId": id,
            "sessionId": "demo-session-0001",
            "createdAt": ISO8601DateFormatter().string(from: command.createdAt)
        ]

        switch elapsed {
        case ..<1.2:
            payload["status"] = "queued"
        case ..<3.6:
            payload["status"] = "working"
        default:
            payload["status"] = "completed"
            payload["duration"] = (elapsed * 10).rounded() / 10
            payload["modelId"] = "demo-model"
            payload["response"] = Self.demoResponse(for: command.text)
        }
        return (200, payload)
    }

    private static func demoResponse(for text: String) -> String {
        // 走本地化表（key: demo.commandResponse）而不是内联多行字符串，
        // 否则这段文案不会跟随 App 内的语言切换。
        L("demo.commandResponse", text, BrewPingConfig.macAppName)
    }

    // MARK: - State helpers

    private func isSessionActive() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessionActive
    }

    private func activeAgent() -> String {
        lock.lock(); defer { lock.unlock() }
        return activeAgentID
    }

    private func setActiveAgent(_ id: String) {
        lock.lock(); activeAgentID = id; lock.unlock()
    }

    private static func displayName(for id: String) -> String {
        agents.first { ($0["id"] as? String) == id }?["name"] as? String ?? id
    }
}
