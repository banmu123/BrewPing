import Foundation
import Combine

/// Desktop Core：管理 Agent 生命周期，提供状态给 Menu Bar UI。
/// 复用现有 SessionManager / OpenCodeAgent / HTTPAPI / BonjourAdvertiser / AgentDiscovery。
@MainActor
public final class DesktopCore: ObservableObject {
    public static let shared = DesktopCore()

    /// 三段式运行时状态。UI 用它来判断指示灯颜色 / 文案。
    /// - `.idle`：从未启动（默认）。
    /// - `.starting`：已经 spawn 了后台 agent 线程，但 `/api/status` 还没回过 200。
    ///   这一段是启动最慢的环节（OpenCode 子进程启动 + HTTP server listen），可能 5-10 秒。
    ///   UI 在此期间显示灰点 + "Starting…"，避免被误判为离线。
    /// - `.online`：`/api/status` 返回了 `status: online`，可以接受 iOS 端的命令。
    /// - `.offline`：曾经 online 但 `/api/status` 请求失败（agent 崩溃 / 网络抖动）。
    public enum RuntimeState: String { case idle, starting, online, offline }

    @Published public var runtimeState: RuntimeState = .idle
    /// 旧字段，仅保留兼容（`isRunning == runtimeState == .online`）。
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

        // 立刻置 starting：让 UI 在 5-10 秒的 spawn 期内显示灰点 + "Starting…"，
        // 而不是停留在默认的 .idle（被 MenuBarView 渲染成红色 Offline，让用户以为没启起来）。
        runtimeState = .starting
        isRunning = false
        sessionStatus = "starting"

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
        runtimeState = .idle
        isRunning = false
        sessionStatus = ""
    }

    private func startStatusPolling() {
        // 加速轮询：启动后前 5 秒每 200ms 一次，让 online 状态尽快反映到 UI。
        // 之后回到稳定的 2s 间隔，避免无意义的网络噪声。
        // 切到 .online 后立即停止 fast loop —— ready 后不再需要高频探测。
        schedulePoll(intervalMs: 200, maxIterations: 25)  // 25 × 200ms = 5s
    }

    /// 启动一个高频轮询循环，跑 `maxIterations` 次或直到 `runtimeState` 离开 `.starting`。
    private func schedulePoll(intervalMs: Int, maxIterations: Int) {
        statusTimer?.invalidate()
        var iteration = 0
        statusTimer = Timer.scheduledTimer(withTimeInterval: Double(intervalMs) / 1000.0, repeats: true) { [weak self] timer in
            iteration += 1
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                await self.refreshStatus()
                // 离开 starting（online/offline）就停 fast loop，或者达到上限。
                if self.runtimeState != .starting || iteration >= maxIterations {
                    timer.invalidate()
                    if self.runtimeState == .online {
                        // ready 后回到稳态 2s 轮询
                        self.statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                            Task { @MainActor in await self?.refreshStatus() }
                        }
                    }
                }
            }
        }
        // 立刻跑一次，不等第一个 tick。
        Task { @MainActor in
            await refreshStatus()
        }
    }

    public func refreshStatus() async {
        guard let lan = LANAddress.primaryLAN() else {
            runtimeState = .offline
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
            runtimeState = .offline
            isRunning = false
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = json["status"] as? String, status == "online" {
                runtimeState = .online
                isRunning = true
                sessionStatus = "online"
                // 刷新 Agent 列表
                agents = AgentDiscovery.shared.discover()
                // 同步 activeAgent
                activeAgentID = AgentManager.shared.activeAgentID
            } else {
                // /api/status 返回 200 但 status != online —— 还在启动中，保持 starting，
                // 不要在 spawn 期间把它误降级成 offline，否则 fast loop 会被无意义地延长。
                if runtimeState == .starting {
                    sessionStatus = "starting"
                } else {
                    runtimeState = .offline
                    isRunning = false
                    sessionStatus = "offline"
                }
            }
        } catch {
            // 连接失败：HTTP server 还没 listen 时会走这里，仍属 starting 阶段。
            if runtimeState == .starting {
                sessionStatus = "starting"
            } else {
                runtimeState = .offline
                isRunning = false
                sessionStatus = "offline"
            }
        }
    }
}
