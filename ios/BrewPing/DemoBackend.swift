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
/// Demo 里"用户选过的工作目录"的存储键。
private let demoWorkdirsKey = "BrewPing.Demo.Workdirs"

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
    /// 授权模式（safe / askAll / auto），与 Mac 端 `ApprovalGate` 同构。
    /// Demo 里默认 safe，让"危险命令会先弹确认"这件事在 Demo 里也能被看见。
    private var approvalMode = "safe"
    /// 挂起待确认的命令。
    private var pendingApprovals: [String: DemoApproval] = [:]
    /// 记住用户在 Demo 里选过的模型（按 Agent 分别记），
    /// 这样"选择后立刻生效 + 下次进来还是它"能在 Demo 里被真实验证到。
    ///
    /// 落 UserDefaults 而不只放内存：真机上的 Mac 端 `AgentManager` 是持久化的，
    /// Demo 若只在内存里记，重启 App 就会退回第一个模型，与真实行为不一致。
    private var preferredModel: [String: String] =
        (UserDefaults.standard.dictionary(forKey: demoPreferredModelsKey) as? [String: String]) ?? [:]
    /// Demo 里用户选过的工作目录（按 Agent 分别记），与真机 `workdirs.json` 行为一致。
    private var workdirs: [String: String] =
        (UserDefaults.standard.dictionary(forKey: demoWorkdirsKey) as? [String: String]) ?? [:]

    private struct DemoCommand {
        let text: String
        let createdAt: Date
    }

    private struct DemoApproval {
        let text: String
        let reasons: [[String: String]]
        let createdAt: Date
    }

    private init() {}

    // MARK: - Entry

    /// 处理一条虚拟请求，返回 (HTTP 状态码, JSON 对象)。
    /// `query` 是原始 query string（不含 `?`）；目录浏览的 `path` 参数靠它传进来。
    func handle(method: String, path: String, query: String? = nil, body: Data) -> (Int, [String: Any]) {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let queryItems = Self.parseQuery(query)

        switch (method, path) {
        case ("GET", "/api/status"):
            return (200, statusPayload())

        case ("GET", "/api/agents"):
            // workdir 并进每个 agent（缺失 = 未设置），与真实桌面端的 /api/agents 对齐
            let agentsWithWorkdir: [[String: Any]] = Self.agents.map { agent in
                var a = agent
                if let id = a["id"] as? String {
                    a["workdir"] = workdirs[id] ?? NSNull()
                }
                return a
            }
            return (200, ["agents": agentsWithWorkdir, "defaultAgent": activeAgent()])

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
            // 授权门卫（与 Mac 端 ApprovalGate 同构）：safe 模式命中危险 → 挂起等确认。
            let mode = currentMode()
            let dangers = Self.demoDangers(in: text)
            if mode != "auto", !dangers.isEmpty {
                let approvalID = "apv-demo-\(UUID().uuidString)"
                lock.lock()
                pendingApprovals[approvalID] = DemoApproval(text: text, reasons: dangers, createdAt: Date())
                lock.unlock()
                return (200, [
                    "success": true,
                    "status": "pending_approval",
                    "approval": [
                        "id": approvalID,
                        "text": text,
                        "reasons": dangers,
                        "createdAt": ISO8601DateFormatter().string(from: Date())
                    ]
                ])
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
        // 授权模式读写（与 Mac 端 /api/approvals/mode 同构）
        if method == "GET", path == "/api/approvals/mode" {
            return (200, ["success": true, "mode": currentMode()])
        }
        if method == "POST", path == "/api/approvals/mode" {
            if let mode = json["mode"] as? String {
                lock.lock(); approvalMode = mode; lock.unlock()
            }
            return (200, ["success": true, "mode": currentMode()])
        }
        // 批准/拒绝挂起的命令（与 Mac 端 /api/approvals/:id 同构）
        if method == "POST", path.hasPrefix("/api/approvals/") {
            let id = String(path.dropFirst("/api/approvals/".count))
            let action = json["action"] as? String ?? ""
            if action == "deny" {
                lock.lock(); pendingApprovals.removeValue(forKey: id); lock.unlock()
                return (200, ["success": true, "status": "denied"])
            }
            lock.lock()
            let approval = pendingApprovals.removeValue(forKey: id)
            lock.unlock()
            guard let approval else {
                return (404, ["success": false, "error": "unknown or expired approval"])
            }
            let commandID = "demo-cmd-\(Int(Date().timeIntervalSince1970 * 1000))"
            lock.lock()
            commands[commandID] = DemoCommand(text: approval.text, createdAt: Date())
            lock.unlock()
            return (200, ["success": true, "commandId": commandID, "sessionId": "demo-session-0001", "status": "queued"])
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
        // ── 目录浏览（与 Windows 端 /api/folders* 同构，Demo 里也能走通"选工作目录"） ──
        if method == "GET", path == "/api/folders/roots" {
            return (200, [
                "platform": "windows",
                "pathSeparator": "\\",
                "homeDir": Self.demoHome,
                "drives": ["C:\\", "D:\\"]
            ])
        }
        if method == "GET", path == "/api/folders" {
            return browsePayload(queryItems: queryItems)
        }
        if method == "POST", path == "/api/agents/workdir" {
            let agentID = json["agentId"] as? String ?? ""
            let workdir = json["path"] as? String
            guard !agentID.isEmpty else {
                return (400, ["success": false, "error": "expected JSON body {\"agentId\": \"...\", \"path\": \"...\" | null}"])
            }
            if agentID == "opencode" {
                return (400, ["success": false, "error": "opencode does not support workdir yet"])
            }
            lock.lock()
            if let workdir, !workdir.isEmpty {
                workdirs[agentID] = workdir
            } else {
                workdirs.removeValue(forKey: agentID)
            }
            UserDefaults.standard.set(workdirs, forKey: demoWorkdirsKey)
            let saved = workdirs[agentID]
            lock.unlock()
            return (200, ["success": true, "agentId": agentID, "workdir": saved ?? NSNull()] as [String: Any])
        }
        return (404, ["success": false, "error": "not found"])
    }

    /// 解析原始 query string（`a=1&b=2`）。只做 percent-decode，不抛错。
    private static func parseQuery(_ query: String?) -> [String: String] {
        guard let query else { return [:] }
        var out: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let key = kv.first.map(String.init).flatMap({ $0.removingPercentEncoding }) else { continue }
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            out[key] = value
        }
        return out
    }

    /// Demo 浏览页的固定 home（Windows 风格路径，与 roots.homeDir 对齐）。
    private static let demoHome = "C:\\Users\\Demo"

    /// 模拟一层数据源：home → 三个项目目录（其一含 .git、其一不可读），项目下为空。
    /// 覆盖 UI 需要分辨的三种形态：普通 / git 徽章 / unreadable 置灰。
    private func browsePayload(queryItems: [String: String]) -> (Int, [String: Any]) {
        let path = queryItems["path"].flatMap { $0.isEmpty ? nil : $0 } ?? demoHome
        let showHidden = ["1", "true", "TRUE", "yes"].contains(queryItems["hidden"] ?? "")

        func entry(_ name: String, parent: String, git: Bool = false, unreadable: Bool = false) -> [String: Any] {
            var e: [String: Any] = [
                "name": name,
                "absolutePath": parent + "\\" + name,
                "isSymlink": false,
                "hidden": false
            ]
            if git { e["hints"] = ["git": true] }
            if unreadable { e["error"] = "unreadable" }
            return e
        }

        let target = path.hasSuffix("\\") ? String(path.dropLast()) : path
        let parent: String? = {
            guard let idx = target.lastIndex(of: "\\") else { return nil }
            let p = String(target[..<idx])
            // "C:" 这种无根形式视为无父目录
            return p.count <= 2 ? nil : p
        }()

        // home（含盘符根）→ projects；projects → 三个项目（git 徽章 / 普通 / 不可读）；其余为空。
        let entries: [[String: Any]]
        if target == "C:" || target == "C:\\" || target == "D:" || target == "D:\\" || target == Self.demoHome {
            entries = [
                entry("projects", parent: target),
                entry(".hidden-assets", parent: target)
            ]
        } else if target.hasSuffix("\\projects") {
            entries = [
                entry("brewping-ios", parent: target, git: true),
                entry("legacy-app", parent: target),
                entry("locked-archive", parent: target, unreadable: true)
            ]
        } else {
            entries = []
        }

        // 隐藏目录默认过滤（与真实服务端一致）
        let visible = showHidden
            ? entries
            : entries.filter { !($0["name"] as? String ?? "").hasPrefix(".") }

        return (200, [
            "path": target,
            "parentPath": parent ?? NSNull(),
            "entries": visible,
            "truncated": false
        ] as [String: Any])
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

    private func currentMode() -> String {
        lock.lock(); defer { lock.unlock() }
        return approvalMode
    }

    /// Demo 用的简化危险检测（Mac 端有完整正则 `DangerPattern`，这里只覆盖常见的几类，
    /// 让"危险命令会先弹确认"在 Demo 里也能演示，不必逐字对齐 Mac 端）。
    private static func demoDangers(in text: String) -> [[String: String]] {
        let lower = text.lowercased()
        var reasons: [[String: String]] = []
        if lower.contains("rm -rf") || lower.contains("rm -fr") || lower.contains("rm --recursive") {
            reasons.append(["code": "recursive_delete", "detail": "recursive delete"])
        }
        if lower.contains("--force") || lower.contains("push -f") {
            reasons.append(["code": "force_push", "detail": "git push --force"])
        }
        if lower.contains("sudo") {
            reasons.append(["code": "sudo", "detail": "sudo"])
        }
        if lower.contains("chmod 777") {
            reasons.append(["code": "chmod_777", "detail": "chmod 777"])
        }
        if lower.contains("git reset --hard") {
            reasons.append(["code": "git_reset_hard", "detail": "git reset --hard"])
        }
        if lower.contains("| sh") || lower.contains("| bash") {
            reasons.append(["code": "pipe_to_shell", "detail": "curl | sh"])
        }
        return reasons
    }

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
