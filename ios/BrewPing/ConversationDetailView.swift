import SwiftUI

// ─── 对话详情（转录 + 工作目录条 + 输入框）─────────────────────────────────────
//
// 两种形态共用一套视图：
//   · conversationId != nil → 既有对话：转录来自桌面端 `GET /api/conversations/{id}`；
//   · conversationId == nil → 新对话（草稿）：本地先显示已发内容与进行中的状态，
//     首条消息由桌面端按「显式对话 → agent → active」三层回落创建/落到当前对话。
// 命令提交仍走单例 `CommandSubmitter`（与 Watch 通道共用同一套竞态/轮询逻辑）。

struct ConversationDetailView: View {
    /// `nil` = 新对话（草稿）。
    let conversationId: String?
    let device: ManagedDevice
    let online: Bool
    /// agentId → 显示名。
    let agentNames: [String: String]
    /// 已安装的 Agent 列表（对话设置里的 Agent 选择器用）。
    let agents: [AgentEntry]
    /// 草稿态用于占位文案的 agent id（当前默认 agent）。
    let fallbackAgentId: String

    @ObservedObject private var store = ConversationStore.shared
    @ObservedObject private var submitter = CommandSubmitter.shared
    @ObservedObject private var modelStore = ModelStore.shared
    @State private var draft = ""
    /// 刚发出、尚未落进服务端转录的那条用户消息（发出后立刻显示，避免"点了没反应"）。
    @State private var pendingUserText: String?
    /// 新对话草稿发送时由桌面端物化的对话 id（之后视图按既有对话工作）。
    @State private var materializedID: String?
    /// 对话设置弹窗（Agent / 模型 / 授权，均按对话独立）。
    @State private var showSettings = false
    /// 草稿态选定的 Agent（nil = 跟随桌面端当前默认 Agent）。
    @State private var draftAgentID: String?
    /// 草稿态选定的授权档位（nil = 跟随桌面端全局默认），随首条消息固化。
    @State private var draftApprovalMode: String?

    /// 生效对话 id：路由参数（既有对话）或草稿物化后的 id。
    private var activeConversationID: String? { conversationId ?? materializedID }
    /// 是否仍处于草稿态（未物化）。
    private var isDraft: Bool { activeConversationID == nil }
    /// 草稿生效的 Agent：草稿里选过的优先，否则跟随桌面端当前默认。
    private var draftResolvedAgentID: String { draftAgentID ?? fallbackAgentId }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.bpBorder.opacity(0.6))
            messageScroll
            workdirBar
            composer
        }
        .background(Color.bpBackground)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        // 模型列表跟随当前对话的 Agent（切 Agent 后自动重拉）
        .task(id: agentId) { await modelStore.refresh(device: device, agentID: agentId) }
        .sheet(isPresented: $showSettings) {
            ConversationSettingsView(
                device: device,
                online: online,
                agents: agents,
                isDraft: isDraft,
                store: store,
                modelStore: modelStore,
                approvalStore: ApprovalModeStore.shared,
                fallbackAgentID: fallbackAgentId,
                draftAgentID: $draftAgentID,
                draftApprovalMode: $draftApprovalMode,
                onChanged: { Task { await reloadAfterSettingsChange() } }
            )
        }
        .onChange(of: submitter.phase) { _, newPhase in
            // 命令结束后：清掉本地挂起项 + 重取权威转录（助手条目此时已落库）
            if !newPhase.inFlight { settle() }
        }
    }

    // MARK: - Header

    private var agentId: String {
        store.detail?.agentId ?? (isDraft ? draftResolvedAgentID : fallbackAgentId)
    }
    private var agentName: String { agentNames[agentId] ?? agentId }
    private var conversationTitle: String {
        if isDraft { return L("New Conversation") }
        return store.detail?.title ?? L("(untitled)")
    }

    /// 头部可点：进入对话设置（Agent / 模型 / 授权，均按对话独立）。
    private var header: some View {
        Button {
            showSettings = true
        } label: {
            HStack(spacing: 8) {
                Text(conversationTitle)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.bpForeground)
                    .lineLimit(1)
                Text(agentName)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.bpSecondaryForeground.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.bpSecondary))
                Spacer(minLength: 4)
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.bpMutedForeground)
                Circle()
                    .fill(online ? Color.bpSuccess : Color.bpDestructive)
                    .frame(width: 6, height: 6)
                Text(L(online ? "Online" : "Offline"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.bpMutedForeground)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Chat Settings"))
    }

    // MARK: - Messages

    /// 渲染项：服务端转录 + 本地挂起项（发出的消息 / 进行中的状态）。
    private var items: [ChatItem] {
        var list: [ChatItem] = (store.detail?.messages ?? []).map {
            ChatItem(id: $0.id, role: $0.role, text: $0.text, createdAtMs: $0.createdAtMs)
        }
        if let text = pendingUserText {
            list.append(
                ChatItem(
                    id: "local-user",
                    role: "user",
                    text: text,
                    createdAtMs: Date().timeIntervalSince1970 * 1000
                )
            )
        }
        // 草稿态没有服务端转录可查，助手输出直接来自提交引擎的状态机
        if isDraft {
            switch submitter.phase {
            case .completed(let response):
                list.append(ChatItem(id: "local-assistant", role: "assistant", text: response, createdAtMs: 0))
            case .completedRaw(let raw):
                list.append(ChatItem(id: "local-assistant", role: "assistant", text: raw, createdAtMs: 0))
            case .failed(let message):
                list.append(ChatItem(id: "local-error", role: "error", text: message, createdAtMs: 0))
            default:
                break
            }
        }
        return list
    }

    private var messageScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if items.isEmpty && !submitter.phase.inFlight {
                        Text("No messages yet.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.bpMutedForeground)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(items) { item in
                        row(item).id(item.id)
                    }
                    if submitter.phase.inFlight {
                        thinkingRow.id("__thinking__")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .onChange(of: items.count) { _, _ in
                if let last = items.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .onChange(of: submitter.phase) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("__thinking__", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ChatItem) -> some View {
        switch item.role {
        case "user":
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: item.createdAtMs > 0 ? bpTimeLabel(ms: item.createdAtMs) : "")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.bpMutedForeground)
                    Text("You")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.bpPrimary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.bpPrimary.opacity(0.15)))
                }
                Text(item.text)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.bpSecondaryForeground)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.bpSecondary)
                    )
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

        case "error":
            Text(item.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.bpDestructive)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case "system":
            Text(item.text)
                .font(.system(size: 11))
                .foregroundStyle(Color.bpMutedForeground.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .center)

        default:
            // 助手消息：通栏 Markdown（解析失败自动回落纯文本，不 crash）
            MarkdownText(text: item.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var thinkingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)
            Text(L("%@ is thinking…", agentName))
                .font(.system(size: 12))
                .foregroundStyle(Color.bpMutedForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Workdir bar

    private var boundDir: String? {
        guard let dir = store.detail?.workdirOverride, !dir.isEmpty else { return nil }
        return dir
    }

    private var workdirBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(Color.bpPrimary.opacity(0.85))
            if let dir = boundDir {
                Text(bpPathLabel(dir))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.bpForeground)
                Text(verbatim: dir)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.bpMutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(L("Unbound Folder"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.bpForeground)
            }
            Spacer(minLength: 6)
            Text(L(boundDir == nil ? "Not bound — the CLI default folder is used." : "This chat's folder. File operations use it."))
                .font(.system(size: 10))
                .foregroundStyle(Color.bpMutedForeground.opacity(0.8))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.bpCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.bpBorder, lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Composer

    private var canSend: Bool {
        online && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(L("Message %@", agentName))
                        .font(.system(size: 15))
                        .foregroundStyle(Color.bpMutedForeground.opacity(0.75))
                        .padding(.top, 8)
                        .padding(.leading, 4)
                }
                TextField("", text: $draft, axis: .vertical)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.bpForeground)
                    .lineLimit(1...5)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.vertical, 8)
            }

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(canSend ? Color.bpPrimaryForeground : Color.bpMutedForeground)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().fill(canSend ? Color.bpPrimary : Color.bpMuted)
                    )
            }
            .disabled(!canSend)
            .accessibilityLabel(Text("Send"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.bpCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.bpBorder, lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Actions

    private func load() async {
        guard let id = activeConversationID else { return }
        await store.open(id: id, device: device)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        pendingUserText = text
        // 新对话草稿：先物化（Agent / 授权档位随创建固化），再按新对话 id 提交。
        // 不再落到桌面端「当前激活对话」—— 那会把消息发进别的对话里。
        if isDraft {
            Task {
                if let newID = await store.createConversation(
                    device: device,
                    agentID: draftResolvedAgentID,
                    approvalMode: draftApprovalMode
                ) {
                    materializedID = newID
                    submitter.submit(text: text, fromWatch: false, conversationId: newID)
                } else {
                    pendingUserText = nil
                    draft = text
                }
            }
        } else {
            submitter.submit(text: text, fromWatch: false, conversationId: activeConversationID)
        }
    }

    /// 命令结束后重取权威数据（助手条目已落库）。
    private func settle() {
        pendingUserText = nil
        Task {
            if let id = activeConversationID {
                await store.open(id: id, device: device)
            }
            await store.refresh(device: device, force: true)
        }
    }

    /// 对话设置变更后刷新：详情（agentId / 模型覆盖 / 档位）与列表。
    private func reloadAfterSettingsChange() async {
        if let id = activeConversationID {
            await store.open(id: id, device: device)
        }
        await store.refresh(device: device, force: true)
    }
}

// MARK: - 渲染项

private struct ChatItem: Identifiable {
    let id: String
    /// user / assistant / error / system
    let role: String
    let text: String
    let createdAtMs: Double
}

// MARK: - Markdown 渲染（零依赖：AttributedString；失败回落纯文本）

struct MarkdownText: View {
    let text: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(.system(size: 15))
                .foregroundStyle(Color.bpForeground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // 半截/非法 Markdown：原样显示，绝不 crash
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Color.bpForeground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 对话设置（Agent / 模型 / 授权；均为**对话级**设置）

/// 从对话详情头部唤起的设置面板。移动端交互 = 表单 + 菜单选择器：
/// 每行一个 Picker（点开即选，不嵌套导航），选择立即生效并回写桌面端。
///
/// 与桌面端同一套语义：
///   · Agent —— 对话级绑定；既有对话里切换由桌面端自动清除该对话的模型覆盖；
///   · 模型 —— 对话级覆盖 > 该 Agent 默认模型；草稿态改的是 Agent 默认模型；
///   · 授权 —— 对话级档位；草稿态只记本地，随首条消息随对话固化。
struct ConversationSettingsView: View {
    let device: ManagedDevice
    let online: Bool
    /// 已安装的 Agent 列表（ContentView 的状态轮询已拉好）。
    let agents: [AgentEntry]
    let isDraft: Bool
    @ObservedObject var store: ConversationStore
    @ObservedObject var modelStore: ModelStore
    @ObservedObject var approvalStore: ApprovalModeStore
    /// 草稿态的兜底 Agent（桌面端当前默认）。
    let fallbackAgentID: String
    @Binding var draftAgentID: String?
    @Binding var draftApprovalMode: String?
    /// 设置变更成功后回调（详情页重取转录与列表）。
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var installedAgents: [AgentEntry] { agents.filter { $0.installed } }

    var body: some View {
        NavigationStack {
            Form {
                agentSection
                modelSection
                approvalSection
                if let error = store.detailError {
                    Section {
                        Text(verbatim: error)
                            .font(.footnote)
                            .foregroundStyle(Color.bpDestructive)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.bpBackground)
            .tint(Color.bpPrimary)
            .navigationTitle("Chat Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Agent

    private var currentAgentID: String {
        isDraft ? (draftAgentID ?? fallbackAgentID) : (store.detail?.agentId ?? fallbackAgentID)
    }

    private var agentSection: some View {
        Section {
            if installedAgents.isEmpty {
                Text(online
                     ? LocalizedStringKey("Detecting agents...")
                     : LocalizedStringKey("No agents detected. Connect a paired Mac to list the coding agents installed on it."))
                    .font(.caption)
                    .foregroundStyle(Color.bpMutedForeground)
            } else {
                Picker("Agent", selection: Binding(
                    get: { currentAgentID },
                    set: { newID in Task { await switchAgent(to: newID) } }
                )) {
                    ForEach(installedAgents) { agent in
                        // agent 名是主机上的数据，不翻译
                        Text(verbatim: agent.name).tag(agent.id)
                    }
                }
            }
            if !isDraft {
                Text("Switching the agent clears this chat's model choice. Other chats are unaffected.")
                    .font(.caption2)
                    .foregroundStyle(Color.bpMutedForeground)
            }
        } header: {
            Text("Agent")
        } footer: {
            Text("These settings apply to this conversation only.")
        }
    }

    private func switchAgent(to newID: String) async {
        guard newID != currentAgentID else { return }
        if isDraft {
            draftAgentID = newID
        } else if let id = store.detail?.id,
                  await store.setAgent(device: device, id: id, agentID: newID) {
            onChanged()
        }
    }

    // MARK: Model

    /// 当前选中模型的复合标识（provider/model）。草稿跟随 Agent 默认模型；
    /// 既有对话优先自己的覆盖，未设置 = 跟随 Agent 配置（空串）。
    private var currentModelComposite: String {
        if isDraft { return modelStore.activeModelID ?? "" }
        guard let overrideID = store.detail?.modelOverride else { return "" }
        let provider = store.detail?.modelProviderOverride
        if let match = modelStore.models.first(where: {
            $0.id == overrideID && (provider == nil || $0.providerID == provider)
        }) {
            return match.compositeID
        }
        // 覆盖的模型不在列表里（列表未刷新 / 已下架）：按 id 原样显示
        return overrideID
    }

    @ViewBuilder
    private var modelSection: some View {
        if modelStore.canSwitch {
            Section {
                Picker("Model", selection: Binding(
                    get: { currentModelComposite },
                    set: { newID in Task { await selectModel(composite: newID) } }
                )) {
                    if !isDraft {
                        Text("Follow Agent Config").tag("")
                    }
                    ForEach(modelStore.models) { model in
                        // 模型名 / provider 名是用户配置的数据，不翻译
                        Text(verbatim: model.providerName.isEmpty
                             ? model.name
                             : "\(model.name) · \(model.providerName)")
                            .tag(model.compositeID)
                    }
                }
                if !isDraft, store.detail?.modelOverride != nil {
                    Text("This chat uses its own model. Other chats are unaffected.")
                        .font(.caption2)
                        .foregroundStyle(Color.bpMutedForeground)
                }
            } header: {
                Text("Model")
            }
        }
    }

    private func selectModel(composite: String) async {
        if isDraft {
            // 草稿没有对话可写：选模型 = 设置该 Agent 的默认模型（新对话的起点）
            guard let option = modelStore.models.first(where: { $0.compositeID == composite }) else { return }
            modelStore.select(option.id, providerID: option.providerID)
            return
        }
        guard let id = store.detail?.id else { return }
        if composite.isEmpty {
            // 跟随 Agent 配置 = 清除对话级覆盖
            if await store.setModel(device: device, id: id, modelID: nil, providerID: nil) {
                onChanged()
            }
        } else if let option = modelStore.models.first(where: { $0.compositeID == composite }) {
            if await store.setModel(device: device, id: id, modelID: option.id, providerID: option.providerID) {
                onChanged()
            }
        }
    }

    // MARK: Approval

    private var currentApprovalMode: ApprovalModeStore.Mode {
        let raw = isDraft
            ? (draftApprovalMode ?? approvalStore.mode.rawValue)
            : (store.detail?.approvalMode ?? approvalStore.mode.rawValue)
        return ApprovalModeStore.Mode(rawValue: raw) ?? .safe
    }

    private var approvalSection: some View {
        Section {
            Picker("Approval Mode", selection: Binding(
                get: { currentApprovalMode },
                set: { newMode in Task { await setApproval(newMode) } }
            )) {
                ForEach(ApprovalModeStore.Mode.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            Text(currentApprovalMode.summary)
                .font(.caption2)
                .foregroundStyle(Color.bpMutedForeground)
        } header: {
            Text("Approval Mode")
        }
    }

    private func setApproval(_ mode: ApprovalModeStore.Mode) async {
        if isDraft {
            // 草稿只记本地，随首条消息随对话固化；不动全局默认
            draftApprovalMode = mode.rawValue
        } else if let id = store.detail?.id,
                  await store.setApprovalMode(device: device, id: id, mode: mode.rawValue) {
            onChanged()
        }
    }
}
