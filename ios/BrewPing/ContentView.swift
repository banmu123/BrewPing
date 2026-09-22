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
    @Environment(\.openURL) private var openURL
    @StateObject private var deviceStore = DeviceStore.shared
    @StateObject private var watchBridge = WatchConnectivityManager.shared
    @StateObject private var submitter = CommandSubmitter.shared
    @StateObject private var bonjour = BonjourDiscovery()
    /// 权限协调器：集中管理三项权限，保证系统弹窗一次只出现一个（见 PermissionCenter）
    @StateObject private var permissions = PermissionCenter()
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

    // 命令的提交与轮询统一由 CommandSubmitter 负责（见 CommandReceiver.swift），
    // 视图只是它的观察者。这样即使界面没被创建，Watch 来的命令也能照常执行。
    private var phase: CommandPhase { submitter.phase }
    private var lastDuration: Double? { submitter.lastDuration }
    private var lastFailureReason: String? { submitter.lastFailureReason }
    private var lastModelId: String? { submitter.lastModelId }

    // 添加设备 Sheet
    @State private var showAddDevice = false
    /// 已经跑过至少一轮自动发现（用于「扫不到」时再显示排查引导，避免首帧闪现）
    @State private var didAttemptDiscovery = false
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

    /// 自动发现是否**已跑完一轮**（不管有没有结果）。
    ///
    /// 用途：区分「还在找」与「找过了、没有」。只有后者才允许显示
    /// 「下载桌面端」引导卡 / 「扫不到」排查卡 —— 否则开机那一段搜索窗口里，
    /// 明明电脑就在网络上，界面却先喊「还没有桌面端？去下载」，看着像闪了一下。
    private var discoverySettled: Bool {
        didAttemptDiscovery && !bonjour.isSearching && !bonjour.isResolving
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                deviceTabBar

                // 已配对设备：主页 = 桌面端同步过来的对话（按绑定的工作目录分组）；
                // 未添加 / 未配对时才是引导表单。
                // Agent / 模型 / 授权的切换在对话详情头部的「对话设置」面板里
                // （ConversationSettingsView，按对话独立生效）。
                if let device = activeDevice, DeviceAuth.isPaired(device) {
                    if statusError != nil {
                        statusBannerRow
                    }
                    ConversationListView(
                        device: device,
                        online: online,
                        agentNames: agentNameMap
                    )
                } else if deviceStore.devices.isEmpty {
                    // 无设备：附近一台没扫到时显示引导卡；扫到了就只显示「附近」列表
                    // （对着一台就在跟前的电脑说"添加第一台电脑/去下载"是噪音）。
                    ScrollView {
                        VStack(spacing: 16) {
                            // 本地网络没就绪时，权限说明卡就是当前最该看的东西：自动发现被挡住的
                            // 原因只有它说得清（本地网络一旦被拒，系统不再弹窗）。
                            // 🚨 5.1.1(iv)：卡片可见性只看本地网络 —— 相机 / 语音识别在真正
                            // 使用对应功能时才按需请求（扫码 / 手表语音），不能拿「还没授权」
                            // 把用户摁在权限页上。状态徽章仍如实显示这两项的系统状态。
                            // 🚨 必须等状态**读过一次**（`hasRefreshed`）才允许渲染：首帧
                            // 「未确定」会被当成「没授权」，卡片闪一下再消失。
                            if permissions.hasRefreshed, !permissions.localNetwork.isGranted {
                                permissionCard
                            }
                            // 🚨 「下载桌面端」引导卡只在**确实搜过一轮且一无所获**后才出现。
                            // 早先只判 `discoveredHosts.isEmpty`，于是自动发现还在跑的窗口里
                            //（此刻用户的电脑就在网络上）这张卡会先渲染出来，等「附近」列表
                            // 出来才消失 —— 表现为每次进页面都「闪一下下载桌面端」。
                            if discoverySettled, bonjour.discoveredHosts.isEmpty, permissions.localNetwork.isGranted {
                                emptyStateCard
                            }
                            nearbyCard
                        }
                        .padding(16)
                    }
                    .background(Color.bpBackground)
                    .tint(Color.bpPrimary)
                    .onAppear {
                        permissions.attach(bonjour)
                        // 🚨 5.1.1(iv)：本地网络的系统授权框**必须**由权限说明卡的
                        // 「Continue」触发（requestLocalNetwork → startSearching），
                        // 不能一进页面就自动弹。所以首装（从未授权过，
                        // `hasEverBeenGranted` 为假）这里**不**探测 —— 用户首屏看到的
                        // 是说明卡 + Continue，点下才进入授权 + 发现流程。
                        // 已授权过的用户照旧静默自动扫描（不会再看到系统弹框）。
                        // 注意这与旧的「hasEverBeenGranted 门禁」不同：当年门禁挡死的是
                        // 首装的探测路径（永远拿不到 `.ready`，TestFlight 自动发现死锁）；
                        // 现在首装的探测路径仍然存在，只是改由用户点 Continue 主动触发。
                        if BonjourDiscovery.hasEverBeenGranted {
                            bonjour.startSearching()
                        }
                        didAttemptDiscovery = true
                    }
                    // 🚨 自动探测得出的权限结论必须回灌给 PermissionCenter：
                    // 它只在 `attach()` 时同步过一次，之后只有用户点「Continue」
                    // 触发的探测会通过轮询更新 —— 于是自动扫描判定的「已授权 / 被拒」
                    // 若不回灌，权限说明卡会一直停在过去的状态。
                    .onReceive(bonjour.$localNetwork) { _ in permissions.refresh() }
                    .onDisappear { bonjour.stopSearching() }
                } else {
                    Form {
                        if let device = activeDevice {
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
                        showHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityLabel("Help and About")
                }
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

                // 回到前台刷新权限状态。自动（重新）探测只允许两类场景，**都不会再弹系统框**：
                // - 已确认被拒 → 用户在系统设置里打开后回前台要立刻接上
                //   （被拒状态下再探测不会弹框，只重跑发现）；
                // - 曾经授权过 → 无声续扫（系统不会再弹框）。
                // 从未授权（首装、还没点 Continue）绝不自动探测 —— 那会绕过说明卡
                // 直接弹系统框（5.1.1(iv)）。唯独「正在等授权」时不重启：
                // startSearching() 会先 stopSearching()，把挂着系统授权框的浏览器
                // cancel 掉（`.ready` 就永远等不到了）。
                guard newPhase == .active, deviceStore.devices.isEmpty else { return }
                permissions.refresh()
                if bonjour.localNetwork == .denied {
                    bonjour.startSearching()
                } else if BonjourDiscovery.hasEverBeenGranted, !bonjour.isWaitingForPermission {
                    bonjour.startSearching()
                }
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
                    agents: agents,
                    fallbackAgentId: activeAgentID
                )
            case .draft:
                ConversationDetailView(
                    conversationId: nil,
                    device: device,
                    online: online,
                    agentNames: agentNameMap,
                    agents: agents,
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

    /// 控制面板已移除：Agent / 模型 / 授权的切换移到了对话详情的
    /// 「对话设置」面板（ConversationSettingsView，按对话独立生效）。

    /// 没有设备时的引导卡片 —— 与 Android `EmptyStateCard` 同构：
    /// （整卡只在附近一台都没扫到时出现；扫到了就只显示「附近」列表。）
    /// 一张居中卡片（图标 / 标题 / 一句说明 / 一个主按钮 / 一行脚注）。
    ///
    /// 之前这里是「三段式 Form + 4 步编号引导 + 快捷入口」：同一件事被说了三四遍
    /// （大段说明、编号步骤、发现列表的 footer、「没有 Mac？」脚注），
    /// 而且「Add Manually」与设备栏的「Add Device」重复。现在收敛成一条主线，
    /// 需要电脑端的自解释性仍然保留（审核员首屏就能看懂要配一台电脑）。
    private var emptyStateCard: some View {
        VStack(spacing: 8) {
            Text("☕")
                .font(.system(size: 32))

            Text("Add your first computer")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.bpForeground)

            Text("Run BrewPing on your computer, then tap “Add Device” to send commands from your phone.")
                .font(.system(size: 12))
                .foregroundStyle(Color.bpMutedForeground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                // 桌面端安装包统一从 GitHub Release 分发（Mac 分 Universal / Apple Silicon /
                // Intel 三个 DMG，另有 Windows 安装包），官网仅作介绍页。
                if let url = URL(string: "https://github.com/banmu123/BrewPing/releases") {
                    openURL(url)
                }
            } label: {
                Label("Download Desktop App", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Color.bpPrimary)
            .padding(.top, 8)

            // 审核 / 无 Mac 用户的一等入口：Demo 是明确的产品能力，不是隐藏后门
            Button {
                deviceStore.addDemoDevice()
            } label: {
                Label("Try the Demo (no Mac needed)", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.top, 4)

            Text("No desktop yet? Get BrewPing for Mac, Windows or Linux.")
                .font(.system(size: 10))
                .foregroundStyle(Color.bpMutedForeground.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.bpCard)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.bpBorder, lineWidth: 1)
        }
    }

    /// 附近电脑（局域网自动发现）。只在**真的扫到**时才出现 ——
    /// 去掉了 header/footer 与「未找到」占位，扫不到就没有这张卡。
    @ViewBuilder
    private var nearbyCard: some View {
        if !bonjour.discoveredHosts.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Nearby")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.bpMutedForeground)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                ForEach(bonjour.discoveredHosts) { host in
                    Divider()
                        .background(Color.bpBorder)
                    Button {
                        handleDiscoveredHost(host)
                    } label: {
                        HStack(spacing: 10) {
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
                            Spacer(minLength: 0)
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.bpPrimary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.bpCard)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.bpBorder, lineWidth: 1)
            }
        } else if bonjour.isSearching || bonjour.isResolving {
            // 正在找：只给一行中性占位。这段窗口里**不能**出现「没有桌面端」的断言
            //（见 `discoverySettled`）—— 之前正是这里让「下载桌面端」卡闪了一下。
            searchingCard
        } else if discoverySettled, bonjour.localNetwork.isGranted {
            // 搜过一轮却一无所获：多播被拦（AP 隔离/访客网络/跨网段）或本地网络
            // 权限被拒时都会走到这里 —— 此时必须给可执行的下一步，否则用户无从下手。
            discoveryHintCard
        }
    }

    /// 搜索期间的占位卡：把「正在找」与「找过了没有」在视觉上分开。
    private var searchingCard: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(L("Searching for nearby computers…"))
                .font(.system(size: 12))
                .foregroundStyle(Color.bpMutedForeground)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.bpCard)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.bpBorder, lineWidth: 1)
        }
    }

    /// 权限说明卡（5.1.1(iv) 合规版）：只解释用途，唯一主按钮是「Continue」。
    ///
    /// Apple 审核要求：系统授权框之前的自定义说明页**不得**出现「Grant / Allow」类
    /// 按钮（用户会误以为点按钮就是在做授权决策），要用「Continue / Next」等继续
    /// 语义。因此这里：
    /// - 三行只做「权限 → 实际用途」的说明 + 实时状态徽章，**没有任何请求按钮**；
    /// - 「Continue」只推进流程：进入本地网络授权 + 发现（见 `PermissionCenter`）；
    /// - 相机 / 语音识别由系统在真正使用对应功能时按需请求（扫码页 / 手表语音），
    ///   本卡不请求它们；
    /// - 仅当本地网络**已被拒**时才出现「Open Settings」（iOS 只弹一次授权框，
    ///   被拒后唯一出路是系统设置；这不是首次授权入口）。
    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("Permissions"), systemImage: "lock.shield")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.bpForeground)
            Text(L("BrewPing uses these permissions to connect to and control your computer."))
                .font(.system(size: 12))
                .foregroundStyle(Color.bpMutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("Tap Continue to start looking for your computer. Camera and Speech Recognition are requested only when you use those features."))
                .font(.system(size: 11))
                .foregroundStyle(Color.bpMutedForeground)
                .fixedSize(horizontal: false, vertical: true)

            permissionRow(
                icon: "wifi",
                title: L("Local Network"),
                detail: L("Used to discover your computer over Bonjour."),
                status: localNetworkStatus
            )
            permissionRow(
                icon: "camera",
                title: L("Camera"),
                detail: L("Only for scanning the pairing QR code."),
                status: permissions.camera
            )
            permissionRow(
                icon: "waveform",
                title: L("Speech Recognition"),
                detail: L("Transcribes the voice commands you send from your Watch."),
                status: permissions.speech
            )

            if localNetworkStatus == .denied {
                // 已被拒：系统不会再弹框，Continue 已无意义，唯一出路是系统设置。
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Local Network permission is denied. Enable it in Settings → Privacy & Security → Local Network."))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.bpMutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        PermissionCenter.openSystemSettings()
                    } label: {
                        Label(L("Open Settings"), systemImage: "gear")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.bpPrimary)
                }
                .padding(.top, 2)
            } else {
                // 唯一主按钮：「Continue」。只推进流程（进入本地网络授权 + 发现），
                // 不冒充授权决策本身。
                Button {
                    permissions.requestLocalNetwork()
                } label: {
                    HStack(spacing: 6) {
                        if isProbingLocalNetwork {
                            ProgressView().controlSize(.small)
                        }
                        Text(L("Continue"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color.bpPrimary)
                .disabled(isProbingLocalNetwork)
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.bpCard)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.bpBorder, lineWidth: 1)
        }
    }

    /// 本地网络正在探测 / 等授权（系统框可能正挂着）：期间禁用 Continue ——
    /// startSearching() 会先掐掉挂着授权框的浏览器，`.ready` 就永远等不到了。
    /// 探测窗口若已结束仍无结论，按钮恢复可点（用户可重试）。
    private var isProbingLocalNetwork: Bool {
        bonjour.localNetwork == .requesting && bonjour.isSearching
    }

    /// 本地网络状态映射成 `PermissionCenter.Status`：它来自 Bonjour 探测而不是系统 API，
    /// `.requesting`（尚未落定）在 UI 上按「未授权」呈现，同时仍保留「授权」按钮可重试。
    private var localNetworkStatus: PermissionCenter.Status {
        switch bonjour.localNetwork {
        case .granted: return .granted
        case .denied: return .denied
        case .unknown, .requesting: return .notDetermined
        }
    }

    /// 权限说明行：图标 + 名称 + 状态徽章 + 一句用途说明。**没有任何按钮** ——
    /// 徽章如实反映系统真实状态（不显示假的「Granted」），请求动作全部发生在
    /// 对应功能的使用现场（扫码页 / 手表语音 / 权限卡的 Continue）。
    private func permissionRow(icon: String, title: String, detail: String,
                               status: PermissionCenter.Status) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color.bpPrimary)
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.bpForeground)
                    permissionStatusBadge(status)
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.bpMutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if status == .granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.bpPrimary)
            }
        }
    }

    @ViewBuilder
    private func permissionStatusBadge(_ status: PermissionCenter.Status) -> some View {
        // 注意：不能在 @ViewBuilder 里写赋值语句（每个 case 体都会被当成 View 表达式），
        // 所以这里按 case 直接返回，具体样式交给 badge(_:fill:fg:)。
        switch status {
        case .granted:
            permissionBadge(L("Allowed"), fill: Color.bpPrimary.opacity(0.15), fg: Color.bpPrimary)
        case .denied:
            permissionBadge(L("Denied"), fill: Color.orange.opacity(0.18), fg: Color.orange)
        case .notDetermined:
            permissionBadge(L("Not granted"), fill: Color.bpBorder.opacity(0.5), fg: Color.bpMutedForeground)
        }
    }

    private func permissionBadge(_ text: String, fill: Color, fg: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(fill))
            .foregroundStyle(fg)
    }

    /// 自动发现扫不到时的排查引导。
    private var discoveryHintCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("Nearby Mac not showing up?"), systemImage: "wifi.exclamationmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.bpForeground)
            Text(L("Make sure your iPhone and your computer are on the same Wi-Fi (same subnet), and that Local Network access is allowed: Settings → Privacy & Security → Local Network → BrewPing. Some routers block device discovery (AP isolation or guest networks) — in that case add the IP manually."))
                .font(.system(size: 12))
                .foregroundStyle(Color.bpMutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showAddDevice = true
            } label: {
                Label(L("Enter IP Manually"), systemImage: "square.and.pencil")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Color.bpPrimary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.bpCard)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.bpBorder, lineWidth: 1)
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
        // 弹出 pair sheet。🚨 必须走 beginEditing（预填名称 / IP / 端口 / 系统），
        // startAddDevice() 会把表单清空 —— 用户点 + 就是为了省掉手输。
        beginEditing(device)
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
                    TextField("Name (e.g. My Mac)", text: $editName)
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

        // 1) 桌面端 QR 的正式格式：brewping://pair?host=...&port=...&deviceId=...&osType=...&code=...&name=...
        //
        // 🚨 解析统一走 `PairingLink`（与外链入口共用同一份），**必须把 osType 落到表单**：
        // 旧实现这里只取了 host/port/code/name，把 osType 丢掉 → 表单里 `editOS` 停在默认
        // `.mac`，于是「扫 Windows 的码，设备仍被存成 Mac」（用户实际报的就是这个）。
        if let link = PairingLink.parse(trimmed) {
            editHost = link.host
            editPort = link.port
            if !link.code.isEmpty { editPairingCode = link.code }
            if let name = link.name { editName = name }
            // 认不出来时**保持表单现值**（不要盲目改成 Mac —— 用户可能已经手动选对了）
            if let osType = link.osType { editOS = osType }
            // 回显识别到的系统：用户能在提交前一眼看出类型对不对
            pairingMessage = L("Scanned (%@). Tap Pair to finish.", editOS.label)
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
            // 🚨 按 host+port 去重复用：同一台电脑可能已经有一条（例如刚从
            // 附近列表点过 +，或之前添加过但没配对）。直接再建一条会出现
            // "一条未配对 + 一条已配对"两个条目指向同一台机器。
            // 复用时保留原 id —— Keychain 里的 token 是按设备存的，换 id 会丢。
            if var existing = deviceStore.devices.first(where: {
                $0.host.caseInsensitiveCompare(trimmedHost) == .orderedSame
                    && $0.port == editPort
            }) {
                if !trimmedName.isEmpty { existing.name = trimmedName }
                existing.osType = editOS
                deviceStore.updateDevice(existing)
                device = existing
            } else {
                device = ManagedDevice.new(
                    name: trimmedName.isEmpty ? editOS.label : trimmedName,
                    host: trimmedHost,
                    port: editPort,
                    osType: editOS
                )
                deviceStore.addDevice(device)
            }
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
                // 🚨 Keychain 写入失败必须让配对失败：否则用户以为配好了，
                // 实际 token 丢失，后续全部 401 且无从排查。
                guard DeviceAuth.store(token: token, for: device) else {
                    BrewPingLog.net.error("Keychain store failed for host \(device.host, privacy: .private)")
                    return (false, L("Couldn't save the pairing token to the Keychain."))
                }
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
            editOS = host.osType   // platform 取自 TXT 记录，否则回落默认 Mac（"幽灵 Mac"）
            discoveryMessage = L("Found: %@ (%@:%@)", host.name, host.host, String(host.port))
        } else if bonjour.localNetwork.isDenied {
            discoveryMessage = L("Local Network permission is denied. Enable it in Settings → Privacy & Security → Local Network.")
        } else {
            discoveryMessage = L("No BrewPing agent found. Make sure %@ is running and on the same Wi-Fi.",
                                 BrewPingConfig.macAppName)
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
        // 🚨 这里**不再**自动请求语音权限：原来的「启动即请求」会让用户一打开 App
        // 就吃到系统弹窗，与「进设备页的本地网络弹窗」「点扫码的相机弹窗」连成三连弹，
        // 正是用户反馈的问题。现在改为：权限卡里由用户点击授权，
        // 或手表语音送达时按需请求（见 WatchConnectivityManager 的识别入口）。
        watchBridge.appIsActive = (scenePhase == .active)

        guard !isInBackground else { return }

        await refreshStatus()
        await refreshAgents()

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { break }
            await refreshStatus()
            // agent 级数据（含工作目录偏好）也要周期刷新：Mac 端在 composer
            // 草稿态换目录写的是 agent 偏好，iOS 的目录条回落值依赖它。
            await refreshAgentsKeepingOldData()
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

            // 🚨 切设备窗口：await 期间用户可能已切到别的 Mac，旧回包不能写入 UI。
            guard deviceStore.activeDeviceID == device.id else { return }
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
            // 空列表也推：拉取失败时 Watch 显示"无"，而不是旧的硬编码假列表
            watchBridge.knownAgents = agents.map { ["id": $0.id, "name": $0.name] }
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

    /// 5s 循环专用的非破坏性刷新：`refreshAgents` 失败路径会把 `agents` 清空，
    /// 周期轮询里一次网络抖动就会把界面上的 Agent 列表 / 目录回落清掉 ——
    /// 这里在失败（且非 401）时回滚旧值。401 不回滚：那是真实的鉴权状态变化。
    private func refreshAgentsKeepingOldData() async {
        let previous = agents
        await refreshAgents()
        if agents.isEmpty, !previous.isEmpty, !agentsUnauthorized {
            agents = previous
        }
    }

    private func refreshAgents() async {
        let requestingDeviceID = deviceStore.activeDeviceID
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
            // 🚨 切设备窗口守卫（与 refreshStatus 同语义）
            guard deviceStore.activeDeviceID == requestingDeviceID else { return }
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
