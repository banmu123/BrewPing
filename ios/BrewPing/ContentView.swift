import SwiftUI
import UIKit

struct StatusResponse: Decodable {
    let status: String?
    let host: String?
    /// 当前生效（默认）Agent 的 id。**这是权威值**，切换默认 Agent 后随之变化。
    let defaultAgent: String?
    let session: SessionBrief?
}

struct SessionBrief: Decodable {
    let id: String?
    let agent: String?
    let agentName: String?
    let status: String?
}

// SubmitResponse / CommandStatusResponse 已随命令提交引擎移到 CommandReceiver.swift。

struct LifecycleResponse: Decodable {
    let success: Bool?
    let sessionId: String?
    let status: String?
    let error: String?
}

struct AgentsResponse: Decodable {
    let agents: [AgentEntry]?
    let defaultAgent: String?
}

struct AgentEntry: Decodable, Identifiable {
    let id: String
    let name: String
    let installed: Bool
    let active: Bool?
    let executable: Bool?
    let version: String?
    /// 用户在该主机上选定的工作目录；缺失/为 null = 未设置（跟随进程当前目录）。
    /// 老版本桌面端不返回这个字段，`?` 保证解码不炸。
    let workdir: String?
}

enum SessionState: Equatable {
    case offline
    case starting
    case running
    case stopping
}

// CommandPhase 已随命令提交引擎一起移到 CommandReceiver.swift。

// MARK: - ContentView

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var deviceStore = DeviceStore.shared
    @StateObject private var watchBridge = WatchConnectivityManager.shared
    @StateObject private var submitter = CommandSubmitter.shared
    @StateObject private var bonjour = BonjourDiscovery()
    /// 当前 Agent 的可切换模型（数据源是 Mac 端 `/api/agents/<id>/models`）。
    @StateObject private var modelStore = ModelStore.shared
    /// 授权模式（safe / askAll / auto），读写 Mac 端 `/api/approvals/mode`。
    @StateObject private var approvalMode = ApprovalModeStore.shared
    /// brewping:// 入口：Mac 端 QR 码扫码后唤起 App，BrewPingApp 在 .onOpenURL 里写入，
    /// 这里消费一次后清空。
    @EnvironmentObject private var pairingURL: PairingURLHandler
    @State private var messageText = ""
    @State private var clearDraftWhenDelivered = false
    @State private var online = false
    @State private var hostName = ""
    @State private var sessionState: SessionState = .offline
    @State private var sessionID = ""
    /// **当前生效（默认）Agent** 的 id —— 由 `/api/status` 的 `defaultAgent` 给出。
    /// 展示名、模型列表、Watch 同步都以它为准。
    /// 注意不要用 `session.agent` 代替：`session` 描述的是"正在跑的会话"，
    /// 主机切换默认 Agent 时会把会话置空（Windows 桌面端就是这样），
    /// 用它会导致切了默认 Agent 之后界面纹丝不动。
    @State private var sessionAgentIDFromStatus = "opencode"
    @State private var sessionAgentNameFromStatus = "OpenCode"
    /// 运行中会话所属的 Agent（`session.agent`），无会话时为 `"opencode"`。
    /// 只用来判断"要不要显示会话启停按钮"，不参与展示当前 Agent。
    @State private var runningSessionAgentID = "opencode"
    @State private var sessionMessage = ""
    /// 与 Mac 通信失败的可读原因。原来这些错误只被吞掉（`catch { online = false }`），
    /// 审核员看到的是"界面一直离线但没有任何解释"。
    @State private var statusError: String?
    /// `/api/agents` 是否因鉴权失败（401）而拿不到数据。
    /// 必须单独记：`/api/status` 是公开端点，token 失效时它仍返回 200 让 `online` 为 true，
    /// 于是"agents 为空 + online 为 true"会被误渲染成永远的 "Detecting agents..."。
    @State private var agentsUnauthorized = false
    @State private var lifecycleBusy = false
    @State private var agents: [AgentEntry] = []
    @State private var discoveryMessage = ""
    @State private var showHelp = false
    /// 控制面板弹窗（Agent 列表 / 会话启停 / 模型 / 授权 / 工作目录）。
    @State private var showControls = false

    // 命令的提交与轮询统一由 CommandSubmitter 负责（见 CommandReceiver.swift），
    // 视图只是它的观察者。这样即使界面没被创建，Watch 来的命令也能照常执行。
    private var phase: CommandPhase { submitter.phase }
    private var lastDuration: Double? { submitter.lastDuration }
    private var lastFailureReason: String? { submitter.lastFailureReason }
    private var lastModelId: String? { submitter.lastModelId }

    // 添加设备 Sheet
    @State private var showAddDevice = false
    @State private var editingDevice: ManagedDevice?
    @State private var editName = ""
    @State private var editHost = ""
    @State private var editPort = "8787"
    @State private var editOS: DeviceOSType = .mac
    @State private var editPairingCode = ""
    @State private var pairingBusy = false
    @State private var pairingMessage = ""
    /// 配对表单里的扫码页开关。
    @State private var showScanner = false

    private var activeDevice: ManagedDevice? { deviceStore.activeDevice }
    private var baseURL: URL? { activeDevice?.baseURL }
    private var hasDevice: Bool { activeDevice != nil }
    /// 只有真正进入后台才停轮询（`.inactive` 包含系统弹窗等瞬时状态，不应停）。
    private var isInBackground: Bool { scenePhase == .background }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                deviceTabBar

                // 已配对设备：主页 = 桌面端同步过来的对话（按绑定的工作目录分组）；
                // 未添加 / 未配对时才是引导表单。
                // 原有的 Agent 列表、会话启停、模型 / 授权 / 工作目录等控制项
                // 收进右上角「控制面板」弹窗（功能不变，只是不再占主页）。
                if let device = activeDevice, DeviceAuth.isPaired(device) {
                    if statusError != nil {
                        statusBannerRow
                    }
                    ConversationListView(
                        device: device,
                        online: online,
                        agentNames: agentNameMap
                    )
                } else {
                    Form {
                        if deviceStore.devices.isEmpty {
                            emptyStateCard
                        } else if let device = activeDevice {
                            notPairedCard(device)
                        }

                        statusBanner
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color.bpBackground)
                    .tint(Color.bpPrimary)
                }
            }
            .background(Color.bpBackground)
            .navigationTitle("BrewPing")
            .navigationDestination(for: ConversationRoute.self) { route in
                conversationDestination(route)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showControls = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel(Text("Controls"))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityLabel("Help and About")
                }
            }
            .sheet(isPresented: $showControls) {
                controlPanel
            }
            .sheet(isPresented: $showHelp) {
                HelpView()
            }
            .sheet(isPresented: Binding(
                get: { submitter.pendingApproval != nil },
                set: { if !$0 { submitter.clearPendingApproval() } }
            )) {
                if let approval = submitter.pendingApproval {
                    ApprovalRequestView(approval: approval) { action in
                        submitter.decide(action: action)
                    }
                }
            }
            .sheet(isPresented: $showAddDevice) {
                deviceFormSheet(isNew: true)
            }
            .sheet(item: $editingDevice) { device in
                deviceFormSheet(isNew: false, existing: device)
            }
            // 轮询随 scenePhase 起停：进后台立刻停，回前台重新拉一次。
            // 用 .task(id:) 而不是在闭包里 sleep 判断，是为了让系统在切换时直接取消旧任务。
            .task(id: scenePhase) {
                await runStatusLoop()
            }
            .task(id: deviceStore.activeDeviceID) {
                // 切换设备后重新读该 Mac 的授权模式（每台 Mac 的设置独立）。
                await approvalMode.refresh()
            }
            .onChange(of: pairingURL.pendingAction) { _, newAction in
                // 冷启动时 ContentView 还没 onAppear，但 URL 可能已存进 pendingAction，
                // 这次 onChange 会在 ContentView 渲染后第一时间触发。
                if let action = newAction {
                    Task { await consumePairAction(action) }
                }
            }
            .onChange(of: deviceStore.activeDeviceID) { _, _ in
                Task {
                    resetState()
                    await refreshStatus()
                    await refreshAgents()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                // 让 WCSession 知道 App 是否在前台：
                // 决定收到手表语音后要不要在本机回放（后台唤醒时不出声）。
                watchBridge.appIsActive = (newPhase == .active)
            }
            .onChange(of: submitter.phase) { _, newPhase in
                // 手动发送成功投递后才清空输入框（与旧行为一致），
                // 失败时保留草稿，方便用户重试。
                if newPhase == .delivered, clearDraftWhenDelivered {
                    messageText = ""
                    clearDraftWhenDelivered = false
                }
            }
        }
    }

    // MARK: - 首次启动 / 空状态

    // MARK: - 对话主页 / 控制面板（本轮新增）

    /// 对话详情的导航目标（既有对话 / 新对话草稿）。
    @ViewBuilder
    private func conversationDestination(_ route: ConversationRoute) -> some View {
        if let device = activeDevice {
            switch route {
            case .existing(let id):
                ConversationDetailView(
                    conversationId: id,
                    device: device,
                    online: online,
                    agentNames: agentNameMap,
                    fallbackAgentId: activeAgentID
                )
            case .draft:
                ConversationDetailView(
                    conversationId: nil,
                    device: device,
                    online: online,
                    agentNames: agentNameMap,
                    fallbackAgentId: activeAgentID
                )
            }
        } else {
            Text("Add a device first")
                .font(.footnote)
                .foregroundStyle(Color.bpMutedForeground)
        }
    }

    /// agentId → 显示名（复用已拉取的 /api/agents 结果，避免对话列表再打一次接口）。
    private var agentNameMap: [String: String] {
        var map: [String: String] = [:]
        for agent in agents {
            map[agent.id] = agent.name
        }
        return map
    }

    /// 连接异常提示（非 Form 版：主页是 List 时也要能看到原因）。
    @ViewBuilder
    private var statusBannerRow: some View {
        if let statusError, hasDevice {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bpWarning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: statusError)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.bpForeground)
                    if let device = activeDevice {
                        Text("Make sure \(BrewPingConfig.macAppName) is running on \(device.host), and that both devices are on the same Wi-Fi.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.bpMutedForeground)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.bpWarning.opacity(0.12))
        }
    }

    /// 控制面板：原有的状态、Agent 列表、会话启停、模型 / 授权 / 工作目录入口。
    private var controlPanel: some View {
        NavigationStack {
            Form {
                statusBanner
                agentListCard
                sessionCard

                if !sessionMessage.isEmpty {
                    Section {
                        Text(verbatim: sessionMessage)
                            .font(.footnote)
                            .foregroundStyle(Color.bpWarning)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.bpBackground)
            .tint(Color.bpPrimary)
            .navigationTitle("Controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showControls = false }
                }
            }
        }
    }

    /// 没有设备时的引导卡片。
    /// 审核员下载后看到的第一屏就是这里 —— 必须自解释"需要配套 Mac 端"，
    /// 否则会被判定为 2.1 App Completeness 问题。
    ///
    /// 由 3 个 Section 拼成：
    ///   1. 引导说明（如何把 Mac 接进来）
    ///   2. 局域网自动发现（核心改进：首装用户不用先点 "+" 也能看到 Mac）
    ///   3. 手动 / Demo 入口
    @ViewBuilder
    private var emptyStateCard: some View {
        Group {
            getStartedSection
            // 扫到任意 Mac，或正在扫，都展示该 Section —— 扫到 0 个时给"未找到"提示
            // 比单纯不显示 Section 更友好。
            discoveredMacsSection
            quickActionsSection
        }
        .onAppear { bonjour.startSearching() }
        .onDisappear { bonjour.stopSearching() }
    }

    /// Section 1：基础说明 + 引导步骤
    private var getStartedSection: some View {
        Section("Get started") {
            VStack(alignment: .leading, spacing: 10) {
                Label("No Mac connected yet", systemImage: "desktopcomputer")
                    .font(.headline)

                Text("BrewPing needs **\(BrewPingConfig.macAppName)** running on your Mac. Your iPhone is the remote control; your Mac runs the coding agents.")
                    .font(.callout)
                    .foregroundStyle(Color.bpMutedForeground)

                VStack(alignment: .leading, spacing: 6) {
                    guideStep(1, "Install and open \(BrewPingConfig.macAppName) on your Mac.")
                    guideStep(2, "Keep this iPhone and your Mac on the same Wi-Fi.")
                    guideStep(3, "In \(BrewPingConfig.macAppName), click the menu bar icon and tap “Show Pairing Code”. A QR code will appear.")
                    guideStep(4, "Scan the QR with your iPhone, or enter the 6-digit code in the device sheet.")
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Section 2：局域网自动发现的 Mac。
    /// 关键改进：首装用户**不再需要先点 + 再等"Auto Discover"按钮**，
    /// 进入空状态时即开始扫描，结果直接以列表形式呈现。
    private var discoveredMacsSection: some View {
        Section {
            if bonjour.isSearching || bonjour.isResolving {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Scanning for \(BrewPingConfig.macAppName) on this Wi-Fi...")
                        .font(.footnote)
                        .foregroundStyle(Color.bpMutedForeground)
                }
            }
            ForEach(bonjour.discoveredHosts) { host in
                Button {
                    handleDiscoveredHost(host)
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        // 图标跟随广播方声明的主机类型（Mac/Win/Linux），不再写死 macstudio。
                        Image(systemName: host.osType.icon)
                            .font(.title3)
                            .foregroundStyle(Color.bpPrimary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.name)
                                .font(.callout)
                                .foregroundStyle(Color.bpForeground)
                            Text("\(host.host):\(host.port)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Color.bpMutedForeground)
                        }
                        Spacer()
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Color.bpPrimary)
                    }
                }
                .buttonStyle(.plain)
            }
            if !bonjour.isSearching && !bonjour.isResolving && bonjour.discoveredHosts.isEmpty {
                Label("No BrewPing Mac found on this Wi-Fi yet.", systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(Color.bpMutedForeground)
            }
        } header: {
            Text("Macs on this Wi-Fi")
        } footer: {
            // 引导去 Mac 端操作：用户看了"自动发现"列表后，最自然的下一步就是
            // 走到 Mac 那边去找配对码 / QR。
            Text("If the list is empty, open \(BrewPingConfig.macAppName) on your Mac and reveal the pairing code (a QR will appear).")
                .font(.footnote)
        }
    }

    /// Section 3：手动添加 / Demo 入口
    private var quickActionsSection: some View {
        Section {
            HStack(spacing: 10) {
                Button {
                    startAddDevice()
                } label: {
                    Label("Add Manually", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    deviceStore.addDemoDevice()
                } label: {
                    Label("Try Demo Mode", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 2)

            Text("No Mac at hand? Demo Mode walks through the whole flow locally, without any hardware.")
                .font(.footnote)
                .foregroundStyle(Color.bpMutedForeground)
        }
    }

    /// 用户在自动发现列表里点了一台主机。
    /// 流程：先 addDevice（host/port 已知）→ 弹出 pair sheet（只填 6 位码）→ 提交即配对。
    private func handleDiscoveredHost(_ host: BonjourDiscovery.DiscoveredHost) {
        // 已存在同 host+port 的设备？直接进 pair sheet 走老路径
        if var existing = deviceStore.devices.first(where: {
            $0.host.caseInsensitiveCompare(host.host) == .orderedSame
            && $0.port == String(host.port)
        }) {
            // 顺手用广播里的 platform 纠正历史误标（早期版本一律存成 Mac）。
            if existing.osType != host.osType {
                existing.osType = host.osType
                deviceStore.updateDevice(existing)
            }
            beginEditing(existing)
            return
        }
        // 新建设备：主机类型取自 TXT 记录的 platform，不再硬编码 .mac。
        let device = ManagedDevice.new(
            name: host.name,
            host: host.host,
            port: String(host.port),
            osType: host.osType
        )
        deviceStore.addDevice(device)
        deviceStore.setActive(device.id)
        // 弹出 pair sheet —— 复用现有 addDevice sheet，自动会展示 pairing code 输入框
        startAddDevice()
    }

    /// 处理 brewping:// 唤起：参数化 addDevice + pair。
    private func consumePairAction(_ action: PairingURLHandler.Action) async {
        let normalizedPort = action.port
        // 1) 查找是否已有同 host:port
        let existing = deviceStore.devices.first(where: {
            $0.host.caseInsensitiveCompare(action.host) == .orderedSame
            && $0.port == normalizedPort
        })
        let device: ManagedDevice
        if var existing {
            // 已存在的设备顺手自愈：主机类型以深链为准。
            // 历史版本不带 osType，Windows 主机被存成了 Mac，这里正好纠正过来。
            if existing.osType != action.osType {
                existing.osType = action.osType
                deviceStore.updateDevice(existing)
            }
            device = existing
            deviceStore.setActive(device.id)
        } else {
            device = ManagedDevice.new(
                name: action.suggestedName,
                host: action.host,
                port: normalizedPort,
                osType: action.osType
            )
            deviceStore.addDevice(device)
            deviceStore.setActive(device.id)
        }
        // 2) 消费动作 —— 必须在发起网络请求前清掉，
        //    否则 pair 过程中如果再来一个 URL 会并发改状态。
        pairingURL.consume()
        // 3) 如果 URL 自带 6 位码，直接走 pair；否则弹 sheet 让用户输。
        let trimmedCode = action.code.trimmingCharacters(in: .whitespaces)
        if !trimmedCode.isEmpty {
            pairingBusy = true
            let result = await pair(device: device, code: trimmedCode)
            pairingBusy = false
            if !result.ok {
                // 配对失败时给出可恢复入口：用户可手动重新输入
                pairingMessage = result.message
                editPairingCode = ""
                beginEditing(device)
            } else {
                await refreshStatus()
                await refreshAgents()
            }
        } else {
            // 让用户输码
            beginEditing(device)
        }
    }

    private func guideStep(_ index: Int, _ key: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index).")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.bpMutedForeground)
            Text(key)
                .font(.footnote)
        }
    }

    /// 设备存在但还没有配对 token。
    private func notPairedCard(_ device: ManagedDevice) -> some View {
        Section("Pairing required") {
            Label("This device is not paired yet.", systemImage: "key.slash")
                .font(.callout)
            Text("Open \(BrewPingConfig.macAppName) on \(device.host), reveal its pairing code, then enter the code for this device.")
                .font(.footnote)
                .foregroundStyle(Color.bpMutedForeground)
            Button {
                beginEditing(device)
            } label: {
                Label("Enter pairing code", systemImage: "key")
            }
        }
    }

    /// 连接异常提示。替代原来"只把 online 置 false、用户看不到任何原因"的行为。
    @ViewBuilder
    private var statusBanner: some View {
        if let statusError, hasDevice {
            Section {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.bpWarning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: statusError)
                            .font(.footnote)
                        if let device = activeDevice {
                            Text("Make sure \(BrewPingConfig.macAppName) is running on \(device.host), and that both devices are on the same Wi-Fi.")
                                .font(.caption2)
                                .foregroundStyle(Color.bpMutedForeground)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 设备 Tab 栏

    private var deviceTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(deviceStore.devices) { device in
                    deviceTab(device)
                }

                Button {
                    startAddDevice()
                } label: {
                    if deviceStore.devices.isEmpty {
                        // 空态下必须有文字：只有一个 "+" 图标审核员不知道要做什么。
                        Label("Add Device", systemImage: "plus.circle.fill")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.bpPrimary.opacity(0.12)))
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.bpPrimary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.bpBackground)
    }

    private func deviceTab(_ device: ManagedDevice) -> some View {
        let isActive = device.id == deviceStore.activeDeviceID
        return Button {
            deviceStore.setActive(device.id)
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: device.osType.icon)
                        .font(.system(size: 11))
                    Text(device.name.isEmpty ? device.host : device.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if !DeviceAuth.isPaired(device) {
                        Image(systemName: "key.slash")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.bpWarning)
                    }
                }
                Circle()
                    .fill(isActive && online ? Color.bpSuccess : (isActive ? Color.bpWarning : Color.bpMutedForeground))
                    .frame(width: 5, height: 5)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.bpAccent : Color.bpCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? Color.bpPrimary.opacity(0.4) : Color.bpBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                beginEditing(device)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deviceStore.removeDevice(id: device.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - 添加/编辑设备 Sheet

    private func startAddDevice() {
        editName = ""
        editHost = ""
        editPort = "8787"
        editOS = .mac
        editPairingCode = ""
        pairingMessage = ""
        discoveryMessage = ""
        showAddDevice = true
    }

    private func beginEditing(_ device: ManagedDevice) {
        editName = device.name
        editHost = device.host
        editPort = device.port
        editOS = device.osType
        editPairingCode = ""
        pairingMessage = ""
        discoveryMessage = ""
        editingDevice = device
    }

    private func deviceFormSheet(isNew: Bool, existing: ManagedDevice? = nil) -> some View {
        NavigationStack {
            Form {
                Section("Device Info") {
                    TextField("Name (e.g. Chenzk)", text: $editName)
                        .autocorrectionDisabled()
                    TextField("Host (IP or hostname)", text: $editHost)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $editPort)
                        .keyboardType(.numberPad)
                    Picker("System", selection: $editOS) {
                        ForEach(DeviceOSType.allCases, id: \.self) { os in
                            Label(os.label, systemImage: os.icon).tag(os)
                        }
                    }
                }

                Section {
                    Button(bonjour.isSearching
                           ? LocalizedStringKey("Searching...")
                           : LocalizedStringKey("Auto Discover")) {
                        Task { await discoverForSheet() }
                    }
                    .disabled(bonjour.isSearching)
                    if !discoveryMessage.isEmpty {
                        Text(verbatim: discoveryMessage)
                            .font(.caption)
                            .foregroundStyle(Color.bpMutedForeground)
                    }
                }

                Section {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    }
                    TextField("6-digit pairing code", text: $editPairingCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                    if pairingBusy {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Pairing...")
                                .font(.callout)
                        }
                    }
                    if !pairingMessage.isEmpty {
                        Text(verbatim: pairingMessage)
                            .font(.caption)
                            .foregroundStyle(Color.bpMutedForeground)
                    }
                } header: {
                    Text("Pairing")
                } footer: {
                    Text("Shown in \(BrewPingConfig.macAppName) on your Mac. Required before this app can send commands. Leave empty to save the device without pairing.")
                }

                Section {
                    Button {
                        deviceStore.addDemoDevice()
                        showAddDevice = false
                        editingDevice = nil
                    } label: {
                        Label("Add Demo Device (no Mac needed)", systemImage: "sparkles")
                    }
                }
            }
            .navigationTitle(isNew
                             ? LocalizedStringKey("Add Device")
                             : LocalizedStringKey("Edit Device"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showAddDevice = false
                        editingDevice = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? LocalizedStringKey("Add") : LocalizedStringKey("Save")) {
                        Task { await commitDeviceForm(isNew: isNew, existing: existing) }
                    }
                    .disabled(editHost.trimmingCharacters(in: .whitespaces).isEmpty || pairingBusy)
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView { scanned in
                    showScanner = false
                    applyScannedValue(scanned)
                }
            }
        }
    }

    /// 处理扫码结果：把二维码内容解析并填进表单，由用户确认后再提交。
    ///
    /// 不直接发起配对，是为了让用户在表单里**看到**读到的 host / port / code，
    /// 确认无误再点 Pair —— 扫码错了（扫到别的码）也有机会发现。
    private func applyScannedValue(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        pairingMessage = ""

        // 1) Mac 端 QR 的正式格式：brewping://pair?host=...&port=...&code=...&name=...
        if let url = URL(string: trimmed),
           url.scheme?.lowercased() == "brewping",
           url.host?.lowercased() == "pair" {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let dict = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            if let host = dict["host"], !host.isEmpty { editHost = host }
            if let port = dict["port"], !port.isEmpty { editPort = port }
            if let code = dict["code"], !code.isEmpty { editPairingCode = code }
            if let name = dict["name"], !name.isEmpty { editName = name }
            pairingMessage = L("Scanned. Tap Pair to finish.")
            return
        }

        // 2) 容忍纯 6 位码（有些用户会把码单独做成二维码）。
        if trimmed.count == 6, trimmed.allSatisfy({ $0.isNumber }) {
            editPairingCode = trimmed
            pairingMessage = L("Scanned. Tap Pair to finish.")
            return
        }

        pairingMessage = L("This QR code isn't a BrewPing pairing code.")
    }

    private func commitDeviceForm(isNew: Bool, existing: ManagedDevice?) async {
        let trimmedHost = editHost.trimmingCharacters(in: .whitespaces)
        let trimmedName = editName.trimmingCharacters(in: .whitespaces)
        let code = editPairingCode.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty else { return }

        let device: ManagedDevice
        if isNew {
            device = ManagedDevice.new(
                name: trimmedName.isEmpty ? editOS.label : trimmedName,
                host: trimmedHost,
                port: editPort,
                osType: editOS
            )
            deviceStore.addDevice(device)
        } else if var updated = existing {
            updated.name = trimmedName
            updated.host = trimmedHost
            updated.port = editPort
            updated.osType = editOS
            deviceStore.updateDevice(updated)
            device = updated
        } else {
            return
        }

        // Demo 设备不需要配对码；没填码则先保存成"未配对"，界面上会给出重新配对的入口。
        guard !code.isEmpty, !device.isDemo else {
            showAddDevice = false
            editingDevice = nil
            return
        }

        pairingBusy = true
        pairingMessage = ""
        let result = await pair(device: device, code: code)
        pairingBusy = false
        pairingMessage = result.message
        guard result.ok else { return }

        showAddDevice = false
        editingDevice = nil
        if deviceStore.activeDeviceID != device.id {
            deviceStore.setActive(device.id)
        }
        await refreshStatus()
        await refreshAgents()
    }

    private func pair(device: ManagedDevice, code: String) async -> (ok: Bool, message: String) {
        guard let request = BrewPingHTTP.pairingRequest(
            host: device.host,
            port: device.port,
            code: code,
            deviceName: UIDevice.current.name
        ) else {
            return (false, L("Invalid host or port."))
        }
        do {
            let (data, response) = try await BrewPingHTTP.session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let decoded = try? JSONDecoder().decode(PairingResponse.self, from: data)
            if statusCode == 200, decoded?.success == true, let token = decoded?.token, !token.isEmpty {
                DeviceAuth.store(token: token, for: device)
                BrewPingLog.net.info("Paired with host \(device.host, privacy: .private)")
                return (true, L("Paired successfully."))
            }
            return (false, decoded?.error ?? L("Pairing failed (HTTP %@).", String(statusCode)))
        } catch {
            return (false, L("Pairing failed: %@", error.localizedDescription))
        }
    }

    private func discoverForSheet() async {
        bonjour.startSearching()
        // 等到「发现 + 解析」都结束（最多 10 秒）
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !bonjour.discoveredHosts.isEmpty { break }
            if !bonjour.isSearching && !bonjour.isResolving { break }
        }
        if let host = bonjour.discoveredHosts.first {
            editHost = host.host
            editPort = String(host.port)
            editName = host.name
            discoveryMessage = L("Found: %@ (%@:%@)", host.name, host.host, String(host.port))
        } else {
            discoveryMessage = L("No BrewPing agent found. Make sure %@ is running and on the same Wi-Fi.",
                                 BrewPingConfig.macAppName)
        }
    }

    // MARK: - Agent List

    private var agentListCard: some View {
        Section("AI Agents") {
            if agents.isEmpty {
                // 三元表达式的两个分支都要显式转成 LocalizedStringKey，
                // 否则会被推断成 String、走 Text 的 verbatim 重载而不翻译。
                // 三种"空"要分开说：鉴权失败 ≠ Mac 离线 ≠ 真的没装 agent。
                Text(agentsUnauthorized
                     ? LocalizedStringKey("Not paired with this Mac. Enter the pairing code in this device's settings.")
                     : (online
                        ? LocalizedStringKey("Detecting agents...")
                        : LocalizedStringKey("No agents detected. Connect a paired Mac to list the coding agents installed on it.")))
                    .font(.caption)
                    .foregroundStyle(Color.bpMutedForeground)
            } else {
                ForEach(agents) { agent in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(agent.installed ? Color.bpSuccess : Color.bpMutedForeground.opacity(0.5))
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(agent.name)
                                    .font(.callout)
                                if agent.active == true {
                                    Text("Default")
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.bpSuccess.opacity(0.15)))
                                        .foregroundStyle(Color.bpSuccess)
                                }
                            }
                            // 版本号是数据、不翻译；没有版本号时才显示本地化文案。
                            if agent.installed, let version = agent.version, !version.isEmpty {
                                Text(verbatim: version)
                                    .font(.caption)
                                    .foregroundStyle(Color.bpMutedForeground)
                            } else {
                                Text(agent.installed
                                     ? LocalizedStringKey("Installed")
                                     : LocalizedStringKey("Not Installed"))
                                    .font(.caption)
                                    .foregroundStyle(Color.bpMutedForeground)
                            }
                        }
                        Spacer()
                        if agent.active != true, agent.installed, agent.executable == true {
                            Button("Set Default") {
                                setDefaultAgent(agent.id)
                            }
                            .font(.caption)
                            .disabled(lifecycleBusy)
                        }
                    }
                }

                // 商标免责：列出兼容的 Agent 名称属于"兼容性说明"，
                // 必须同时声明无关联，否则容易被 5.2.1 判定为暗示授权/背书。
                // 免责声明在 BrewPingConfig 里是 String，显式转成 key 才能被翻译。
                Text(LocalizedStringKey(BrewPingConfig.trademarkDisclaimer))
                    .font(.caption2)
                    .foregroundStyle(Color.bpMutedForeground)
            }
        }
    }

    // MARK: - Session Card

    private var sessionCard: some View {
        Section("Active Agent") {
            HStack(spacing: 8) {
                Text(activeAgentName)
                    .font(.headline)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(sessionDotColor)
                        .frame(width: 10, height: 10)
                    Text(sessionStateText)
                        .font(.callout)
                        .foregroundStyle(Color.bpMutedForeground)
                }
            }
            modelRow
            workdirRow
            approvalModeRow
            if !sessionID.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session ID")
                        .font(.caption2)
                        .foregroundStyle(Color.bpMutedForeground)
                    Text(String(sessionID.prefix(12)) + "...")
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
            if !sessionMessage.isEmpty {
                Text(verbatim: sessionMessage)
                    .font(.caption)
                    .foregroundStyle(Color.bpMutedForeground)
            }
            // 会话启停按钮的显示条件：
            //  - 正在跑会话 → 必须显示（否则切到非 OpenCode 的默认 Agent 后就停不掉了）；
            //  - 没有会话时，按"会话型 Agent"判断，保持既有语义（OpenCode 需要显式开会话，
            //    headless Agent 是发一条执行一条）。
            // 这里**不能**用 `activeAgentID`：它现在跟的是默认 Agent，而默认 Agent 是
            // headless 时并不代表这台主机不需要会话（Windows 端发命令就要求先有会话）。
            if sessionState == .running || runningSessionAgentID == "opencode" {
                actionButton
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.circle.fill")
                        .foregroundStyle(Color.bpPrimary)
                        .font(.caption)
                    Text("Ready — type a command below to send")
                        .font(.caption2)
                        .foregroundStyle(Color.bpMutedForeground)
                }
            }
        }
    }

    private var activeAgentID: String { sessionAgentIDFromStatus }
    private var activeAgentName: String { sessionAgentNameFromStatus }

    /// 当前默认 Agent 的 id：**以 `/api/status` 的 `defaultAgent` 为准**。
    ///
    /// 为什么不用 `session.agent`：`session` 描述的是"正在跑的会话"，
    /// 主机切换默认 Agent 时会把会话置空，于是 `session.agent` 读到的永远是旧值/缺失值
    /// （Windows 桌面端就是这种实现），表现为"切了默认 Agent，iOS 这边纹丝不动"。
    /// 老版本服务端没有 `defaultAgent` 字段时才退回 `session.agent`，再退回 `opencode`。
    private static func resolvedActiveAgentID(from decoded: StatusResponse) -> String {
        if let id = decoded.defaultAgent, !id.isEmpty { return id }
        if let id = decoded.session?.agent, !id.isEmpty { return id }
        return "opencode"
    }

    /// 解析默认 Agent 的展示名。
    /// 顺序：① `/api/status` 附带的 `agentName`（仅当它描述的确实是这个 Agent）
    /// ② `/api/agents` 列表里的 `name`（没有运行中会话时只能靠它）
    /// ③ 退回 id 本身（列表还没拉到时短暂可见，不算错误）
    private func resolvedActiveAgentName(id: String, from brief: SessionBrief?) -> String {
        if let brief, brief.agent == id, let name = brief.agentName, !name.isEmpty {
            return name
        }
        if let match = agents.first(where: { $0.id == id }), !match.name.isEmpty {
            return match.name
        }
        return id
    }

    /// 模型切换入口，放在会话页顶部（Agent 名下方）。
    /// **只在真的有得选时才出现** —— 0 个（没配或没拿到）或 1 个（没得选）时隐藏，
    /// 与其给一个点开只有一行的入口，不如不显示。
    @ViewBuilder
    private var modelRow: some View {
        if modelStore.canSwitch {
            NavigationLink {
                ModelPickerView()
            } label: {
                HStack(spacing: 8) {
                    Text("Model")
                        .font(.callout)
                    Spacer()
                    // 模型名是用户配置的数据，不翻译。
                    Text(verbatim: modelStore.activeModelName ?? "—")
                        .font(.callout)
                        .foregroundStyle(Color.bpMutedForeground)
                        .lineLimit(1)
                }
            }
        }
    }

    /// 工作目录入口 —— **必须排在模型入口（`modelRow`）下面**（用户明确要求的顺序）。
    ///
    /// 显示条件：有已配对设备且默认 Agent 不是 opencode（stub 不 spawn 子进程，
    /// 主机端会直接拒绝，提前拦住避免一次注定失败的请求）。
    /// 老版本桌面端没有目录浏览接口时降级：入口仍显示，点进去看解释文案。
    @ViewBuilder
    private var workdirRow: some View {
        if let device = activeDevice, DeviceAuth.isPaired(device),
           FolderBrowserStore.supportsWorkdir(agentID: activeAgentID) {
            NavigationLink {
                FolderBrowserView(
                    device: device,
                    agentID: activeAgentID,
                    currentWorkdir: activeAgentWorkdir,
                    onSet: { _ in
                        Task { await refreshAgents() }
                    }
                )
            } label: {
                HStack(spacing: 8) {
                    Text("Working Folder Entry")
                        .font(.callout)
                    Spacer()
                    // workdir 是主机上的路径数据，不翻译。
                    Text(verbatim: activeAgentWorkdir ?? "—")
                        .font(.caption)
                        .foregroundStyle(Color.bpMutedForeground)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
    }

    /// 当前默认 Agent 在主机上已设置的工作目录（`/api/agents` 的 `workdir` 字段）。
    private var activeAgentWorkdir: String? {
        agents.first(where: { $0.id == activeAgentID })?.workdir ?? nil
    }

    /// 授权模式切换，紧跟在模型入口下方。
    /// 与 `modelRow` 不同的是：只要有**已配对**的设备就显示（授权档位是安全设置，
    /// 不该像模型那样"没得选就隐藏"）。但**未配对时必须隐藏** ——
    /// 没有 token 的请求会被 Mac 端直接判 401，显示出来只会让用户以为"坏了"。
    @ViewBuilder
    private var approvalModeRow: some View {
        if let device = activeDevice, DeviceAuth.isPaired(device) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(systemName: approvalMode.mode == .auto ? "shield.slash" : "shield.lefthalf.filled")
                        .foregroundStyle(approvalMode.mode == .auto ? Color.bpWarning : Color.bpMutedForeground)
                        .font(.callout)
                    Text("Approval Mode")
                        .font(.callout)
                    Spacer()
                    Picker("Approval Mode", selection: Binding(
                        get: { approvalMode.mode },
                        set: { newMode in Task { await approvalMode.setMode(newMode) } }
                    )) {
                        ForEach(ApprovalModeStore.Mode.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                Text(approvalMode.mode.summary)
                    .font(.caption2)
                    .foregroundStyle(Color.bpMutedForeground)
                // 切换失败时明确告知原因，不要让用户面对"点了没反应"的静默回退。
                if let error = approvalMode.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(Color.bpDestructive)
                }
            }
        }
    }

    private var actionButton: some View {
        Button {
            switch sessionState {
            case .running: stopSession()
            case .offline: newSession()
            default: break
            }
        } label: {
            HStack {
                Spacer()
                switch sessionState {
                case .running:
                    Label("Stop Session", systemImage: "stop.fill")
                case .offline:
                    // 无设备时按钮文案自解释，配合 .disabled 彻底消除"点了没反应"。
                    Label(hasDevice
                          ? LocalizedStringKey("Start Session")
                          : LocalizedStringKey("Add a device first"),
                          systemImage: hasDevice ? "play.fill" : "plus.circle")
                case .starting:
                    HStack(spacing: 8) { ProgressView(); Text("Starting...") }
                case .stopping:
                    HStack(spacing: 8) { ProgressView(); Text("Stopping...") }
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
        .tint(actionTint)
        .disabled(!hasDevice || lifecycleBusy || sessionState == .starting || sessionState == .stopping)
    }

    private var actionTint: Color {
        guard hasDevice else { return Color.bpMutedForeground }
        return sessionState == .running ? Color.bpDestructive : Color.bpSuccess
    }

    private var sessionDotColor: Color {
        switch sessionState {
        case .running: return Color.bpSuccess
        case .starting: return Color.bpWarning
        case .stopping: return Color.bpWarning
        case .offline: return online ? Color.bpMutedForeground : Color.bpDestructive
        }
    }

    /// 返回 `LocalizedStringKey` 而不是 `String`：
    /// `Text(String)` 走 verbatim 重载、不查语言包，`Text(LocalizedStringKey)` 才会翻译。
    private var sessionStateText: LocalizedStringKey {
        switch sessionState {
        case .running: return "Running"
        case .starting: return "Starting..."
        case .stopping: return "Stopping..."
        case .offline: return "Offline"
        }
    }

    // MARK: - Message

    private var messageSection: some View {
        Section("Message") {
            TextField("Hello from iPhone", text: $messageText, axis: .vertical)
                .lineLimit(3...5)
                .autocorrectionDisabled()
                .disabled(sessionState != .running)
            Button {
                send()
            } label: {
                if phase.inFlight {
                    HStack { ProgressView(); Text("Sending...") }
                } else {
                    Text("Send")
                }
            }
            .disabled(sessionState != .running || phase.inFlight || messageText.trimmingCharacters(in: .whitespaces).isEmpty)
            if sessionState != .running {
                Text(hasDevice
                     ? LocalizedStringKey("Start a session to enable sending.")
                     : LocalizedStringKey("Add a device to enable sending."))
                    .font(.caption2)
                    .foregroundStyle(Color.bpMutedForeground)
            }
        }
    }

    // MARK: - Result View

    @ViewBuilder
    private var resultView: some View {
        switch phase {
        case .idle:
            Text("No message sent yet.")
                .font(.caption)
                .foregroundStyle(Color.bpMutedForeground)
        case .sending:
            HStack(spacing: 8) {
                ProgressView()
                Text("Sending...")
                    .font(.callout)
            }
        case .delivered:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.bpSuccess)
                Text("Delivered")
                    .font(.callout)
                Spacer()
                ProgressView()
            }
        case .working:
            HStack(spacing: 8) {
                Circle().fill(Color.bpWarning).frame(width: 10, height: 10)
                Text("Working")
                    .font(.callout)
                Spacer()
                ProgressView()
            }
        case .completed(let response):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.bpSuccess)
                    durationSuffix("Completed").font(.callout).fontWeight(.medium)
                }
                agentModelLine
                Text(response)
                    .font(.body)
                    .textSelection(.enabled)
            }
        case .completedRaw(let raw):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.bpSuccess)
                    durationSuffix("Completed").font(.callout).fontWeight(.medium)
                }
                agentModelLine
                Text("Raw screen output")
                    .font(.caption)
                    .foregroundStyle(Color.bpMutedForeground)
                Text(raw)
                    .font(.footnote)
                    .foregroundStyle(Color.bpMutedForeground)
                    .textSelection(.enabled)
            }
        case .failed(let error):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.bpDestructive)
                    durationSuffix("Failed").font(.callout).fontWeight(.medium)
                }
                agentModelLine
                if let reason = lastFailureReason {
                    Text(failureReasonLabel(reason))
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.bpDestructive)
                }
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Color.bpMutedForeground)
                    .textSelection(.enabled)
            }
        }
    }

    /// 返回 `Text` 而不是 `String`：这样 `base` 能以 `LocalizedStringKey` 的身份被翻译，
    /// 时长则用 `verbatim` 原样拼上（"4.2s" 不需要翻译）。
    private func durationSuffix(_ base: LocalizedStringKey) -> Text {
        guard let d = lastDuration else { return Text(base) }
        return Text(base) + Text(verbatim: String(format: " · %.1fs", d))
    }

    private var agentModelLine: some View {
        HStack(spacing: 12) {
            if !sessionAgentNameFromStatus.isEmpty {
                Text(sessionAgentNameFromStatus)
                    .font(.caption)
                    .foregroundStyle(Color.bpMutedForeground)
            }
            if let model = lastModelId {
                Text(model)
                    .font(.caption)
                    .foregroundStyle(Color.bpMutedForeground)
            }
        }
    }

    /// 返回 `LocalizedStringKey`：`reason` 是后端给的机器可读码，
    /// 已知的码映射成可翻译文案，未知的原样展示。
    private func failureReasonLabel(_ reason: String) -> LocalizedStringKey {
        switch reason {
        case "quota_exceeded":         return "Quota exceeded"
        case "authentication_failed":  return "Authentication failed"
        case "rate_limited":           return "Rate limited"
        case "network_error":          return "Network error"
        case "model_unavailable":      return "Model unavailable"
        case "provider_error":         return "Provider error"
        case "timeout":                return "Timeout"
        case "process_exited":         return "Process exited"
        default:                       return LocalizedStringKey(reason)
        }
    }

    // MARK: - State Reset

    private func resetState() {
        online = false
        hostName = ""
        sessionState = .offline
        sessionID = ""
        sessionAgentIDFromStatus = "opencode"
        sessionAgentNameFromStatus = "OpenCode"
        runningSessionAgentID = "opencode"
        sessionMessage = ""
        statusError = nil
        submitter.reset()
        agents = []
        // 设备被切走/移除：缓存的模型属于旧设备，必须失效重拉。
        modelStore.invalidate()
        // 同理：对话列表/详情也属于旧设备，必须清空，否则会串到另一台机器上。
        ConversationStore.shared.invalidate()
    }

    // MARK: - Polling

    /// 状态轮询主循环。
    ///
    /// 只在 App **进入后台**时停：进后台立刻停（旧实现是"视图活着就一直每 5 秒打一次"），
    /// 回到前台由 `.task(id:)` 重新拉起并立刻刷新一次。
    ///
    /// 注意这里刻意用 `.inactive` 之外的判断（`!isInBackground`），而不是 `== .active`：
    /// 首次启动弹出语音授权弹窗时，App 会短暂进入 `.inactive`，
    /// 若按 `.active` 判定，循环会在弹窗期间直接返回、界面停在"离线"不再刷新，
    /// 直到用户手动关闭弹窗才恢复 —— 实机复现过这个卡死。
    private func runStatusLoop() async {
        // 语音识别权限只能在前台弹窗，先在这里定下来，
        // 否则手表在后台发来的语音会因为权限未决而识别失败。
        watchBridge.requestSpeechAuthorizationIfNeeded()
        watchBridge.appIsActive = (scenePhase == .active)

        guard !isInBackground else { return }

        await refreshStatus()
        await refreshAgents()

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { break }
            await refreshStatus()
        }
    }

    // MARK: - Networking

    private func refreshStatus() async {
        guard let device = activeDevice,
              let request = BrewPingHTTP.request(device: device, path: "/api/status", timeout: 10) else {
            online = false
            hostName = ""
            statusError = nil
            if !lifecycleBusy { sessionState = .offline }
            return
        }

        do {
            let (data, response) = try await BrewPingHTTP.session.data(for: request)

            if BrewPingHTTP.isUnauthorized(response) {
                // 不打印主机名以外的内容；主机名也可能是用户名，标记 .private。
                BrewPingLog.net.error("Status request unauthorized for \(device.host, privacy: .private)")
                online = false
                hostName = ""
                statusError = L("Not paired with %@.", device.host)
                if !lifecycleBusy { sessionState = .offline }
                return
            }

            let decoded = try JSONDecoder().decode(StatusResponse.self, from: data)
            online = decoded.status == "online"
            hostName = decoded.host ?? ""
            statusError = nil
            sessionID = decoded.session?.id ?? ""
            // 会话侧（只喂给会话启停按钮的门控）
            runningSessionAgentID = decoded.session?.agent ?? "opencode"
            // 默认 Agent 侧（展示 / 模型列表 / Watch 都用它）。
            let defaultAgentID = Self.resolvedActiveAgentID(from: decoded)
            sessionAgentIDFromStatus = defaultAgentID
            sessionAgentNameFromStatus = resolvedActiveAgentName(id: defaultAgentID, from: decoded.session)
            let serverStatus = decoded.session?.status ?? ""
            if !lifecycleBusy {
                sessionState = (serverStatus == "running") ? .running : .offline
            }
            watchBridge.currentOnline = online
            watchBridge.currentSessionState = serverStatus
            watchBridge.currentAgentName = sessionAgentNameFromStatus
            watchBridge.currentAgentMode = sessionAgentIDFromStatus == "opencode" ? "session" : "headless"
            watchBridge.currentAgentID = sessionAgentIDFromStatus
            if !agents.isEmpty {
                watchBridge.knownAgents = agents.map { ["id": $0.id, "name": $0.name] }
            }
            // 同步设备列表到 Watch
            watchBridge.knownDevices = deviceStore.devices.map { d in
                ["id": d.id, "name": d.displayName, "os": d.osType.rawValue]
            }
            watchBridge.activeDeviceID = deviceStore.activeDeviceID
            // 模型列表跟着 Agent / 设备走：两者任一变化才真正发请求（ModelStore 内部去重）。
            await refreshModels()
            watchBridge.pushStatus(online: online, sessionStateRaw: serverStatus)
        } catch {
            online = false
            hostName = ""
            statusError = L("Can't reach %@: %@", device.host, error.localizedDescription)
            BrewPingLog.net.error("Status request failed: \(error.localizedDescription, privacy: .private)")
            if !lifecycleBusy {
                sessionState = .offline
                sessionID = ""
            }
            // 请求失败时**保留**上一次已知的默认 Agent：这一次没拿到新信息，
            // 没必要把标题打回 "OpenCode" 再等下一次轮询改回来（会闪）。
            runningSessionAgentID = "opencode"
            watchBridge.currentOnline = false
            watchBridge.currentSessionState = ""
            watchBridge.pushStatus(online: false, sessionStateRaw: "")
        }
    }

    private func refreshAgents() async {
        guard let request = BrewPingHTTP.request(device: activeDevice, path: "/api/agents", timeout: 10) else {
            agents = []
            agentsUnauthorized = false
            return
        }
        do {
            let (data, response) = try await BrewPingHTTP.session.data(for: request)
            if BrewPingHTTP.isUnauthorized(response) {
                // 401：Mac 在线但没通过鉴权（未配对 / token 失效）。
                // 显式标记，避免界面永远停在 "Detecting agents..."。
                agents = []
                agentsUnauthorized = true
                return
            }
            let decoded = try JSONDecoder().decode(AgentsResponse.self, from: data)
            agents = decoded.agents ?? []
            agentsUnauthorized = false
            // `/api/status` 只在有运行中会话时才带得住 agentName，
            // 列表到位后把当前 Agent 的展示名补齐（否则会短暂显示成 id）。
            if let match = agents.first(where: { $0.id == sessionAgentIDFromStatus }),
               !match.name.isEmpty {
                sessionAgentNameFromStatus = match.name
            }
        } catch {
            agents = []
        }
    }

    /// 拉模型列表，并同步一份给 Watch（与 agents 同一条通道）。
    private func refreshModels() async {
        await modelStore.refresh(device: activeDevice, agentID: activeAgentID)
        watchBridge.knownModels = modelStore.models.map { ["id": $0.id, "name": $0.name] }
        watchBridge.activeModelID = modelStore.activeModelID ?? ""
    }

    private func setDefaultAgent(_ id: String) {
        guard var request = BrewPingHTTP.request(device: activeDevice, path: "/api/agents/default", method: "POST", timeout: 15) else {
            sessionMessage = L("No Mac connected. Add a device first.")
            return
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["agent": id])
        Task {
            do {
                let (data, response) = try await BrewPingHTTP.session.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if statusCode != 200 {
                    let decoded = try? JSONDecoder().decode(LifecycleResponse.self, from: data)
                    sessionMessage = decoded?.error ?? L("Switch failed (HTTP %@)", String(statusCode))
                }
            } catch {
                sessionMessage = L("Switch failed: %@", error.localizedDescription)
            }
            await refreshStatus()
            await refreshAgents()
        }
    }

    // MARK: - Session Lifecycle

    private func stopSession() {
        guard var request = BrewPingHTTP.request(device: activeDevice, path: "/api/session/stop", method: "POST", timeout: 30) else {
            sessionMessage = L("No Mac connected. Add a device first.")
            return
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        submitter.cancelPolling()
        lifecycleBusy = true
        sessionState = .stopping
        sessionMessage = ""
        Task {
            do {
                let (data, response) = try await BrewPingHTTP.session.data(for: request)
                let decoded = try? JSONDecoder().decode(LifecycleResponse.self, from: data)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if BrewPingHTTP.isUnauthorized(response) {
                    sessionMessage = L("Not paired. Enter the pairing code in this device's settings.")
                } else if statusCode == 200, decoded?.success == true {
                    sessionMessage = L("Session stopped")
                    submitter.reset()
                } else {
                    sessionMessage = L("Stop failed: %@", decoded?.error ?? "HTTP \(statusCode)")
                }
            } catch {
                sessionMessage = L("Stop failed: %@", error.localizedDescription)
            }
            lifecycleBusy = false
            await refreshStatus()
            if sessionState == .stopping { sessionState = .offline }
        }
    }

    private func newSession() {
        // 旧实现在这里 `guard let url = ... else { return }`，无设备时按钮可点却毫无反馈。
        // 现在：按钮已被禁用（见 actionButton），这里再兜一层用户可见提示。
        guard var request = BrewPingHTTP.request(device: activeDevice, path: "/api/session/start", method: "POST", timeout: 120) else {
            sessionMessage = L("No Mac connected. Add a device first.")
            return
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        submitter.reset()
        lifecycleBusy = true
        sessionState = .starting
        sessionMessage = ""
        Task {
            do {
                let (data, response) = try await BrewPingHTTP.session.data(for: request)
                let decoded = try? JSONDecoder().decode(LifecycleResponse.self, from: data)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if BrewPingHTTP.isUnauthorized(response) {
                    sessionMessage = L("Not paired. Enter the pairing code in this device's settings.")
                } else if statusCode == 200, decoded?.success == true {
                    sessionMessage = ""
                } else {
                    sessionMessage = L("Start failed: %@", decoded?.error ?? "HTTP \(statusCode)")
                }
            } catch {
                sessionMessage = L("Start failed: %@", error.localizedDescription)
            }
            lifecycleBusy = false
            await refreshStatus()
            if sessionState == .starting && !online { sessionState = .offline }
        }
    }

    // MARK: - Send

    /// 手动发送（输入框 + Send 按钮）。
    /// 这里只做 UI 侧的前置校验，真正的提交与轮询统一交给 CommandSubmitter，
    /// 与 Watch 语音链路共用同一套实现，避免两条路径逻辑漂移。
    private func send() {
        guard let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
              sessionState == .running else { return }
        clearDraftWhenDelivered = true
        Task {
            await refreshStatus()
            submitter.submit(text: text, fromWatch: false)
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
