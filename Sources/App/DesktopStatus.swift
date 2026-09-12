import Foundation

/// 桌面端状态载荷 —— 与 Windows `get_status` 返回的 `DesktopStatus`（`src/api/types.ts`）
/// 字段逐一对齐，供桌面 UI 取代 Tauri `invoke`。
public struct DesktopStatusAgent: Codable {
    public var id: String
    public var name: String
    public var installed: Bool
    public var active: Bool
    public var executable: String?
    public var version: String?
}

public struct DesktopStatusSession: Codable {
    public var id: String
    public var agent: String
    public var agentName: String
    public var status: String
}

public struct DesktopStatus: Codable {
    public var host: String
    public var defaultAgent: String
    public var session: DesktopStatusSession?
    public var agents: [DesktopStatusAgent]
    public var port: UInt16
    public var lanIp: String?
    public var mdnsRunning: Bool
    public var platform: String
    public var version: String
    public var deviceId: String
    public var activeAgentId: String
    /// 当前激活的对话 ID（草稿态为 nil）。
    public var activeConversationId: String?
    /// 三段式运行时状态（对齐 `DesktopCore.RuntimeState` 的 rawValue）。
    public var runtimeState: String

    /// 组装当前快照。
    ///
    /// 数据全部来自已有单例，**不新增数据源**：
    /// - Agent 列表 ← `AgentDiscovery`（磁盘上真实安装的 CLI）
    /// - 激活 Agent / 运行时状态 / 配对 ← `AgentManager` / `DesktopCore`
    /// - 激活对话 ← `ConversationStore`
    public static func current(port: UInt16, lanIp: String?, mdnsRunning: Bool, runtimeState: String) -> DesktopStatus {
        let detected = AgentDiscovery.shared.discover()
        let defaultID = AgentManager.shared.defaultAgentID
        let manager = AgentManager.shared

        let agents = detected.map { agent in
            DesktopStatusAgent(
                id: agent.id,
                name: agent.name,
                installed: agent.installed,
                active: agent.id == defaultID,
                executable: agent.path,
                version: agent.version
            )
        }

        // session 的语义与 `/api/status` 一致：会话型 Agent 活着才有值。
        let sessionID = SessionManager.shared.currentStatus().sessionID
        let session = sessionID.map { id in
            DesktopStatusSession(
                id: id,
                agent: defaultID,
                agentName: manager.agentName(for: defaultID),
                status: "online"
            )
        }

        return DesktopStatus(
            host: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            defaultAgent: defaultID,
            session: session,
            agents: agents,
            port: port,
            lanIp: lanIp,
            mdnsRunning: mdnsRunning,
            platform: "macOS",
            version: DesktopStatus.appVersion,
            deviceId: DeviceIdentity.loadOrCreate().deviceId,
            activeAgentId: manager.activeAgentID,
            activeConversationId: ConversationStore.shared.activeConversation(),
            runtimeState: runtimeState
        )
    }

    /// 版本号：优先取 Info.plist（打包后的 .app），SwiftPM 直跑时回落 1.0.0。
    public static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }
}
