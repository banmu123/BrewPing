import Foundation
import Combine

/// Desktop Core：管理 Agent 生命周期，提供状态给 Menu Bar UI。
/// 复用现有 SessionManager / OpenCodeAgent / HTTPAPI / BonjourAdvertiser / AgentDiscovery。
@MainActor
public final class DesktopCore: ObservableObject {
    public static let shared = DesktopCore()

    @Published public var isRunning = false
    @Published public var httpPort: UInt16?
    @Published public var lanIP: String?
    @Published public var deviceName: String = ""
    @Published public var deviceId: String = ""
    @Published public var agents: [DetectedAgent] = []
    @Published public var sessionStatus: String = ""
    @Published public var activeAgentID: String = AgentManager.shared.activeAgentID

    private var identity: DeviceIdentity?
    private var agentThread: Thread?
    private var statusTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // 监听 Agent 切换通知
        NotificationCenter.default.publisher(for: .activeAgentDidChange)
            .compactMap { $0.userInfo?["agentId"] as? String }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] agentId in
                self?.activeAgentID = agentId
            }
            .store(in: &cancellables)
    }

    public func start() {
        let id = DeviceIdentity.loadOrCreate()
        self.identity = id
        self.deviceId = id.deviceId
        self.deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

        if let lan = LANAddress.primaryLAN() {
            self.lanIP = lan.ip
        }

        // 复用 AgentDiscovery（只读，不重复实现）
        self.agents = AgentDiscovery.shared.discover()

        // 在后台线程启动 Agent Core（复用 BrewPingAgent.run()）
        let thread = Thread {
            BrewPingAgent.run()
        }
        thread.name = "BrewPing Desktop Agent"
        thread.start()
        self.agentThread = thread

        // 轮询 Agent 是否就绪（HTTP Server 启动后 /api/status 有响应）
        startStatusPolling()
    }

    public func stop() {
        statusTimer?.invalidate()
        statusTimer = nil
        // 通过 Unix Socket 发送 stop 指令
        let store = SessionManager.shared
        if let payload = try? JSONEncoder().encode(AgentRequest(cmd: "stop", text: nil)) {
            _ = UnixSocketClient.request(path: store.socketPath, payload: payload, timeoutSeconds: 5)
        }
        // 等待线程退出
        agentThread?.cancel()
        agentThread = nil
        isRunning = false
    }

    private func startStatusPolling() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshStatus()
            }
        }
        // 立即刷新一次
        Task { @MainActor in
            await refreshStatus()
        }
    }

    public func refreshStatus() async {
        guard let lan = LANAddress.primaryLAN() else {
            isRunning = false
            sessionStatus = "offline"
            return
        }
        lanIP = lan.ip

        // 读取 HTTP 端口
        if let info = SessionManager.shared.load(), let port = info.httpPort {
            httpPort = UInt16(port)
        } else {
            httpPort = 8787
        }

        // 请求 /api/status 验证 Agent 是否活着
        guard let port = httpPort,
              let url = URL(string: "http://\(lan.ip):\(port)/api/status") else {
            isRunning = false
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = json["status"] as? String, status == "online" {
                isRunning = true
                sessionStatus = "online"
                // 刷新 Agent 列表
                agents = AgentDiscovery.shared.discover()
                // 同步 activeAgent
                activeAgentID = AgentManager.shared.activeAgentID
            } else {
                isRunning = false
                sessionStatus = "offline"
            }
        } catch {
            isRunning = false
            sessionStatus = "offline"
        }
    }
}
