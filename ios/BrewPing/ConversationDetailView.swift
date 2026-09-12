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
    /// 草稿态用于占位文案的 agent id（当前默认 agent）。
    let fallbackAgentId: String

    @ObservedObject private var store = ConversationStore.shared
    @ObservedObject private var submitter = CommandSubmitter.shared
    @State private var draft = ""
    /// 刚发出、尚未落进服务端转录的那条用户消息（发出后立刻显示，避免"点了没反应"）。
    @State private var pendingUserText: String?

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
        .onChange(of: submitter.phase) { _, newPhase in
            // 命令结束后：清掉本地挂起项 + 重取权威转录（助手条目此时已落库）
            if !newPhase.inFlight { settle() }
        }
    }

    // MARK: - Header

    private var agentId: String { store.detail?.agentId ?? fallbackAgentId }
    private var agentName: String { agentNames[agentId] ?? agentId }
    private var conversationTitle: String {
        if conversationId == nil { return L("New Conversation") }
        return store.detail?.title ?? L("(untitled)")
    }

    private var header: some View {
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
            Circle()
                .fill(online ? Color.bpSuccess : Color.bpDestructive)
                .frame(width: 6, height: 6)
            Text(L(online ? "Online" : "Offline"))
                .font(.system(size: 11))
                .foregroundStyle(Color.bpMutedForeground)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
        if conversationId == nil {
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
        guard let id = conversationId else { return }
        await store.open(id: id, device: device)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        pendingUserText = text
        submitter.submit(text: text, fromWatch: false, conversationId: conversationId)
    }

    /// 命令结束后重取权威数据（助手条目已落库）。
    private func settle() {
        pendingUserText = nil
        Task {
            if let id = conversationId {
                await store.open(id: id, device: device)
            }
            await store.refresh(device: device, force: true)
        }
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
