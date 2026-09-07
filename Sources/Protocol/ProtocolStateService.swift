import Foundation
import Darwin

/// Phase 2 - Protocol State Projection
///
/// 将 Mac Agent 的现有运行状态投影为 BrewPingProtocol 模型：
///   SessionManager（PTY 会话） → Session（mode = interactive）
///   CommandStore（命令记录）   → Session（mode = headless）+ Conversation
///   AgentManager/AgentDiscovery → Agent 列表
///   本机信息                    → Device
///
/// 只读、纯内存、无数据库；不改变任何既有模块的执行流程。
enum ProtocolStateService {
    struct Snapshot: Codable {
        let device: BrewPingProtocol.Device
        let agents: [BrewPingProtocol.Agent]
        let providers: [BrewPingProtocol.Provider]
        let sessions: [BrewPingProtocol.Session]
        let conversations: [BrewPingProtocol.Conversation]
    }

    static func snapshot(deviceOnline: Bool = true) -> Snapshot {
        let device = deviceProjection(online: deviceOnline)
        let commands = CommandStore.shared.all()
        let agents = agentProjections(defaultAgentID: AgentManager.shared.defaultAgentID)
        let providers = providerProjections(agents: agents)
        return Snapshot(
            device: device,
            agents: agents,
            providers: providers,
            sessions: sessionProjections(commands: commands, deviceId: device.id),
            conversations: conversationProjections(commands: commands)
        )
    }

    // MARK: - Providers

    private static func providerProjections(agents: [BrewPingProtocol.Agent]) -> [BrewPingProtocol.Provider] {
        var all: [BrewPingProtocol.Provider] = []
        for agent in agents where agent.status != .unavailable {
            let config = AgentConfigDiscovery.discover(agentId: agent.id)
            all.append(contentsOf: config.providers)
        }
        return all
    }

    // MARK: - Device

    static func deviceID() -> String {
        slug(Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
    }

    private static func deviceProjection(online: Bool) -> BrewPingProtocol.Device {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        var metadata: [String: String] = [
            "hostname": ProcessInfo.processInfo.hostName,
            "pid": String(getpid())
        ]
        if let info = SessionManager.shared.load(), let port = info.httpPort {
            metadata["httpPort"] = String(port)
        }
        return BrewPingProtocol.Device(
            id: deviceID(),
            name: name,
            platform: .macOS,
            status: online ? .online : .offline,
            metadata: metadata
        )
    }

    // MARK: - Agents

    private static func agentProjections(defaultAgentID: String) -> [BrewPingProtocol.Agent] {
        var out: [BrewPingProtocol.Agent] = []
        for detected in AgentDiscovery.shared.discover() {
            // Cursor 暂无 Provider（不可执行），不进入协议投影。
            if detected.id == "cursor" { continue }
            let isSessionAgent = detected.id == AgentManager.sessionAgentID
            let mode: BrewPingProtocol.AgentExecutionMode = isSessionAgent ? .session : .headless

            var status = BrewPingProtocol.AgentStatus.installed
            if !detected.installed {
                status = .unavailable
            } else if detected.id == defaultAgentID {
                if isSessionAgent {
                    let live = SessionManager.shared.currentStatus()
                    status = (live.ok && live.status == SessionStatus.running.rawValue) ? .running : .stopped
                } else {
                    status = .idle
                }
            }

            var metadata: [String: String] = ["path": detected.path ?? ""]
            if let modelId = AgentManager.shared.defaultModel(for: detected.id) {
                metadata["defaultModel"] = modelId
            }
            if detected.installed {
                let config = AgentConfigDiscovery.discover(agentId: detected.id)
                if let active = config.activeModelId {
                    metadata["activeModel"] = active
                }
                if let err = config.error {
                    metadata["configError"] = err
                }
            }

            out.append(BrewPingProtocol.Agent(
                id: detected.id,
                name: detected.name,
                type: detected.id,
                executionMode: mode,
                status: status,
                version: detected.version,
                metadata: metadata
            ))
        }
        return out
    }

    // MARK: - Sessions

    private static func sessionProjections(
        commands: [CommandInfo],
        deviceId: String
    ) -> [BrewPingProtocol.Session] {
        var out: [BrewPingProtocol.Session] = []

        // 1) OpenCode PTY 会话（交互式，最多一个）
        if let info = SessionManager.shared.load() {
            let live = SessionManager.shared.currentStatus()
            out.append(BrewPingProtocol.Session(
                id: info.id.uuidString,
                deviceId: deviceId,
                agentId: AgentManager.sessionAgentID,
                project: project(from: info.cwd),
                status: mapSessionStatus(live.status ?? info.status.rawValue),
                mode: .interactive,
                createdAt: info.createdAt,
                updatedAt: Date()
            ))
        }

        // 2) Headless 命令会话：每个 headless-<agent> 一次执行 = 一个会话。
        //    OpenCode 命令的 sessionId 与 PTY 会话 id 相同，不重复投影
        //    （其消息进入 Conversation）。
        var bySession: [String: [CommandInfo]] = [:]
        for command in commands where command.sessionId.hasPrefix("headless-") {
            bySession[command.sessionId, default: []].append(command)
        }
        for (sessionId, group) in bySession.sorted(by: { $0.value.first?.createdAt ?? Date() < $1.value.first?.createdAt ?? Date() }) {
            let agentID = sessionId.replacingOccurrences(of: "headless-", with: "")
            let first = group.first!
            let last = group.last!
            out.append(BrewPingProtocol.Session(
                id: sessionId,
                deviceId: deviceId,
                agentId: agentID,
                project: project(from: FileManager.default.currentDirectoryPath),
                status: mapCommandStatus(last.status),
                mode: .headless,
                createdAt: first.createdAt,
                updatedAt: last.completedAt ?? last.createdAt
            ))
        }
        return out
    }

    // MARK: - Conversations

    private static func conversationProjections(commands: [CommandInfo]) -> [BrewPingProtocol.Conversation] {
        commands.map { command in
            var conversation = BrewPingProtocol.Conversation(
                id: "conv_" + command.commandId,
                sessionId: command.sessionId,
                title: String(command.text.prefix(48)),
                messages: [],
                createdAt: command.createdAt,
                updatedAt: command.completedAt ?? command.createdAt
            )
            conversation.append(role: .user, content: command.text)
            let assistantContent = command.response ?? command.rawOutput ?? command.error
            if let content = assistantContent, !content.isEmpty {
                conversation.append(role: .assistant, content: content)
            }
            return conversation
        }
    }

    // MARK: - Mappings

    private static func mapCommandStatus(_ status: CommandStatus) -> BrewPingProtocol.SessionLifecycle {
        switch status {
        case .queued, .sent: return .queued
        case .working: return .running
        case .completed, .completedWithRaw: return .completed
        case .failed: return .failed
        }
    }

    private static func mapSessionStatus(_ raw: String) -> BrewPingProtocol.SessionLifecycle {
        switch raw {
        case SessionStatus.starting.rawValue: return .created
        case SessionStatus.running.rawValue: return .running
        case SessionStatus.exited.rawValue: return .stopped
        case SessionStatus.failed.rawValue: return .failed
        default: return .created
        }
    }

    private static func project(from cwd: String) -> String {
        (cwd as NSString).lastPathComponent
    }

    private static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        let filtered = lowered.unicodeScalars.filter { allowed.contains($0) }
        let result = String(String.UnicodeScalarView(filtered))
        return result.isEmpty ? "unknown-device" : result
    }
}
