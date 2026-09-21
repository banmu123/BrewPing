import AppKit
import BrewPingCore
import Combine
import Foundation

// ─── 桌面端应用状态（App.tsx 的 Swift 等价物）──────────────────────────────────
//
// 逐条对齐 `Sources/BrewPingwinDesktop/src/App.tsx` 的状态机：
//   · 同一组派生值（effectiveAgentId / effectiveWorkdir / effectiveApprovalMode /
//     dirGroups / isBusy / messages …）；
//   · 同一组副作用（初始化、5s+2s 轮询、8 个后端事件订阅、busy 期 700ms 补轮询）；
//   · 同一组动作（send / switchAgent / selectModel / setApproval / workdir /
//     对话 CRUD / 配对 / 终端清理）。
//
// 与 React 的差异只在「表达方式」：`useState` → `@Published`，`useMemo/`派生变量
// → 计算属性，`useEffect` → Combine 订阅与 Timer。视图层的消费方式完全一致。

/// 侧栏目录过滤哨兵：显示全部目录组。
let kAllDirs = "__all__"
/// 目录过滤哨兵：未绑定目录的对话组（`conv.workdirOverride == nil`）。
let kUnbound = "__unbound__"
/// 草稿输入的存储键（尚无对话 ID 时）。
let kDraftKey = "__draft__"

/// 设置弹窗左侧分类。
public enum SettingsSection: String, CaseIterable, Identifiable {
    case general, machine, models, environment, pairing

    public var id: String { rawValue }
}

/// 草稿态工作目录的**三态**（对齐 App.tsx 的 `draftWorkdir`）：
/// - `.unset`：未选择 → 发送时快照当前 Agent 偏好目录；
/// - `.cleared`：明确解绑 → 发送时不绑定；
/// - `.path`：使用该目录。
public enum DraftWorkdir: Equatable {
    case unset
    case cleared
    case path(String)

    public var value: String? {
        switch self {
        case .unset: return nil
        case .cleared: return nil
        case .path(let p): return p
        }
    }

    public var isUnset: Bool { self == .unset }
}

// 流式增量与执行阶段统一由 `ConversationRun`（BrewPingCore）承载 ——
// 它绑定 commandId + conversationId，并提供纯函数式的阶段转移与展示派生。
// 原先这里只有一个存文本的 `StreamingSlot`，无法表达「排队中 / 等待首字 /
// 已在生成 / 正在停止」，UI 只能靠猜，这正是「不知道是否卡住」的来源。

/// 渲染用消息（`fromTranscript` 的输出）。
public struct ChatMessage: Identifiable, Equatable {
    public var id: String
    /// "user" | "assistant" | "error" | "system"
    public var role: String
    public var text: String
    public var createdAtMs: Double?
    /// 该消息所属命令（失败时据此提供「重试」，因此必须一路带到渲染层）。
    public var commandId: String?

    public init(
        id: String,
        role: String,
        text: String,
        createdAtMs: Double?,
        commandId: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAtMs = createdAtMs
        self.commandId = commandId
    }
}

/// 目录分组。
public struct DirGroup: Identifiable {
    public var key: String
    public var items: [ConversationSummary]
    public var id: String { key }
}

@MainActor
public final class DesktopAppState: ObservableObject {

    public static let shared = DesktopAppState()

    // ─── 状态（对应 App.tsx 的 useState 组）──────────────────────────────────

    @Published public var status: DesktopStatus?
    @Published public var settingsOpen = false
    @Published public var settingsSection: SettingsSection = .general
    @Published public var terminals: [TerminalAgentStateDTO] = []
    /// 草稿态（新对话）选定的 Agent —— 已有对话一律以 `conv.agentId` 为准。
    @Published public var draftAgentId = AgentManager.sessionAgentID
    @Published public var loading = true
    @Published public var pairing: PairingInfo?
    /// 设备配对成功次数（每次 `POST /api/pair` 成功 +1）。
    /// 向导终步监听它：配对成功 → 成功态 UI + 自动完成向导进入主界面。
    @Published public var pairingSuccessCount = 0
    /// 全局默认授权档位（`~/.brewping/approval.json`，轮询只更新它）。
    @Published public var globalApprovalMode = ApprovalMode.safe.rawValue
    /// 草稿里手动选过的档位（nil = 未选过，跟随全局默认）。
    @Published public var draftApprovalMode: String?
    @Published public var models: AgentModelsInfo?
    @Published public var copied = false
    @Published public var error: String?
    @Published public var dockOpen = false

    // 多对话
    @Published public var conversations: [ConversationSummary] = []
    @Published public var dirFilter = kAllDirs
    @Published public var collapsedGroups: [String: Bool] = [:]
    @Published public var activeConvId: String?
    @Published public var activeConv: ConversationDetail?
    @Published public var drafts: [String: String] = [:]
    /// **按对话**保存的执行状态（key = conversationId；草稿态用 `draftRunKey`）。
    ///
    /// 🚨 必须是「按对话」而不是单个字段。此前是单值字段，且在切换对话时被清空，
    /// 于是「命令执行中切到新对话、再切回来」会出现：`isBusy`（回退到
    /// `latestCommandId`）为真、`run` 却为 nil —— 界面只剩一个停止按钮、
    /// 没有任何状态说明，已生成的半截回复也消失。这就是切换对话的显示异常。
    @Published private var runs: [String: ConversationRun] = [:]
    /// 执行侧的失败说明（当前对话）。贴着消息展示（可重试 / 复制），与顶部错误条互补。
    @Published public private(set) var runError: String?

    /// 草稿态执行状态的键：新对话在物化前还没有 conversationId。
    static let draftRunKey = "__draft__"

    private var currentRunKey: String { activeConvId ?? Self.draftRunKey }

    /// 当前对话正在执行的命令状态。其它对话的状态仍保留在 `runs` 里，切回即恢复。
    public var run: ConversationRun? { runs[currentRunKey] }

    /// 当前 Agent 的工作目录偏好（`~/.brewping/workdirs.json`）。
    @Published public var agentWorkdir: String?
    @Published public var draftWorkdir: DraftWorkdir = .unset

    // 首次启动 Setup Wizard
    @Published public var setupWizardOpen = false
    @Published public var setupCompleted = SetupState.isCompleted

    // ─── 私有 ────────────────────────────────────────────────────────────────

    private var cancellables = Set<AnyCancellable>()
    private var pollTimer: Timer?
    private var terminalTimer: Timer?
    private var busyTimer: Timer?
    private var didStart = false

    /// 流式帧合并缓冲（**按对话**）：事件可能每秒十几次，先攒在这里，约 100ms 写一次 UI。
    /// 按对话分桶是必要的 —— 执行中切走的对话同样要继续接收增量，否则切回来时
    /// 文本会停在切走那一刻。
    private var pendingDeltas: [String: ConversationDelta] = [:]
    private var flushTimer: Timer?
    /// 活跃命令的 1s 心跳：评估「长时间无新增量」并把耗时刷新给 UI。
    private var runTickTimer: Timer?
    /// `fetchConversation` 的代次。切对话 / 新建 / 归档时 +1，使在途返回失效 ——
    /// 否则慢返回的旧对话会把用户刚切过去的新对话覆盖掉。
    private var fetchGeneration = 0

    private init() {}

    // ─── 生命周期 ─────────────────────────────────────────────────────────────

    /// 视图出现时调用一次：初始加载 + 起轮询 + 订阅事件。
    public func start() {
        guard !didStart else { return }
        didStart = true
        Task { await initialLoad() }
        startPolling()
        subscribeEvents()
        // DesktopCore 的 runtimeState 一有变化立刻反映（不必等 5s 轮询）。
        DesktopCore.shared.$runtimeState
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.refreshStatus() }
            }
            .store(in: &cancellables)
        // 手机扫码 / 手动输码配对成功（HTTPAPI pair 处理器发出）
        NotificationCenter.default.publisher(for: PairingStore.devicePairedNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.pairingSuccessCount += 1 }
            .store(in: &cancellables)
    }

    private func initialLoad() async {
        async let a: Void = refreshStatus()
        async let b: Void = refreshTerminal()
        async let c: Void = refreshSecurity()
        async let d: Void = refreshConversations()
        _ = await (a, b, c, d)

        // 启动时从后端取回 active 对话（重启恢复）
        if let id = status?.activeConversationId, !id.isEmpty {
            updateActiveConvId(id)
            await fetchConversation(id)
        }
        loading = false

        // 首次启动（既没完成也没跳过 setup）→ 进入 Setup Wizard
        if SetupState.shouldShowOnLaunch {
            setupWizardOpen = true
        }
    }

    // ─── Setup Wizard ─────────────────────────────────────────────────────────

    /// 走完向导（Ready 页的 Start BrewPing）。
    public func completeSetup() {
        SetupState.markCompleted()
        setupCompleted = true
        setupWizardOpen = false
    }

    /// 跳过向导：不再自动弹出；主界面保留轻量「未完成」横幅。
    public func skipSetup() {
        SetupState.markSkipped()
        setupWizardOpen = false
    }

    /// 「Run Setup Again」/ 主界面横幅入口。
    public func runSetupAgain() {
        setupWizardOpen = true
    }

    // ─── 轮询（对齐 App.tsx：status/security/conversations 5s，终端 2s）──────

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.refreshStatus()
                await self.refreshSecurity()
                await self.refreshConversations()
            }
        }
        terminalTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshTerminal() }
        }
    }

    // ─── 事件订阅（对齐 App.tsx 的 8 个 listen）───────────────────────────────

    private func subscribeEvents() {
        NotificationCenter.default
            .publisher(for: .desktopEvent)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self,
                      let raw = note.userInfo?["event"] as? String,
                      let event = DesktopEvent(rawValue: raw) else { return }
                self.handleEvent(event, payload: note.userInfo?["payload"])
            }
            .store(in: &cancellables)
    }

    private func handleEvent(_ event: DesktopEvent, payload: Any?) {
        switch event {
        case .terminalUpdated:
            Task { await refreshTerminal() }

        case .activeAgentChanged:
            if let id = payload as? String { draftAgentId = id }
            Task { await refreshTerminal() }

        case .runtimeStateChanged:
            Task { await refreshStatus() }

        case .pairingRevealed:
            // 菜单栏「显示配对码」→ 打开设置弹窗并定位到配对分类
            settingsOpen = true
            settingsSection = .pairing
            Task { await refreshSecurity() }

        case .refreshAgents:
            Task {
                await refreshStatus()
                await refreshTerminal()
            }

        case .conversationsChanged:
            Task { await refreshConversations() }
            if let id = activeConvId { Task { await fetchConversation(id) } }

        case .conversationDelta:
            guard let delta = payload as? ConversationDelta, !delta.conversationId.isEmpty else { return }
            acceptDelta(delta)

        case .activeConversationChanged:
            let id = payload as? String
            updateActiveConvId(id)
            if let id {
                Task { await fetchConversation(id) }
            } else {
                activeConv = nil
            }

        case .envSetupLog, .envSetupDone:
            // 由环境卡片自行订阅（与 Windows 的 EnvironmentCard 自包含一致）
            break
        }
    }

    // ─── 数据拉取 ─────────────────────────────────────────────────────────────

    public func refreshStatus() async {
        let snapshot = DesktopCommands.getStatus()
        status = snapshot
        if !snapshot.activeAgentId.isEmpty {
            draftAgentId = snapshot.activeAgentId
        }
    }

    public func refreshTerminal() async {
        terminals = DesktopCommands.getTerminalState()
    }

    public func refreshSecurity() async {
        let info = DesktopCommands.getPairingInfo()
        pairing = info
        globalApprovalMode = DesktopCommands.getApprovalMode()
    }

    public func refreshConversations() async {
        conversations = DesktopCommands.listConversations(includeArchived: true)
    }

    /// 当前对话的完整转录（按 id 拉取，事件与轮询共用）。
    ///
    /// 🚨 并发正确性：发起前记下代次，返回时若代次已变（用户切了对话 / 新建 / 归档）
    /// 或 id 已不是当前 activeConvId —— 一律丢弃、绝不写回。否则慢返回的旧对话会把
    /// 用户刚切过去的那条覆盖掉（表现为「切过去又跳回来」）。
    public func fetchConversation(_ id: String) async {
        let generation = fetchGeneration
        do {
            let conv = try DesktopCommands.getConversation(id)
            guard generation == fetchGeneration, id == activeConvId else { return }
            activeConv = conv
            reconcileRun(with: conv)
        } catch {
            guard generation == fetchGeneration, id == activeConvId else { return }
            // 对话可能已被删除 → 回草稿态
            activeConv = nil
        }
    }

    /// 用刚落库的转录校正执行状态。
    ///
    /// · 出现该 commandId 的 **assistant / error** 条目（最终产物）→ 命令已终结，
    ///   撤掉执行状态（文案由转录里的消息承载）。
    /// · 出现该 commandId 的 **user** 条目 → 乐观占位已被真实消息取代，撤掉它。
    ///
    /// 🚨 只认 assistant / error：用户消息带的是**同一个** commandId，若不加角色判断，
    /// 每次轮询取到用户消息都会清掉流式气泡，下一帧增量又把它加回来 ——
    /// 表现为「回复闪一下 → 正在思考」反复跳变。
    private func reconcileRun(with conv: ConversationDetail) {
        guard var current = runs[conv.id] else {
            // 兜底：转录显示这条对话还有命令在飞，但我们没有它的执行状态
            //（App 重启后恢复、或命令由手机端 / Watch 端发起且尚未收到任何增量）。
            // 这里补一条「等待首字」，让 `isBusy` 与状态指示器**始终一致** ——
            // 否则界面会只剩一个停止按钮、没有任何状态说明，用户以为卡住了。
            if let commandId = conv.latestCommandId, !commandId.isEmpty {
                runs[conv.id] = Self.freshRun(conversationId: conv.id, commandId: commandId)
                syncRunTick()
            }
            return
        }
        let mine = conv.messages.filter { $0.commandId == current.commandId }

        if current.pendingUserText != nil, mine.contains(where: { $0.role == "user" }) {
            current.pendingUserText = nil
        }

        if let final = mine.first(where: { $0.role == "assistant" || $0.role == "error" }) {
            current.finishFromTranscript(role: final.role, now: Date())
            // 终态已在转录里可见 → 该对话的执行状态功成身退（只清这一条对话的）。
            runs.removeValue(forKey: conv.id)
            if conv.id == activeConvId { runError = nil }
            syncRunTick()
            return
        }
        runs[conv.id] = current
    }

    // ─── 派生值 ───────────────────────────────────────────────────────────────

    /// 当前生效的 Agent：已有对话以 `conv.agentId` 为准，草稿态用草稿选定的 Agent。
    public var effectiveAgentId: String { activeConv?.agentId ?? draftAgentId }

    public var convAgentId: String { effectiveAgentId }

    public var activeTerminal: TerminalAgentStateDTO? {
        terminals.first { $0.agentId == convAgentId }
    }

    public var agentNameMap: [String: String] {
        Dictionary(uniqueKeysWithValues: (status?.agents ?? []).map { ($0.id, $0.name) })
    }

    public var convAgentName: String {
        agentNameMap[convAgentId] ?? activeConv?.agentId ?? convAgentId
    }

    public var runtimeState: String { status?.runtimeState ?? "idle" }

    public var installedAgents: [DesktopStatusAgent] {
        (status?.agents ?? []).filter { $0.installed }
    }

    public var isDraftConv: Bool { activeConvId == nil }

    /// 目录上下文：对话绑定优先，草稿三态次之，Agent 偏好兜底。
    public var effectiveWorkdir: String? {
        if activeConvId != nil {
            return activeConv?.workdirOverride ?? agentWorkdir
        }
        switch draftWorkdir {
        case .unset: return agentWorkdir
        case .cleared: return nil
        case .path(let p): return p
        }
    }

    /// 最近使用的目录（含已归档对话的绑定；conversations 已按最近活动排序）。
    public var recentDirs: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for c in conversations {
            guard let d = c.workdirOverride, !seen.contains(d) else { continue }
            seen.insert(d)
            out.append(d)
        }
        return out
    }

    /// 所有 provider 的模型摊平。key 带 provider 前缀（同名模型可来自多个厂商）。
    public var modelOptions: [(key: String, id: String, name: String, provider: String, providerId: String)] {
        (models?.providers ?? []).flatMap { provider in
            provider.models.map { model in
                (
                    key: "\(provider.id)::\(model.id)",
                    id: model.id,
                    name: model.name,
                    provider: provider.name,
                    providerId: provider.id
                )
            }
        }
    }

    /// 生效模型 = 对话级覆盖 > 该 Agent 的默认模型偏好 > 配置里的 active。
    public var currentModelKey: String {
        let convOverride = activeConv?.modelOverride
        let currentId = convOverride ?? models?.preferredModelId ?? models?.activeModelId ?? ""
        let currentProvider = convOverride != nil
            ? activeConv?.modelProviderOverride
            : models?.preferredProviderId
        return modelOptions.first { option in
            option.id == currentId && (currentProvider == nil || option.providerId == currentProvider)
        }?.key ?? ""
    }

    /// 生效授权档位 = 对话级 > 草稿手选 > 全局默认。
    public var effectiveApprovalMode: String {
        activeConv?.approvalMode ?? draftApprovalMode ?? globalApprovalMode
    }

    public var activeConversations: [ConversationSummary] {
        conversations.filter { !$0.archived }
    }

    public var archivedConversations: [ConversationSummary] {
        conversations.filter { $0.archived }
    }

    /// 目录组：key = 绑定目录 ?? UNBOUND；组序按组内最新活动降序，未绑定组垫底。
    public var dirGroups: [DirGroup] {
        var map: [String: [ConversationSummary]] = [:]
        for c in activeConversations {
            let key = c.workdirOverride ?? kUnbound
            map[key, default: []].append(c)
        }
        return map.map { DirGroup(key: $0.key, items: $0.value) }
            .sorted { lhs, rhs in
                if lhs.key == kUnbound { return false }
                if rhs.key == kUnbound { return true }
                return (lhs.items.first?.updatedAtMs ?? 0) > (rhs.items.first?.updatedAtMs ?? 0)
            }
    }

    public var visibleGroups: [DirGroup] {
        dirFilter == kAllDirs ? dirGroups : dirGroups.filter { $0.key == dirFilter }
    }

    /// 是否有命令在飞：以**当前对话的执行状态机**为准。
    /// 无可用的 run 时退回 `latestCommandId`（例如刚启动、run 尚未重建）。
    ///
    /// TerminalState 按 Agent 而不是对话保存：把它纳入这里会导致用户创建新对话、
    /// 或浏览同一 Agent 的另一条对话时，错误地显示为「正在思考」。
    public var isBusy: Bool {
        if let run { return run.phase.isActive }
        return activeConv?.latestCommandId != nil
    }

    /// 渲染用的消息列表 = 权威转录 + 乐观用户占位 + 正在生成的那条助手气泡。
    public var messages: [ChatMessage] {
        var out = fromTranscript(activeConv?.messages ?? [], convId: activeConvId)
        guard let run else { return out }
        // 提交中的新对话尚未物化，conversationId 为空 —— 此时占位仍要显示。
        if !run.conversationId.isEmpty, run.conversationId != activeConvId { return out }

        if let pending = run.pendingUserText, !pending.isEmpty {
            out.append(ChatMessage(
                id: "pending_user_\(run.commandId)",
                role: "user",
                text: pending,
                createdAtMs: nil,
                commandId: run.commandId
            ))
        }
        if !run.text.isEmpty {
            out.append(ChatMessage(
                id: "streaming_\(run.commandId)",
                role: "assistant",
                text: run.text,
                createdAtMs: nil,
                commandId: run.commandId
            ))
        }
        // 失败反馈贴着消息展示（带重试 / 复制），不依赖顶部那条会消失的错误条。
        if run.phase == .failed, let message = runError, !message.isEmpty {
            out.append(ChatMessage(
                id: "run_error_\(run.commandId)",
                role: "error",
                text: message,
                createdAtMs: nil,
                commandId: run.commandId
            ))
        }
        return out
    }

    /// 输入草稿按对话隔离（切换不丢失）。
    public var draftText: String {
        drafts[activeConvId ?? kDraftKey] ?? ""
    }

    public func setDraftText(_ text: String) {
        drafts[activeConvId ?? kDraftKey] = text
    }

    // ─── 动作 ─────────────────────────────────────────────────────────────────

    /// 切换当前对话。
    ///
    /// 🚨 这里**不再丢弃执行状态** —— 这是「命令执行中切到新对话、再切回来显示异常」的
    /// 修复点。`runs` 按对话保存，切走时原对话的阶段与已生成的半截文本都留着，
    /// 切回来直接恢复（与 UI 读的 `run` 计算属性配合）。
    /// 只作废在途刷新与轮询：它们的闭包/定时器绑定的是旧 conversationId。
    private func updateActiveConvId(_ id: String?) {
        guard id != activeConvId else { return }
        activeConvId = id
        // 作废在途刷新：慢返回的旧对话不得覆盖用户刚切过去的新对话。
        fetchGeneration += 1
        cancelRunTracking()
        syncRunTick()
    }

    /// 统一的错误包裹（对齐 `runQuietly`）：任何动作抛错都进顶部错误条。
    private func runQuietly(_ action: () async throws -> Void) async {
        error = nil
        do {
            try await action()
        } catch {
            self.error = String(describing: error)
        }
    }

    public func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }

        // ① 点击发送的**当帧**就给出反馈：乐观用户消息 + 「正在提交」状态。
        //    此前要等后端返回才有任何视觉变化，用户会怀疑是不是没点上。
        let optimisticId = "local-\(UUID().uuidString)"
        var optimistic = ConversationRun(
            submitting: optimisticId,
            conversationId: activeConvId ?? "",
            text: trimmed,
            now: Date()
        )
        // 乐观用户消息必须能被「重试」找回（此时还没有真实 commandId）。
        optimistic.pendingUserText = trimmed
        runs[Self.draftRunKey] = optimistic
        runError = nil
        syncRunTick()

        let targetConv = activeConvId
        do {
            // 新对话创建即记录「当时的目录」与「当时的授权档位」。
            let bindWorkdir: String? = targetConv != nil
                ? nil
                : (draftWorkdir.isUnset ? agentWorkdir : draftWorkdir.value)
            let bindApproval: String? = targetConv != nil ? nil : draftApprovalMode

            let convId = try await DesktopCommands.sendCommand(
                text: trimmed,
                conversationId: targetConv,
                workdir: bindWorkdir,
                approvalMode: bindApproval
            )
            guard !convId.isEmpty else {
                failRun("command could not be submitted")
                return
            }
            // ② 后端已确认：把执行状态从草稿键迁移到真实对话键（否则切走再切回
            //    会找不到状态），阶段推进到 queued。
            updateActiveConvId(convId)
            migrateRun(to: convId)

            draftWorkdir = .unset
            draftApprovalMode = nil
            await refreshConversations()
            await fetchConversation(convId)
            await refreshTerminal()
        } catch {
            // ③ 失败：乐观占位就地转为失败态（用户原消息保留，可重试），
            //    同时保留顶部错误条以兼容既有习惯。
            failRun(String(describing: error))
        }
    }

    /// 命令落定到真实 conversationId 后，把执行状态从草稿键迁移过去。
    ///
    /// 草稿态（新对话）在物化前没有 conversationId，占位只能先挂在 `draftRunKey` 下；
    /// 不迁移的话，切换对话再切回来就找不到这条命令的状态了。
    private func migrateRun(to convId: String) {
        guard var current = runs.removeValue(forKey: Self.draftRunKey) ?? runs[convId] else { return }
        current.conversationId = convId
        current.markQueued(now: Date())
        runs[convId] = current
        syncRunTick()
    }

    /// 提交阶段失败：保留用户消息，标记失败，给出就近错误说明。
    private func failRun(_ message: String) {
        let key = currentRunKey
        guard var current = runs[key] else {
            error = message
            return
        }
        current.finish(success: false, now: Date())
        runs[key] = current
        runError = message
        error = message
        syncRunTick()
    }

    /// 切换 Agent。Agent 是**对话级**绑定：在已有对话里切到别的 Agent 会进入草稿态
    /// （下一条消息以新 Agent 开新对话），旧对话原样保留、可随时切回。
    public func switchAgent(_ agentId: String) async {
        guard agentId != convAgentId else { return }
        await runQuietly {
            DesktopCommands.switchActiveAgent(agentId)
            draftAgentId = agentId
            await refreshTerminal()
            if let conv = activeConv, conv.agentId != agentId {
                updateActiveConvId(nil)
                activeConv = nil
                draftApprovalMode = nil
            }
        }
    }

    /// 选择模型。key 形如 `providerId::modelId`；`""` = 跟随 Agent 配置（清除偏好）。
    public func selectModel(_ key: String) async {
        await runQuietly {
            let modelId: String?
            let providerId: String?
            if key.isEmpty {
                modelId = nil
                providerId = nil
            } else {
                guard let range = key.range(of: "::") else { return }
                providerId = String(key[key.startIndex..<range.lowerBound])
                modelId = String(key[range.upperBound...])
            }
            if let id = activeConvId {
                try DesktopCommands.setConversationModel(id, modelId: modelId, providerId: providerId)
                if var conv = activeConv, conv.id == id {
                    conv.modelOverride = modelId
                    conv.modelProviderOverride = providerId
                    activeConv = conv
                }
            } else {
                DesktopCommands.setDefaultModel(effectiveAgentId, modelId: modelId, providerId: providerId)
                await refreshModels(effectiveAgentId)
            }
        }
    }

    /// 切换授权档位（对话级：已有对话写对话，草稿态只改本地）。
    public func setApprovalMode(_ mode: String) async {
        await runQuietly {
            if let id = activeConvId {
                try DesktopCommands.setConversationApprovalMode(id, mode: mode)
                if var conv = activeConv, conv.id == id {
                    conv.approvalMode = mode
                    activeConv = conv
                }
            } else {
                draftApprovalMode = mode
            }
        }
    }

    public func clearTerminal() async {
        await runQuietly { DesktopCommands.clearTerminal(effectiveAgentId) }
    }

    /// 手动停止生成（composer 的停止按钮）。
    ///
    /// 立即进入 `stopping`：按钮就地禁用并显示「正在停止…」，避免用户重复点击。
    /// 真正的终态由 `CommandRunner` 回写转录后，经 `fetchConversation` → `reconcileRun`
    /// 收敛；若迟迟不确认，指示器会在 `RunTiming.stopConfirmTimeoutSeconds` 后
    /// 给出「停止请求尚未确认」并重新开放停止按钮。
    public func stopGeneration() async {
        let key = currentRunKey
        guard var current = runs[key], current.phase.isActive else { return }
        current.requestStop(now: Date())
        runs[key] = current
        syncRunTick()
        DesktopCommands.stopActiveCommand()
        if let id = activeConvId {
            await fetchConversation(id)
        }
        await refreshTerminal()
    }

    /// 重试一条失败的命令。
    ///
    /// 已有转录条目的（后端已落库）按 `commandId` 找回原用户消息；
    /// 提交阶段就失败的（尚无转录条目）用保留的乐观文本。
    public func retry(commandId: String?) async {
        var text: String?
        if let commandId, let conv = activeConv {
            text = conv.messages.first { $0.commandId == commandId && $0.role == "user" }?.text
        }
        if text == nil { text = run?.pendingUserText }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        clearRun()
        error = nil
        await send(text)
    }

    /// 复制文本到剪贴板（失败消息的「复制错误」）。
    public func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // ─── 执行状态的接收与合并 ─────────────────────────────────────────────────

    /// 接收一帧流式增量。
    ///
    /// **按对话分桶写入**，不再只看当前对话：
    /// · 已跟踪的对话（含用户刚切走的）继续更新 —— 否则切回来时文本停在切走那一刻；
    /// · 从未跟踪过、且不是当前对话的帧直接忽略 —— 不能为历史对话凭空造执行状态；
    /// · 当前对话的陌生帧（手机端 / Watch 端发起）建立跟踪，桌面端同样能看到进度。
    private func acceptDelta(_ delta: ConversationDelta) {
        let convId = delta.conversationId

        if var current = runs[convId] {
            if current.commandId != delta.commandId {
                // 同一对话里的另一条命令：仅当上一条还停在提交/排队阶段才接管 ——
                // 那时我们的 commandId 还是本地乐观 id，这一帧是它的真实身份。
                if current.phase == .submitting || current.phase == .queued {
                    current.commandId = delta.commandId
                } else {
                    current = Self.freshRun(conversationId: convId, commandId: delta.commandId)
                }
            }
            runs[convId] = current
        } else {
            guard convId == activeConvId else { return }
            runs[convId] = Self.freshRun(conversationId: convId, commandId: delta.commandId)
        }

        pendingDeltas[convId] = delta
        scheduleFlush()
    }

    /// 建立一条「刚发现、尚无增量」的命令跟踪（等待首字阶段）。
    private static func freshRun(conversationId: String, commandId: String) -> ConversationRun {
        let now = Date()
        return ConversationRun(
            conversationId: conversationId,
            commandId: commandId,
            phase: .thinking,
            startedAt: now,
            lastActivityAt: now
        )
    }

    /// 把高频事件与 SwiftUI 的渲染频率解耦：约 100ms 才写一次 UI。
    private func scheduleFlush() {
        guard flushTimer == nil else { return }
        flushTimer = Timer.scheduledTimer(
            withTimeInterval: RunTiming.uiFlushIntervalSeconds, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.flushDelta() }
        }
    }

    private func flushDelta() {
        flushTimer?.invalidate()
        flushTimer = nil
        guard !pendingDeltas.isEmpty else { return }
        let pending = pendingDeltas
        pendingDeltas.removeAll()
        for (convId, delta) in pending {
            guard var current = runs[convId], current.commandId == delta.commandId else { continue }
            // 去重 / 过时帧过滤都在状态机里（累积全文的前缀关系），此处只负责节流。
            current.applyDelta(delta.text, done: delta.done, now: Date())
            runs[convId] = current
        }
        syncRunTick()
    }

    /// 命令活跃期间保持 1s 心跳：评估「长时间无新增量」并让耗时显示持续走动。
    ///
    /// 遍历**所有**对话的执行状态而非仅当前对话：切走的对话同样需要 stalled 判定，
    /// 否则切回来时看到的是过期的阶段。
    private func syncRunTick() {
        let hasActive = runs.values.contains { $0.phase.isActive }
        guard hasActive else {
            runTickTimer?.invalidate()
            runTickTimer = nil
            return
        }
        guard runTickTimer == nil else { return }
        runTickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = Date()
                for (key, var value) in self.runs where value.phase.isActive {
                    value.refreshStall(now: now)
                    self.runs[key] = value
                }
            }
        }
    }

    /// 撤掉**当前对话**的执行状态（含它的合并缓冲条目）。转录已承载最终消息时使用。
    private func clearRun() {
        flushTimer?.invalidate()
        flushTimer = nil
        let key = currentRunKey
        pendingDeltas.removeValue(forKey: key)
        runs.removeValue(forKey: key)
        runError = nil
        syncRunTick()
    }

    /// 切换对话时的收尾：只作废旧对话的轮询与就地错误提示。
    ///
    /// 🚨 **不动 `runs`** —— 各对话的执行状态各自保留，切回即恢复。
    /// 这里若顺手清掉状态，就是「执行中切走再切回、只剩停止按钮没有说明」的成因。
    private func cancelRunTracking() {
        busyTimer?.invalidate()
        busyTimer = nil
        runError = nil
    }

    // 配对
    public func revealPairing() async {
        await runQuietly { pairing = DesktopCommands.revealPairingCode() }
    }

    public func regeneratePairing() async {
        await runQuietly { pairing = DesktopCommands.regeneratePairingCode() }
    }

    public func copyPairingCode() async {
        guard let code = pairing?.code else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        copied = true
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        copied = false
    }

    /// 「新对话」：进入草稿态（不调任何 API，无文件产生），发送首条消息时才物化。
    public func newConversation() {
        updateActiveConvId(nil)
        activeConv = nil
        draftWorkdir = .unset
        draftApprovalMode = nil
        settingsOpen = false
    }

    public func openConversation(_ id: String) async {
        await runQuietly {
            DesktopCommands.activateConversation(id)
            updateActiveConvId(id)
            await fetchConversation(id)
            settingsOpen = false
        }
    }

    public func archiveConversation(_ id: String) async {
        await runQuietly {
            try DesktopCommands.setConversationArchived(id, archived: true)
            // 归档的对话不再展示 → 连带清掉它的执行状态，避免 `runs` 长期堆积。
            runs.removeValue(forKey: id)
            if id == activeConvId {
                updateActiveConvId(nil)
                activeConv = nil
            }
            await refreshConversations()
        }
    }

    public func restoreConversation(_ id: String) async {
        await runQuietly {
            try DesktopCommands.setConversationArchived(id, archived: false)
            await refreshConversations()
        }
    }

    public func deleteConversation(_ id: String) async {
        await runQuietly {
            try DesktopCommands.deleteConversation(id)
            // 对话已删除 → 它的执行状态也没有意义了。
            runs.removeValue(forKey: id)
            if id == activeConvId {
                updateActiveConvId(nil)
                activeConv = nil
            }
            await refreshConversations()
        }
    }

    public func togglePin(_ id: String, pinned: Bool) async {
        await runQuietly {
            try DesktopCommands.togglePinConversation(id, pinned: pinned)
            await refreshConversations()
        }
    }

    /// 目录条选择：已有对话 → 写对话绑定；草稿态 → 只改本地三态。
    public func setWorkdir(_ path: String?) async {
        await runQuietly {
            if let id = activeConvId {
                try DesktopCommands.setConversationWorkdir(id, workdir: path)
                if var conv = activeConv, conv.id == id {
                    conv.workdirOverride = path
                    activeConv = conv
                }
                await refreshConversations()
            } else {
                draftWorkdir = path.map { DraftWorkdir.path($0) } ?? .cleared
            }
        }
    }

    // ─── 模型 / 目录的跟随刷新 ─────────────────────────────────────────────────

    private var modelsTask: Task<Void, Never>?
    public func refreshModels(_ agentId: String) async {
        do {
            let info = try DesktopCommands.getAgentModels(agentId)
            models = info
        } catch {
            models = nil  // 未知 agent / 无配置 → 隐藏模型入口
        }
    }

    public func refreshWorkdir(_ agentId: String) async {
        agentWorkdir = DesktopCommands.getAgentWorkdir(agentId)
    }

    /// 派生值变化时的跟随副作用（对齐 App.tsx 的两个 useEffect 依赖）。
    /// 视图在 `body` 变更后调用它（`onChange` 语义），保持副作用显式且可预测。
    public func syncFollowedState() {
        // 模型目录跟随当前生效 Agent
        if followedAgentIdForModels != effectiveAgentId {
            followedAgentIdForModels = effectiveAgentId
            models = nil
            let id = effectiveAgentId
            modelsTask?.cancel()
            modelsTask = Task { await refreshModels(id) }
        }
        // 工作目录跟随当前生效 Agent
        if followedAgentIdForWorkdir != convAgentId {
            followedAgentIdForWorkdir = convAgentId
            agentWorkdir = nil
            let id = convAgentId
            Task { await refreshWorkdir(id) }
        }
        // 命令在飞期间 700ms 轮询当前对话（事件为主、轮询兜底防丢事件）
        syncBusyPolling()
    }

    private var followedAgentIdForModels: String?
    private var followedAgentIdForWorkdir: String?

    private func syncBusyPolling() {
        guard let id = activeConvId, isBusy else {
            busyTimer?.invalidate()
            busyTimer = nil
            return
        }
        guard busyTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.fetchConversation(id) }
        }
        busyTimer = timer
        // 立刻跑一次，不等第一个 tick
        Task { await fetchConversation(id) }
    }

    /// 转录条目 → 渲染消息（对齐 `fromTranscript`）。
    /// `commandId` 一并带出：失败消息的就近「重试」要靠它找回原用户消息。
    public func fromTranscript(_ entries: [TranscriptEntryDTO], convId: String?) -> [ChatMessage] {
        entries.enumerated().map { index, entry in
            ChatMessage(
                id: "\(convId ?? "conv")_\(index)",
                role: entry.role,
                text: entry.text,
                createdAtMs: entry.createdAtMs,
                commandId: entry.commandId
            )
        }
    }

    /// 路径末段（`/Users/x/workFlow` → `workFlow`），目录分组标题用。
    public static func pathLabel(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasSuffix("/") || trimmed.hasSuffix("\\") {
            trimmed.removeLast()
        }
        guard let idx = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return trimmed }
        return String(trimmed[trimmed.index(after: idx)...])
    }
}
