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
    case general, machine, environment, pairing

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

/// 流式增量槽位（后端逐块推送时先放在这里，落库后丢弃）。
public struct StreamingSlot: Equatable {
    public var convId: String
    public var commandId: String
    public var text: String
}

/// 渲染用消息（`fromTranscript` 的输出）。
public struct ChatMessage: Identifiable, Equatable {
    public var id: String
    /// "user" | "assistant" | "error" | "system"
    public var role: String
    public var text: String
    public var createdAtMs: Double?
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
    /// 流式增量：命令执行期间后端边读边推，渲染成一条「正在生成」的助手气泡。
    @Published public var streaming: StreamingSlot?

    /// 当前 Agent 的工作目录偏好（`~/.brewping/workdirs.json`）。
    @Published public var agentWorkdir: String?
    @Published public var draftWorkdir: DraftWorkdir = .unset

    // ─── 私有 ────────────────────────────────────────────────────────────────

    private var cancellables = Set<AnyCancellable>()
    private var pollTimer: Timer?
    private var terminalTimer: Timer?
    private var busyTimer: Timer?
    private var didStart = false

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
            if var prev = streaming, prev.commandId == delta.commandId {
                prev.text = delta.text
                streaming = prev
            } else {
                streaming = StreamingSlot(
                    convId: delta.conversationId, commandId: delta.commandId, text: delta.text
                )
            }

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
    public func fetchConversation(_ id: String) async {
        do {
            let conv = try DesktopCommands.getConversation(id)
            activeConv = conv
            // 真实条目已落库 → 丢掉同命令的流式占位
            if let slot = streaming, conv.messages.contains(where: { $0.commandId == slot.commandId }) {
                streaming = nil
            }
        } catch {
            // 对话可能已被删除 → 回草稿态
            activeConv = nil
        }
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

    /// busy：调度指针在飞，或终端在跑。
    public var isBusy: Bool {
        activeConv?.latestCommandId != nil || activeTerminal?.status == "running"
    }

    /// 渲染用的消息列表 = 权威转录 +（可选）当前会话正在生成的那条流式气泡。
    public var messages: [ChatMessage] {
        var out = fromTranscript(activeConv?.messages ?? [], convId: activeConvId)
        if let slot = streaming, slot.convId == activeConvId, !slot.text.isEmpty {
            out.append(ChatMessage(
                id: "streaming_\(slot.commandId)", role: "assistant", text: slot.text, createdAtMs: nil
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

    private func updateActiveConvId(_ id: String?) {
        activeConvId = id
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
        await runQuietly {
            // 新对话创建即记录「当时的目录」与「当时的授权档位」。
            let bindWorkdir: String? = activeConvId != nil
                ? nil
                : (draftWorkdir.isUnset ? agentWorkdir : draftWorkdir.value)
            let bindApproval: String? = activeConvId != nil ? nil : draftApprovalMode

            let convId = try await DesktopCommands.sendCommand(
                text: text,
                conversationId: activeConvId,
                workdir: bindWorkdir,
                approvalMode: bindApproval
            )
            guard !convId.isEmpty else { return }
            updateActiveConvId(convId)
            streaming = nil
            draftWorkdir = .unset
            draftApprovalMode = nil
            await refreshConversations()
            await fetchConversation(convId)
            await refreshTerminal()
        }
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
    /// 命令被杀后 `CommandRunner` 会走 failed 终态并回写转录，
    /// 这里只做即时反馈（立刻重取转录 + 复位终端指示灯）。
    public func stopGeneration() async {
        DesktopCommands.stopActiveCommand()
        if let id = activeConvId {
            await fetchConversation(id)
        }
        await refreshTerminal()
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
    public func fromTranscript(_ entries: [TranscriptEntryDTO], convId: String?) -> [ChatMessage] {
        entries.enumerated().map { index, entry in
            ChatMessage(
                id: "\(convId ?? "conv")_\(index)",
                role: entry.role,
                text: entry.text,
                createdAtMs: entry.createdAtMs
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
