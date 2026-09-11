import Foundation

enum HTTPAPI {
    static func handle(_ request: HTTPRequest, router: CommandRouter) -> HTTPResponse {
        // ---- 公开端点（不需要 token）----
        // 1) 配对入口：本身就是为了换取 token，不能要求 token；
        // 2) /api/status 只读健康检查，Mac 端自己的 DesktopCore 也要用它判活，
        //    不泄露命令内容，因此保持公开。
        if request.method == "POST", request.path == "/api/pair" {
            return pairResponse(request)
        }
        if request.method == "GET", request.path == "/api/status" {
            return statusResponse(router.route(.status))
        }

        // ---- 其余全部要求 Bearer token（写操作还要 timestamp + nonce）----
        if case .denied(let status, let error) = PairingStore.shared.authorize(request) {
            return .json(status, "Unauthorized", ["success": false, "error": error])
        }

        switch (request.method, request.path) {
        case ("GET", "/api/protocol/state"):
            return protocolStateResponse()
        case ("GET", "/api/agents"):
            return agentsResponse()
        case ("POST", "/api/agents/default"):
            return setDefaultAgentResponse(request)
        case ("POST", "/api/message"):
            return messageResponse(request, router: router)
        case ("POST", "/api/session/stop"):
            return lifecycleResponse(router.route(.stopSession))
        case ("POST", "/api/session/start"):
            return lifecycleResponse(router.route(.startSession))
        case ("POST", "/api/discovery/refresh"):
            return discoveryRefreshResponse()
        case ("GET", "/api/message"):
            return .json(405, "Method Not Allowed", ["success": false, "error": "use POST /api/message or GET /api/message/:id"])
        case let ("GET", path) where path.hasPrefix("/api/agents/") && path.hasSuffix("/models"):
            let agentID = String(path.dropFirst("/api/agents/".count).dropLast("/models".count))
            return agentModelsResponse(agentID)
        case let ("POST", path) where path.hasPrefix("/api/agents/") && path.hasSuffix("/switch"):
            let agentID = String(path.dropFirst("/api/agents/".count).dropLast("/switch".count))
            return agentSwitchResponse(agentID)
        case ("POST", "/api/agents/models/default"):
            return setDefaultModelResponse(request)
        case let ("GET", path) where path.hasPrefix("/api/message/"):
            let id = String(path.dropFirst("/api/message/".count))
            return commandResponse(id)
        case ("POST", "/api/status"):
            return .json(405, "Method Not Allowed", ["success": false, "error": "use GET /api/status"])
        default:
            return .json(404, "Not Found", ["success": false, "error": "not found"])
        }
    }

    /// `POST /api/pair` —— 用 6 位配对码换取长期 token。
    ///
    /// 请求：`{"code": "123456", "deviceName": "iPhone"}`
    /// 响应：`{"success": true, "token": "<64 位 hex>", "deviceId": "...", "deviceName": "..."}`
    private static func pairResponse(_ request: HTTPRequest) -> HTTPResponse {
        guard let object = try? JSONSerialization.jsonObject(with: request.body, options: []),
              let body = object as? [String: Any],
              let code = body["code"] as? String, !code.isEmpty else {
            return .json(400, "Bad Request", [
                "success": false,
                "error": "expected JSON body {\"code\": \"123456\"}"
            ])
        }

        // 配对码一次性且 10 分钟过期：换不到就说明码错了或已失效，
        // 不区分这两种情况，避免给暴力枚举提供反馈。
        guard let token = PairingStore.shared.exchange(code: code) else {
            return .json(401, "Unauthorized", [
                "success": false,
                "error": "invalid or expired pairing code"
            ])
        }

        let identity = DeviceIdentity.loadOrCreate()
        let deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return .json(200, "OK", [
            "success": true,
            "token": token,
            "deviceId": identity.deviceId,
            "deviceName": deviceName
        ] as [String: Any])
    }

    private static func discoveryRefreshResponse() -> HTTPResponse {
        // 强制重新扫描：重新读取各 Agent 真实配置（PATH + 版本 + 本机 Provider/Model）。
        // AgentDiscovery 缓存 60s，force=true 绕过缓存。
        // AgentConfigDiscovery 每次直接读文件，无缓存。
        // 失败时保留上次已知配置（AgentDiscovery 内部 lastSuccessful 保护）。
        let discovered = AgentDiscovery.shared.discover(force: true)
        let defaultID = AgentManager.shared.defaultAgentID

        var agents: [[String: Any]] = []
        var errors: [String] = []

        for detected in discovered {
            var entry: [String: Any] = [
                "id": detected.id,
                "name": detected.name,
                "installed": detected.installed,
                "version": detected.version ?? ""
            ]
            if detected.installed {
                let config = AgentConfigDiscovery.discover(agentId: detected.id)
                entry["providers"] = config.providers.map { p -> [String: Any] in
                    ["id": p.id, "name": p.name, "modelCount": p.models.count]
                }
                entry["activeModelId"] = config.activeModelId ?? NSNull()
                if let err = config.error { errors.append("\(detected.name): \(err)") }
            }
            entry["active"] = detected.id == defaultID
            agents.append(entry)
        }

        var object: [String: Any] = [
            "success": true,
            "status": errors.isEmpty ? "updated" : "updated_with_warnings",
            "agents": agents
        ]
        if !errors.isEmpty { object["errors"] = errors }
        return .json(200, "OK", object)
    }

    private static func agentModelsResponse(_ agentID: String) -> HTTPResponse {
        guard !agentID.isEmpty,
              AgentDiscovery.catalog.contains(where: { $0.id == agentID }) else {
            return .json(404, "Not Found", ["success": false, "error": "unknown agent"])
        }
        let config = AgentConfigDiscovery.discover(agentId: agentID)
        let defaultModelId = AgentManager.shared.defaultModel(for: agentID)
        let providers = config.providers.map { provider -> [String: Any] in
            var p: [String: Any] = ["id": provider.id, "name": provider.name]
            if let base = provider.baseURL { p["baseURL"] = base }
            p["models"] = provider.models.map { model -> [String: Any] in
                [
                    "id": model.id,
                    "name": model.name,
                    "available": model.available,
                    "isActive": model.isActive,
                    "isDefault": model.id == defaultModelId
                ]
            }
            return p
        }
        return .json(200, "OK", [
            "agentId": agentID,
            "providers": providers,
            "activeModelId": config.activeModelId ?? NSNull(),
            "preferredModelId": defaultModelId ?? NSNull()
        ] as [String: Any])
    }

    private static func setDefaultModelResponse(_ request: HTTPRequest) -> HTTPResponse {
        guard let object = try? JSONSerialization.jsonObject(with: request.body, options: []),
              let body = object as? [String: Any],
              let agentID = body["agentId"] as? String, !agentID.isEmpty else {
            return .json(400, "Bad Request", ["success": false, "error": "expected JSON body {\"agentId\": \"...\", \"modelId\": \"...\"}"])
        }
        let modelId = body["modelId"] as? String
        AgentManager.shared.setDefaultModel(modelId, for: agentID)
        return .json(200, "OK", ["success": true, "agentId": agentID, "modelId": modelId ?? NSNull()] as [String: Any])
    }

    private static func protocolStateResponse() -> HTTPResponse {
        let snapshot = ProtocolStateService.snapshot(deviceOnline: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(snapshot)) ?? Data("{}".utf8)
        return HTTPResponse(status: 200, reason: "OK", body: data)
    }

    private static func agentsResponse() -> HTTPResponse {
        let defaultID = AgentManager.shared.defaultAgentID
        let agents = AgentDiscovery.shared.discover().map { agent -> [String: Any] in
            var object: [String: Any] = [
                "id": agent.id,
                "name": agent.name,
                "command": agent.command,
                "installed": agent.installed,
                "active": agent.id == defaultID,
                "executable": agent.id == AgentManager.sessionAgentID
                    || AgentManager.shared.provider(for: agent.id) != nil
            ]
            if let version = agent.version { object["version"] = version }
            return object
        }
        return .json(200, "OK", ["agents": agents, "defaultAgent": defaultID])
    }

    private static func setDefaultAgentResponse(_ request: HTTPRequest) -> HTTPResponse {
        guard let object = try? JSONSerialization.jsonObject(with: request.body, options: []),
              let body = object as? [String: Any],
              let agentID = body["agent"] as? String, !agentID.isEmpty else {
            return .json(400, "Bad Request", ["success": false, "error": "expected JSON body {\"agent\": \"<id>\"}"])
        }
        switch AgentManager.shared.setDefaultAgent(agentID) {
        case .success:
            return .json(200, "OK", ["success": true, "defaultAgent": agentID])
        case .failure(let error):
            return .json(409, "Conflict", ["success": false, "error": error.description])
        }
    }

    private static func statusResponse(_ resp: AgentResponse) -> HTTPResponse {
        let defaultID = AgentManager.shared.defaultAgentID
        let session: Any = resp.ok
            ? [
                "id": resp.sessionID ?? "",
                "agent": defaultID,
                "agentName": AgentManager.shared.agentName(for: defaultID),
                "status": resp.status ?? "unknown"
            ]
            : NSNull()

        // 多 Agent 状态列表
        let agents: [[String: Any]] = AgentManager.shared.registeredAgents.map { agent in
            [
                "id": agent.id,
                "name": agent.name,
                "status": agent.status.rawValue
            ]
        }

        return .json(200, "OK", [
            "status": "online",
            "host": Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            "defaultAgent": defaultID,
            "activeAgent": defaultID,
            "session": session,
            "agents": agents
        ] as [String: Any])
    }

    private static func agentSwitchResponse(_ agentId: String) -> HTTPResponse {
        guard !agentId.isEmpty else {
            return .json(400, "Bad Request", ["success": false, "error": "agentId is required"])
        }
        guard AgentDiscovery.catalog.contains(where: { $0.id == agentId }) else {
            return .json(404, "Not Found", ["success": false, "error": "unknown agent: \(agentId)"])
        }

        AgentManager.shared.switchActiveAgent(agentId)
        return .json(200, "OK", [
            "success": true,
            "activeAgent": agentId
        ] as [String: Any])
    }

    private static func lifecycleResponse(_ resp: AgentResponse) -> HTTPResponse {
        if resp.ok {
            var object: [String: Any] = ["success": true]
            if let sessionID = resp.sessionID { object["sessionId"] = sessionID }
            if let status = resp.status { object["status"] = status }
            return .json(200, "OK", object)
        }
        return .json(409, "Conflict", ["success": false, "error": resp.error ?? "request failed"])
    }

    private static var appendedCommandIDs = Set<String>()
    private static let appendLock = NSLock()
    private static let maxAppendedIDs = 500

    private static func messageResponse(_ request: HTTPRequest, router: CommandRouter) -> HTTPResponse {
        guard let object = try? JSONSerialization.jsonObject(with: request.body, options: []),
              let body = object as? [String: Any],
              let text = body["text"] as? String else {
            return .json(400, "Bad Request", ["success": false, "error": "expected JSON body {\"text\": \"...\"}"])
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .json(400, "Bad Request", ["success": false, "error": "text is empty"])
        }

        // 将 iOS 发来的消息写入当前 Agent 的 TerminalState
        let agentId = AgentManager.shared.activeAgentID
        if let state = AgentManager.shared.terminalState(for: agentId) {
            DispatchQueue.main.async {
                state.appendLine("[iOS] > \(text)", type: .system)
                state.setStatus(.running)
            }
        }

        let resp = router.route(.submit(text: text))
        if resp.ok {
            return .json(200, "OK", [
                "success": true,
                "commandId": resp.commandId ?? "",
                "sessionId": resp.sessionID ?? "",
                "status": resp.status ?? CommandStatus.queued.rawValue
            ])
        }
        return .json(409, "Conflict", ["success": false, "error": resp.error ?? "send failed"])
    }

    private static func commandResponse(_ id: String) -> HTTPResponse {
        guard !id.isEmpty, let info = CommandStore.shared.get(id) else {
            return .json(404, "Not Found", ["success": false, "error": "unknown commandId"])
        }

        // 当命令完成时，将输出写入对应 Agent 的 TerminalState（仅一次）
        if (info.status == .completed || info.status == .completedWithRaw || info.status == .failed) {
            appendLock.lock()
            let alreadyAppended = appendedCommandIDs.contains(id)
            if !alreadyAppended {
                appendedCommandIDs.insert(id)
                if appendedCommandIDs.count > maxAppendedIDs {
                    appendedCommandIDs.removeAll(keepingCapacity: false)
                    appendedCommandIDs.insert(id)
                }
            }
            appendLock.unlock()

            if !alreadyAppended {
                let agentId = AgentManager.shared.activeAgentID
                if let state = AgentManager.shared.terminalState(for: agentId) {
                    let outputText = info.response ?? info.rawOutput ?? info.error ?? "(no output)"
                    let outputType: OutputType = info.status == .failed ? .error : .normal
                    DispatchQueue.main.async {
                        for line in outputText.split(separator: "\n", omittingEmptySubsequences: false) {
                            state.appendLine(String(line), type: outputType)
                        }
                        state.setStatus(.idle)
                    }
                }
            }
        }

        var object: [String: Any] = [
            "commandId": info.commandId,
            "sessionId": info.sessionId,
            "status": info.status.rawValue,
            "createdAt": ISO8601DateFormatter().string(from: info.createdAt)
        ]
        if let response = info.response { object["response"] = response }
        if let rawOutput = info.rawOutput { object["rawOutput"] = rawOutput }
        if let error = info.error { object["error"] = error }
        if let failureReason = info.failureReason { object["failureReason"] = failureReason }
        if let modelId = info.modelId { object["modelId"] = modelId }
        if let duration = info.duration { object["duration"] = (duration * 10).rounded() / 10 }
        if let completedAt = info.completedAt {
            object["completedAt"] = ISO8601DateFormatter().string(from: completedAt)
        }
        return .json(200, "OK", object)
    }
}
