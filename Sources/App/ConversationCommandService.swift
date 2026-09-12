import Foundation

/// 对话命令服务：**唯一**的命令提交与授权裁决实现。
///
/// 为什么必须共用一条：
/// Windows 端历史上把"执行"复制成了两份（`http_server.rs` 的手机端 submit 与
/// `lib.rs` 的桌面端 send），任何与执行有关的改动（参数 / env / cwd / 授权）都得
/// 同批改两处，否则出现「手机端生效、桌面端不生效」的分裂。
///
/// macOS 端从设计上只保留一条：`HTTPAPI`（手机端）与桌面 UI **都**走这里。
/// 唯一允许分叉的是 `Source`（回显标签）与 `DraftPolicy`（草稿物化语义）。
enum ConversationCommandService {

    // MARK: - 语义开关

    /// 显式对话 ID 缺省时怎么解析目标对话。
    enum DraftPolicy {
        /// 优先复用当前激活对话，没有才新建 —— HTTP 老客户端的「直接发」语义。
        case reuseActive
        /// 总是新建 —— 桌面端「新对话」草稿态：UI 是纯本地草稿（不调 API），
        /// 后端 active 指针仍指着上一条对话，必须新建而不是复用。
        case alwaysCreate
    }

    /// 命令来源。只影响终端回显标签与转录里的 `source` 字段。
    enum Source: String {
        case desktop
        case http
        case watch

        /// 终端回显前缀。桌面端与 Windows `submit_command` 一致（裸 `> `，
        /// UI 认这个前缀做用户输入样式）；手机端沿用 macOS 既有的 `[iOS]` 约定。
        var terminalTag: String? {
            switch self {
            case .desktop: return nil
            case .http: return "[iOS]"
            case .watch: return "[Watch]"
            }
        }

        func terminalLine(for text: String) -> String {
            guard let tag = terminalTag else { return "> \(text)" }
            return "\(tag) > \(text)"
        }
    }

    // MARK: - 结果

    /// 提交成功。带上 `sessionID` / `status` 是为了让 HTTP 响应体与改造前逐字一致
    /// （iOS 端会读这两个字段）。
    struct SubmitSuccess {
        var commandID: String
        var sessionID: String?
        var status: String?
        /// 命令实际落入的对话（桌面端 `send_command` 要把它返回给 UI 做定位/激活）。
        var conversationID: String?
    }

    enum SubmitOutcome {
        case ok(SubmitSuccess)
        case pending(PendingApproval)
    }

    struct DecisionOutcome {
        /// `"denied"` 或 `"executed"`。
        var status: String
        var commandID: String?
    }

    enum SubmitError: LocalizedError {
        case emptyText
        case conversationNotFound
        case conversationArchived
        case conversationHasNoText
        case sendFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyText: return "text is empty"
            case .conversationNotFound: return "conversation not found"
            case .conversationArchived: return "conversation is archived — restore it first"
            case .conversationHasNoText: return "approval has no command text"
            case .sendFailed(let reason): return reason
            }
        }
    }

    // MARK: - 提交

    /// 提交一条命令：解析对话 → 过授权门卫 → 执行。
    ///
    /// - Parameters:
    ///   - draftWorkdir / draftApprovalMode: **仅**在本次调用新建对话时生效
    ///     （草稿物化），已有对话的改绑走 `ConversationStore.set*`。
    ///   - markExplicitActive: 显式指定对话时是否把它设为当前对话。
    ///     桌面端发消息 = 切到该对话（与 UI 视图一致）；HTTP 端保持原状（不切）。
    @discardableResult
    static func submit(
        text: String,
        conversationID: String?,
        router: CommandRouter,
        policy: DraftPolicy = .reuseActive,
        createAgentID: String? = nil,
        draftWorkdir: String? = nil,
        draftApprovalMode: String? = nil,
        source: Source = .http,
        markExplicitActive: Bool = false
    ) throws -> SubmitOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SubmitError.emptyText }

        let store = ConversationStore.shared
        if markExplicitActive, let raw = conversationID, !raw.isEmpty,
           store.activeConversation() != raw, store.get(raw) != nil {
            store.setActiveConversation(raw)
            DesktopEventBus.shared.post(.activeConversationChanged, payload: raw)
        }

        let conversation = try resolveConversation(
            explicitID: conversationID,
            policy: policy,
            createAgentID: createAgentID,
            workdir: draftWorkdir,
            approvalMode: draftApprovalMode
        )

        // 授权门卫按**该对话**的档位判定（授权是对话级设置）；
        // pending 记住所属对话，批准后回同一条对话执行。
        let mode = conversation.approvalMode.flatMap(ApprovalMode.init(rawValue:))
        switch ApprovalGate.shared.check(text: text, mode: mode, conversationID: conversation.id) {
        case .pending(let approval):
            return .pending(approval)
        case .allow:
            break
        }

        let success = try execute(
            text: text,
            conversationID: conversation.id,
            router: router,
            source: source
        )
        return .ok(success)
    }

    /// 裁决一条挂起命令。`deny` 只返回状态；批准类动作走与提交完全相同的执行路径
    /// （含所属对话上下文），保证回显与转录一致。
    static func decide(
        id: String,
        action: String,
        router: CommandRouter,
        source: Source = .desktop
    ) throws -> DecisionOutcome? {
        guard let resolution = ApprovalGate.shared.decide(id: id, action: action) else {
            return nil
        }
        switch resolution.action {
        case "deny":
            return DecisionOutcome(status: "denied", commandID: nil)
        case "approve", "always_approve":
            guard let text = resolution.text else { throw SubmitError.conversationHasNoText }
            let success = try execute(
                text: text,
                conversationID: resolution.conversationID,
                router: router,
                source: source
            )
            return DecisionOutcome(status: "executed", commandID: success.commandID)
        default:
            return nil
        }
    }

    // MARK: - 执行（私有）

    /// 公共执行入口：把命令正文写进 TerminalState 并提交给 agent。
    ///
    /// `conversationID` 非空时：命令由**该对话绑定的 Agent** 执行，cwd / 模型按
    /// 「对话级覆盖 ?? Agent 偏好」解析；用户条目与终态结果回写对话转录。
    private static func execute(
        text: String,
        conversationID: String?,
        router: CommandRouter,
        source: Source
    ) throws -> SubmitSuccess {
        let store = ConversationStore.shared
        let conversation = conversationID.flatMap { store.get($0) }
        let agentID = conversation?.agentId ?? AgentManager.shared.activeAgentID

        if let state = AgentManager.shared.terminalState(for: agentID) {
            let line = source.terminalLine(for: text)
            DispatchQueue.main.async {
                state.appendLine(line, type: .system)
                state.setStatus(.running)
            }
        }

        // cwd 回落链：对话绑定 ?? 该 Agent 的用户偏好（桌面端目录条设置）。
        // 与 Windows `command_runner` 的生效规则一致。
        let resolvedWorkdir = conversation?.workdirOverride
            ?? WorkdirPrefs.shared.get(agentID: agentID)

        let context = CommandContext(
            conversationID: conversationID,
            workdir: resolvedWorkdir,
            modelID: conversation?.modelOverride,
            providerID: conversation?.modelProviderOverride
        )
        let resp = router.route(.submit(text: text, context: context))

        if resp.ok, let commandID = resp.commandId {
            if let conversationID {
                // 转录落盘（单一写入口）：用户条目 + 调度指针
                store.append(
                    conversationID: conversationID,
                    role: "user",
                    text: text,
                    source: source.rawValue,
                    commandID: commandID
                )
                store.setLatestCommand(id: conversationID, commandID: commandID)
                DesktopEventBus.shared.post(.conversationsChanged, payload: ["id": conversationID])
            }
            return SubmitSuccess(
                commandID: commandID,
                sessionID: resp.sessionID,
                status: resp.status,
                conversationID: conversationID
            )
        }

        let reason = resp.error ?? "send failed"
        if let conversationID {
            store.append(
                conversationID: conversationID,
                role: "error",
                text: reason,
                source: nil,
                commandID: nil
            )
            store.setLatestCommand(id: conversationID, commandID: nil)
            DesktopEventBus.shared.post(.conversationsChanged, payload: ["id": conversationID])
        }
        throw SubmitError.sendFailed(reason)
    }

    /// 解析目标对话（三层回落）。
    private static func resolveConversation(
        explicitID: String?,
        policy: DraftPolicy,
        createAgentID: String?,
        workdir: String?,
        approvalMode: String?
    ) throws -> ConversationRecord {
        let store = ConversationStore.shared

        if let raw = explicitID, !raw.isEmpty {
            guard let conv = store.get(raw) else { throw SubmitError.conversationNotFound }
            if conv.archived { throw SubmitError.conversationArchived }
            return conv
        }

        if policy == .reuseActive,
           let activeID = store.activeConversation(),
           let conv = store.get(activeID), !conv.archived {
            return conv
        }

        let agentID = createAgentID ?? AgentManager.shared.activeAgentID
        let conv = store.createWithOptions(
            agentID: agentID,
            workdir: workdir,
            approvalMode: approvalMode
        )
        store.setActiveConversation(conv.id)
        DesktopEventBus.shared.post(.activeConversationChanged, payload: conv.id)
        DesktopEventBus.shared.post(.conversationsChanged, payload: ["id": conv.id])
        return conv
    }
}
