import Foundation

// ─── 桌面端命令面（Tauri `#[tauri::command]` 的 macOS 等价物）────────────────────
//
// Windows 桌面端的 UI 通过 `invoke("get_status")` 之类调用 Rust 侧命令（见
// `src-tauri/src/lib.rs` 的 command 注册表与 `src/api/tauri.ts` 的封装）。
// macOS 端 UI 与核心同进程，但**仍然保留同一层命令面**，理由：
//   1. UI 只依赖这一层公开 API，核心内部类型（ConversationStore / ApprovalGate /
//      FolderBrowser …）不必为了 UI 而整体 public，边界清晰；
//   2. 两端命令名 / 参数 / 返回结构逐一对齐 → 「接口一致、界面一致」可核对；
//   3. 执行类命令（send_command / 安装）统一在此处切到后台队列，**不阻塞主线程**
//      （Tauri 侧是 async runtime，语义等价）。
//
// 命名与 `src/api/tauri.ts` 一一对应：函数名 = Tauri 命令名的驼峰形式。

// MARK: - DTO（与 src/api/types.ts 的 interface 逐字段对齐）

/// `PairingInfo`
public struct PairingInfo: Codable {
    public var code: String?
    public var expiresAt: String?
    public var url: String?
    public var deviceId: String
    public var deviceName: String
    public var host: String
    public var port: UInt16
}

/// `ProviderModel`
public struct ProviderModel: Codable {
    public var id: String
    public var name: String
    public var available: Bool
    public var isActive: Bool
    public var isDefault: Bool
}

/// `ProviderInfo`
public struct ProviderInfo: Codable {
    public var id: String
    public var name: String
    public var models: [ProviderModel]
    public var baseURL: String?
}

/// `AgentModelsInfo`
public struct AgentModelsInfo: Codable {
    public var agentId: String
    public var providers: [ProviderInfo]
    public var activeModelId: String?
    public var preferredModelId: String?
    public var preferredProviderId: String?
}

/// `TranscriptEntry`（去掉了 Windows 侧的 `id` 字段——macOS 的转录条目没有稳定 id，
/// UI 用「对话 id + 下标」合成渲染标识，视觉与行为一致）。
public struct TranscriptEntryDTO: Codable {
    public var role: String
    public var text: String
    public var source: String?
    public var commandId: String?
    public var createdAtMs: Double
}

/// `Conversation`（= `ConversationSummary` + `messages`）
public struct ConversationDetail: Codable {
    public var id: String
    public var agentId: String
    public var title: String?
    public var titleSource: String?
    public var createdAtMs: Double
    public var updatedAtMs: Double
    public var archived: Bool
    public var isPinned: Bool
    public var modelOverride: String?
    public var modelProviderOverride: String?
    public var workdirOverride: String?
    public var approvalMode: String?
    public var latestCommandId: String?
    public var messageCount: Int
    public var messages: [TranscriptEntryDTO]
}

/// `OutputLine`
public struct TerminalLineDTO: Codable, Identifiable {
    public var id: Int
    public var text: String
    /// "normal" | "system" | "error"
    public var type: String
}

/// `AgentTerminalState`
public struct TerminalAgentStateDTO: Codable {
    public var agentId: String
    public var agentName: String
    public var outputLines: [TerminalLineDTO]
    /// "idle" | "running" | "error" | "stopped"
    public var status: String
}

/// `ConversationDelta` 事件载荷
public struct ConversationDelta: Codable {
    public var conversationId: String
    public var commandId: String
    public var text: String
    public var done: Bool
}

/// `EnvSetupLog` 事件载荷
public struct EnvSetupLog: Codable {
    public var task: String
    public var line: String
}

/// `EnvSetupDone` 事件载荷
public struct EnvSetupDone: Codable {
    public var task: String
    public var ok: Bool
    public var error: String?
}

// MARK: - 命令面

public enum DesktopCommands {

    // MARK: 状态

    /// `get_status`
    @MainActor
    public static func getStatus() -> DesktopStatus {
        let core = DesktopCore.shared
        return DesktopStatus.current(
            port: core.httpPort ?? 8787,
            lanIp: core.lanIP,
            mdnsRunning: BonjourAdvertiser.isRunning,
            runtimeState: core.runtimeState.rawValue
        )
    }

    /// `get_agents`
    public static func getAgents() -> [DesktopStatusAgent] {
        let defaultID = AgentManager.shared.defaultAgentID
        return AgentDiscovery.shared.discover().map { agent in
            DesktopStatusAgent(
                id: agent.id,
                name: agent.name,
                installed: agent.installed,
                active: agent.id == defaultID,
                executable: agent.path,
                version: agent.version
            )
        }
    }

    /// `set_default_agent`
    @discardableResult
    public static func setDefaultAgent(_ agentId: String) -> String {
        switch AgentManager.shared.setDefaultAgent(agentId) {
        case .success:
            NotificationCenter.default.post(
                name: .activeAgentDidChange, object: nil, userInfo: ["agentId": agentId]
            )
            DesktopEventBus.shared.post(.activeAgentChanged, payload: agentId)
            DesktopEventBus.shared.post(.refreshAgents)
            return agentId
        case .failure(let error):
            return error.localizedDescription
        }
    }

    /// `get_lan_ip`
    public static func getLanIp() -> String {
        LANAddress.primaryLAN()?.ip ?? ""
    }

    /// `get_port`
    public static func getPort() -> UInt16 {
        UInt16(SessionManager.shared.load()?.httpPort ?? 8787)
    }

    // MARK: 配对

    /// `get_pairing_info`（不生成新码）
    @MainActor
    public static func getPairingInfo() -> PairingInfo {
        let store = PairingStore.shared
        let expiry = store.pairingCodeExpiry
        let valid = expiry.map { $0 > Date() } ?? false
        let code = valid ? core_displayedPairingCode() : nil
        return pairingInfo(code: code, expiry: valid ? expiry : nil)
    }

    /// `reveal_pairing_code`（生成或复用未过期的码）
    @MainActor
    @discardableResult
    public static func revealPairingCode() -> PairingInfo {
        let code = PairingStore.shared.issuePairingCode()
        DesktopCore.shared.pairingCode = code
        DesktopCore.shared.pairingCodeExpiresAt = PairingStore.shared.pairingCodeExpiry
        return pairingInfo(code: code, expiry: PairingStore.shared.pairingCodeExpiry)
    }

    /// `regenerate_pairing_code`（强制作废旧码）
    @MainActor
    @discardableResult
    public static func regeneratePairingCode() -> PairingInfo {
        let code = PairingStore.shared.regeneratePairingCode()
        DesktopCore.shared.pairingCode = code
        DesktopCore.shared.pairingCodeExpiresAt = PairingStore.shared.pairingCodeExpiry
        return pairingInfo(code: code, expiry: PairingStore.shared.pairingCodeExpiry)
    }

    /// 拿当前已展示的码（`PairingStore` 只对外暴露「生成」，展示走 `DesktopCore` 的缓存字段）。
    @MainActor
    private static func core_displayedPairingCode() -> String? {
        DesktopCore.shared.pairingCode
    }

    @MainActor
    private static func pairingInfo(code: String?, expiry: Date?) -> PairingInfo {
        let core = DesktopCore.shared
        let url = code.flatMap { core.pairingURL(code: $0)?.absoluteString }
        let formatter = ISO8601DateFormatter()
        return PairingInfo(
            code: code,
            expiresAt: expiry.map { formatter.string(from: $0) },
            url: url,
            deviceId: core.deviceId,
            deviceName: core.deviceName,
            host: core.lanIP ?? "",
            port: core.httpPort ?? 8787
        )
    }

    // MARK: 授权

    /// `get_approval_mode`
    public static func getApprovalMode() -> String {
        ApprovalGate.shared.currentMode.rawValue
    }

    /// `set_approval_mode`
    @discardableResult
    public static func setApprovalMode(_ mode: String) -> String {
        guard let parsed = ApprovalMode(rawValue: mode) else {
            return ApprovalGate.shared.currentMode.rawValue
        }
        ApprovalGate.shared.setMode(parsed)
        return parsed.rawValue
    }

    // MARK: 终端

    /// `get_terminal_state` —— 所有 Agent 的终端快照。
    public static func getTerminalState() -> [TerminalAgentStateDTO] {
        let manager = AgentManager.shared
        let names = Dictionary(
            uniqueKeysWithValues: AgentDiscovery.shared.discover().map { ($0.id, $0.name) }
        )
        // 顺序对齐 Windows：按 AgentDiscovery.catalog 的稳定顺序输出。
        return AgentDiscovery.catalog.compactMap { definition in
            guard let state = manager.terminalState(for: definition.id) else { return nil }
            return TerminalAgentStateDTO(
                agentId: state.agentId,
                agentName: names[definition.id] ?? definition.name,
                outputLines: state.outputLines.enumerated().map { index, line in
                    TerminalLineDTO(id: index, text: line.text, type: line.type.rawValue)
                },
                status: state.status.rawValue
            )
        }
    }

    /// `get_active_agent_id`
    public static func getActiveAgentId() -> String {
        AgentManager.shared.activeAgentID
    }

    /// `switch_active_agent`
    public static func switchActiveAgent(_ agentId: String) {
        AgentManager.shared.switchActiveAgent(agentId)
    }

    /// `send_command`
    ///
    /// `conversationId` 为 nil（草稿态）时后端创建新对话并激活，返回对话 ID。
    /// 走 `ConversationCommandService`（与 HTTP / Watch 端**同一条**执行路径）。
    /// 执行会 spawn 子进程 → 必须在后台队列，绝不阻塞主线程。
    public static func sendCommand(
        text: String,
        conversationId: String?,
        workdir: String?,
        approvalMode: String?
    ) async throws -> String {
        try await offMain {
            let outcome = try ConversationCommandService.submit(
                text: text,
                conversationID: conversationId,
                router: CommandRouter.shared,
                policy: .alwaysCreate,
                createAgentID: nil,
                draftWorkdir: workdir,
                draftApprovalMode: approvalMode,
                source: .desktop,
                markExplicitActive: true
            )
            switch outcome {
            case .ok(let success):
                // Windows `send_command` 返回的是**对话 ID**（草稿态下由后端创建）。
                return success.conversationID ?? conversationId ?? ""

            case .pending(let approval):
                // 挂起等确认：仍要返回对话 ID，桌面端才能显示/定位这条对话。
                return approval.conversationID ?? ""
            }
        }
    }

    /// 裁决一条挂起命令（桌面端目前把确认弹窗交给 iPhone / Apple Watch，
    /// 该命令保留给未来的桌面内确认入口，语义与 HTTP 端完全一致）。
    @discardableResult
    public static func decideApproval(id: String, action: String) async throws -> String? {
        try await offMain {
            let outcome = try ConversationCommandService.decide(
                id: id, action: action, router: CommandRouter.shared, source: .desktop
            )
            return outcome?.status
        }
    }

    /// `stop_generation` —— 手动停止当前对话正在生成的命令。
    /// 命令被终止后走 `failed` 终态：转录落一条说明、调度指针清空。
    @discardableResult
    public static func stopActiveCommand() -> Bool {
        guard let conversationId = ConversationStore.shared.activeConversation(),
              let conversation = ConversationStore.shared.get(conversationId),
              let commandId = conversation.latestCommandId, !commandId.isEmpty else {
            return false
        }
        let stopped = CommandRouter.shared.stop(commandId: commandId)
        // 终端指示灯即时复位（真正的终态由 CommandRunner 的 failed 分支回写）。
        if let state = AgentManager.shared.terminalState(for: conversation.agentId) {
            DispatchQueue.main.async { state.setStatus(.idle) }
        }
        return stopped
    }

    /// `clear_terminal`
    public static func clearTerminal(_ agentId: String) {
        AgentManager.shared.terminalState(for: agentId)?.clearOutput()
        DesktopEventBus.shared.post(.terminalUpdated)
    }

    // MARK: 模型

    /// `get_agent_models` —— 未知 agent 抛 `CommandError.unknownAgent`。
    public static func getAgentModels(_ agentId: String) throws -> AgentModelsInfo {
        guard AgentDiscovery.catalog.contains(where: { $0.id == agentId }) else {
            throw CommandError.unknownAgent
        }
        let config = AgentConfigDiscovery.discover(agentId: agentId)
        let defaultModelId = AgentManager.shared.defaultModel(for: agentId)
        let providers = config.providers.map { provider in
            ProviderInfo(
                id: provider.id,
                name: provider.name,
                models: provider.models.map { model in
                    ProviderModel(
                        id: model.id,
                        name: model.name,
                        available: model.available,
                        isActive: model.isActive,
                        isDefault: model.id == defaultModelId
                    )
                },
                baseURL: provider.baseURL
            )
        }
        return AgentModelsInfo(
            agentId: agentId,
            providers: providers,
            activeModelId: config.activeModelId,
            preferredModelId: defaultModelId,
            preferredProviderId: AgentManager.shared.defaultModelProvider(for: agentId)
        )
    }

    /// `set_default_model`（`modelId` 传 nil 清除偏好；`providerId` 与 model 成对）
    public static func setDefaultModel(_ agentId: String, modelId: String?, providerId: String?) {
        AgentManager.shared.setDefaultModel(modelId, providerId: providerId, for: agentId)
    }

    // MARK: 工作目录 / 目录浏览

    /// `get_agent_workdir`
    public static func getAgentWorkdir(_ agentId: String) -> String? {
        WorkdirPrefs.shared.get(agentID: agentId)
    }

    /// `set_agent_workdir`（`path` 传 nil 清除；返回校验后的规范路径）
    public static func setAgentWorkdir(_ agentId: String, path: String?) -> String? {
        WorkdirPrefs.shared.set(agentID: agentId, path: path)
    }

    /// `browse_roots`
    public static func browseRoots() -> FolderBrowser.RootsInfo {
        FolderBrowser.roots()
    }

    /// `browse_folder`（`path` 传 nil = 主目录）
    public static func browseFolder(_ path: String?) throws -> FolderBrowser.BrowseResult {
        try FolderBrowser.browse(path: path)
    }

    // MARK: 对话

    /// `list_conversations`
    public static func listConversations(includeArchived: Bool) -> [ConversationSummary] {
        ConversationStore.shared.list(includeArchived: includeArchived)
    }

    /// `get_conversation`
    public static func getConversation(_ id: String) throws -> ConversationDetail {
        guard let conv = ConversationStore.shared.get(id) else { throw CommandError.conversationNotFound }
        return detail(from: conv)
    }

    /// `activate_conversation`
    public static func activateConversation(_ id: String) {
        ConversationStore.shared.setActiveConversation(id)
        DesktopEventBus.shared.post(.activeConversationChanged, payload: id)
    }

    /// `set_conversation_archived`
    public static func setConversationArchived(_ id: String, archived: Bool) throws {
        _ = try ConversationStore.shared.patch(id: id, title: nil, archived: archived, pinned: nil)
        if archived, ConversationStore.shared.activeConversation() == id {
            ConversationStore.shared.setActiveConversation(nil)
        }
        DesktopEventBus.shared.post(.conversationsChanged)
    }

    /// `delete_conversation`
    public static func deleteConversation(_ id: String) throws {
        try ConversationStore.shared.delete(id: id)
        if ConversationStore.shared.activeConversation() == id {
            ConversationStore.shared.setActiveConversation(nil)
        }
        DesktopEventBus.shared.post(.conversationsChanged)
    }

    /// `toggle_pin_conversation`
    public static func togglePinConversation(_ id: String, pinned: Bool) throws {
        _ = try ConversationStore.shared.patch(id: id, title: nil, archived: nil, pinned: pinned)
        DesktopEventBus.shared.post(.conversationsChanged)
    }

    /// `set_conversation_workdir`（空串 = 解绑）
    public static func setConversationWorkdir(_ id: String, workdir: String?) throws {
        _ = try ConversationStore.shared.setWorkdir(id: id, workdir: workdir)
        DesktopEventBus.shared.post(.conversationsChanged)
    }

    /// `set_conversation_approval_mode`（nil = 清除，回落全局默认）
    public static func setConversationApprovalMode(_ id: String, mode: String?) throws {
        _ = try ConversationStore.shared.setApprovalMode(id: id, mode: mode)
        DesktopEventBus.shared.post(.conversationsChanged)
    }

    /// `set_conversation_model`（`modelId` nil = 清除覆盖）
    public static func setConversationModel(_ id: String, modelId: String?, providerId: String?) throws {
        _ = try ConversationStore.shared.setModel(id: id, modelID: modelId, providerID: providerId)
        DesktopEventBus.shared.post(.conversationsChanged)
    }

    // MARK: 环境与 CLI 安装

    /// `check_environment` —— 探测要 spawn 若干 `--version`（约 1-2s），放后台。
    public static func checkEnvironment() async -> EnvironmentSetup.EnvironmentStatus {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: EnvironmentSetup.check())
            }
        }
    }

    /// `get_node_versions` —— 联网拉 nodejs.org dist index，失败回落离线别名。
    public static func getNodeVersions() async -> [EnvironmentSetup.NodeVersionOption] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: EnvironmentSetup.fetchNodeVersions())
            }
        }
    }

    /// `install_nvm`
    public static func installNvm() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                EnvironmentSetup.installNvm()
                continuation.resume()
            }
        }
    }

    /// `install_node`
    public static func installNode(_ version: String) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                EnvironmentSetup.installNode(version: version)
                continuation.resume()
            }
        }
    }

    /// `install_agent_cli`
    @discardableResult
    public static func installAgentCli(agentId: String, methodId: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: EnvironmentSetup.installAgentCli(agentID: agentId, methodID: methodId))
            }
        }
    }

    /// `update_agent_cli`
    @discardableResult
    public static func updateAgentCli(agentId: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: EnvironmentSetup.updateAgentCli(agentID: agentId))
            }
        }
    }

    // MARK: - Internals

    public enum CommandError: LocalizedError {
        case unknownAgent
        case conversationNotFound

        public var errorDescription: String? {
            switch self {
            case .unknownAgent: return "unknown agent"
            case .conversationNotFound: return "conversation not found"
            }
        }
    }

    private static func detail(from conv: ConversationRecord) -> ConversationDetail {
        ConversationDetail(
            id: conv.id,
            agentId: conv.agentId,
            title: conv.title,
            titleSource: conv.titleSource,
            createdAtMs: conv.createdAtMs,
            updatedAtMs: conv.updatedAtMs,
            archived: conv.archived,
            isPinned: conv.isPinned,
            modelOverride: conv.modelOverride,
            modelProviderOverride: conv.modelProviderOverride,
            workdirOverride: conv.workdirOverride,
            approvalMode: conv.approvalMode,
            latestCommandId: conv.latestCommandId,
            messageCount: conv.messages.count,
            messages: conv.messages.map {
                TranscriptEntryDTO(
                    role: $0.role, text: $0.text, source: $0.source,
                    commandId: $0.commandId, createdAtMs: $0.createdAtMs
                )
            }
        )
    }

    /// 把同步的阻塞工作挪到后台队列，返回时回到调用方的 actor。
    private static func offMain<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
