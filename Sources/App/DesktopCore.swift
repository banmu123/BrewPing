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

    /// 当前展示中的配对码（nil 表示尚未点开）。
    /// 配对码只在菜单栏 UI 里按需生成，不常驻内存。
    @Published public var pairingCode: String?
    @Published public var pairingCodeExpiresAt: Date?

    private var identity: DeviceIdentity?
    private var agentThread: Thread?
    private var statusTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// 防止重复启动（App 启动钩子与终端窗口都可能调用 start()）
    private var hasStarted = false

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
        guard !hasStarted else { return }
        hasStarted = true

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

    /// 生成并显示配对码，供 iPhone 首次配对使用。
    ///
    /// 按需触发（而不是启动就生成）：配对码是"这台 Mac 的执行权限"的等价物，
    /// 不点开就不该存在，也不该在屏幕上停留。
    public func revealPairingCode() {
        pairingCode = PairingStore.shared.issuePairingCode()
        pairingCodeExpiresAt = PairingStore.shared.pairingCodeExpiry
    }

    /// 强制轮换配对码，旧的立即作废。
    ///
    /// 用途：用户在菜单栏 UI 上点 "Refresh" 时。
    /// 已经在用旧码换过 token 的设备**不受影响**（token 与码独立），
    /// 只是未消费的旧码不能再换新 token。
    public func regeneratePairingCode() {
        pairingCode = PairingStore.shared.regeneratePairingCode()
        pairingCodeExpiresAt = PairingStore.shared.pairingCodeExpiry
    }

    /// 用于 QR 码内容的 brewping:// 链接。
    /// host 取自 `lanIP`，端口取自 `httpPort`。
    /// `code` 可选：iPhone 端打开链接时如果带 code 会直接发起配对；不带则弹 pair sheet。
    public func pairingURL(code: String? = nil) -> URL? {
        guard let lanIP, let httpPort else { return nil }
        var comps = URLComponents()
        comps.scheme = "brewping"
        comps.host = "pair"
        var items: [URLQueryItem] = [
            URLQueryItem(name: "host", value: lanIP),
            URLQueryItem(name: "port", value: String(httpPort)),
            URLQueryItem(name: "deviceId", value: deviceId),
            URLQueryItem(name: "name", value: deviceName)
        ]
        if let code, !code.isEmpty {
            items.append(URLQueryItem(name: "code", value: code))
        }
        comps.queryItems = items
        return comps.url
    }

    public func stop() {
        statusTimer?.invalidate()
        statusTimer = nil
        hasStarted = false
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
