import AppKit
import BrewPingCore
import SwiftUI

// ─── 会话视图（chat-view.tsx 的 Swift 等价物）──────────────────────────────────
//
// 布局铁律（对齐 `conversation-layout.ts`）：滚动容器保持全宽，内容各自进列；
// 水平留白挂在列上，不挂在滚动容器上。列宽 = max-w-[46rem]（736pt）。

/// 简化版列：不需要 GeometryReader 的场景（固定宽度内容）。
struct ConversationColumnSimple<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: LatteMetrics.conversationContentWidth, alignment: .leading)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct ChatView: View {
    @EnvironmentObject private var i18n: I18n
    @EnvironmentObject private var app: DesktopAppState

    @State private var composerFocused = false

    private var isStreaming: Bool {
        app.isBusy && !app.messages.isEmpty && app.messages.last?.role == "assistant"
    }

    private var showThinking: Bool {
        app.isBusy && (app.messages.isEmpty || app.messages.last?.role != "assistant")
    }

    private var canSend: Bool {
        !app.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !app.isBusy
    }

    var body: some View {
        VStack(spacing: 0) {
            if app.messages.isEmpty && !showThinking {
                LandingGreeting(agentName: app.convAgentName)
            } else {
                messageScroll
            }

            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 消息滚动区

    private var messageScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    MessageList(messages: app.messages, isStreaming: isStreaming)

                    if showThinking {
                        ConversationColumnSimple {
                            HStack(spacing: 8) {
                                ThinkingDot()
                                Text(i18n.t(.chatThinking, ["agent": app.convAgentName]))
                                    .font(LatteFont.xs)
                                    .foregroundStyle(Latte.mutedForeground)
                            }
                            .padding(.bottom, 16)
                        }
                    }

                    // 贴底锚点：新消息 / 流式增长 / 思考指示器变化都滚到底
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 16)
                .scrollTargetLayoutCompat()
            }
            .onChange(of: app.messages) { _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: showThinking) { _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Composer 停靠区

    private var composer: some View {
        ConversationColumnSimple {
            VStack(spacing: 0) {
                // 卡片上方独立条：工作目录展示与选择
                WorkdirPickerView()

                VStack(spacing: 0) {
                    ComposerTextView(
                        text: Binding(get: { app.draftText }, set: { app.setDraftText($0) }),
                        placeholder: i18n.t(.chatPlaceholder, ["agent": app.convAgentName]),
                        onSubmit: submit,
                        onFocusChange: { composerFocused = $0 }
                    )
                    .frame(minHeight: 72, maxHeight: 176)

                    HStack(spacing: 2) {
                        composerToolbar

                        Spacer(minLength: 0)

                        Button(action: submit) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(canSend ? Latte.primaryForeground : Latte.mutedForeground.opacity(0.6))
                                .frame(width: 32, height: 32)
                                .background(canSend ? Latte.primary : Latte.muted)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .help(i18n.t(.chatSendTitle))
                        .accessibilityLabel(i18n.t(.chatSend))
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .background(Latte.inputField)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            composerFocused ? Latte.primary.opacity(0.45) : Latte.inputBorder,
                            lineWidth: 1
                        )
                }
                .latteShadow(LatteShadow.panel)
            }
        }
        .padding(.bottom, 12)
    }

    /// 工具栏行：左侧 Agent / 模型 / 授权，右侧终端开关（发送钮在行尾，由 composer 负责）。
    private var composerToolbar: some View {
        HStack(spacing: 4) {
            // 切换 Agent
            ComposerDropdown(
                icon: "cpu",
                title: i18n.t(.barSwitchAgent),
                value: app.convAgentId,
                options: (app.installedAgents.isEmpty
                          ? [(value: app.convAgentId, label: app.convAgentName, description: nil)]
                          : app.installedAgents.map { (value: $0.id, label: $0.name, description: nil) }),
                onChange: { id in Task { await app.switchAgent(id) } },
                maxTriggerWidth: 160
            )

            // 切换模型（Agent 没有可用模型时隐藏）
            if !app.modelOptions.isEmpty {
                ComposerDropdown(
                    icon: "shippingbox",
                    title: i18n.t(.barPickModel),
                    value: app.currentModelKey,
                    options: [(value: "", label: i18n.t(.barFollowAgent), description: nil)]
                        + app.modelOptions.map { (value: $0.key, label: $0.name, description: $0.provider) },
                    onChange: { key in Task { await app.selectModel(key) } },
                    maxTriggerWidth: 192
                )
            }

            // 切换授权模式（对话级）
            ComposerDropdown(
                icon: "checkmark.shield",
                title: i18n.t(.barApproval),
                value: app.effectiveApprovalMode,
                options: approvalOptions,
                onChange: { mode in Task { await app.setApprovalMode(mode) } },
                maxTriggerWidth: 144,
                tint: approvalTint
            )

            Spacer(minLength: 0)

            Button {
                app.dockOpen.toggle()
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 13))
                    .foregroundStyle(app.dockOpen ? Latte.primary : Latte.mutedForeground)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(app.dockOpen ? Latte.accent : .clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(i18n.t(.barTerminal))
        }
    }

    private var approvalOptions: [(value: String, label: String, description: String?)] {
        [
            (ApprovalMode.safe.rawValue,
             i18n.t(.barApprovalItem, ["label": "safe"]),
             i18n.t(.approvalSafe)),
            (ApprovalMode.askAll.rawValue,
             i18n.t(.barApprovalItem, ["label": "askAll"]),
             i18n.t(.approvalAskAll)),
            (ApprovalMode.auto.rawValue,
             i18n.t(.barApprovalItem, ["label": "auto"]),
             i18n.t(.approvalAuto)),
        ]
    }

    private var approvalTint: Color? {
        switch app.effectiveApprovalMode {
        case ApprovalMode.askAll.rawValue: return Latte.warning
        case ApprovalMode.auto.rawValue: return Latte.success
        default: return nil
        }
    }

    private func submit() {
        let text = app.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !app.isBusy else { return }
        app.setDraftText("")
        Task { await app.send(text) }
    }
}

/// macOS 13 上没有 `scrollTargetLayout`，这里用空修饰符占位以保持结构清晰。
private extension View {
    @ViewBuilder
    func scrollTargetLayoutCompat() -> some View {
        if #available(macOS 14.0, *) {
            self.scrollTargetLayout()
        } else {
            self
        }
    }
}

// MARK: - 消息列表

struct MessageList: View {
    @EnvironmentObject private var i18n: I18n
    var messages: [ChatMessage]
    var isStreaming: Bool

    private var lastId: String { messages.last?.id ?? "-1" }

    var body: some View {
        ConversationColumnSimple {
            VStack(spacing: 0) {
                ForEach(messages) { msg in
                    row(msg)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func row(_ msg: ChatMessage) -> some View {
        switch msg.role {
        case "user":
            VStack(alignment: .trailing, spacing: 4) {
                if let label = timeLabel(msg.createdAtMs) {
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        Text(label)
                            .font(LatteFont.font10)
                            .foregroundStyle(Latte.mutedForeground)
                        Text(i18n.t(.chatMe))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Latte.primary)
                            .frame(width: 20, height: 20)
                            .background(Latte.primary.opacity(0.15))
                            .clipShape(Circle())
                    }
                }
                HStack {
                    Spacer(minLength: 0)
                    Text(msg.text)
                        .font(LatteFont.sm)
                        .foregroundStyle(Latte.secondaryForeground)
                        .lineSpacing(14 * 0.45)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        // 对齐 `max-w-[85%]`：列宽上限 736 - 32 内边距 = 704，其 85% ≈ 598
                        .frame(maxWidth: 598, alignment: .leading)
                        .background(Latte.secondary)
                        .clipShape(
                            UnevenRoundedRectangle(
                                topLeadingRadius: 16, bottomLeadingRadius: 16,
                                bottomTrailingRadius: 6, topTrailingRadius: 16,
                                style: .continuous
                            )
                        )
                }
            }
            .padding(.bottom, 16)

        case "error":
            Text(msg.text)
                .font(LatteFont.mono)
                .foregroundStyle(Latte.warning)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)

        case "system":
            Text(msg.text)
                .font(LatteFont.font10)
                .foregroundStyle(Latte.mutedForeground.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 12)

        default:
            // 助手消息：无头像无角标，Markdown 直接通栏排版
            MarkdownView(text: msg.text)
                .padding(.bottom, 20)
        }
    }

    private func timeLabel(_ ms: Double?) -> String? {
        guard let ms, ms > 0 else { return nil }
        return DesktopDateFormat.messageTime(ms, locale: i18n.locale)
    }
}

// MARK: - 空态 Landing

struct LandingGreeting: View {
    @EnvironmentObject private var i18n: I18n
    var agentName: String

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 20) {
                Text("☕").font(.system(size: 30))
                Text(i18n.t(.chatStandby, ["agent": agentName]))
                    .font(LatteFont.landing)
                    .foregroundStyle(Latte.foreground)
                    .multilineTextAlignment(.center)
                Text(i18n.t(.chatLandingHint))
                    .font(LatteFont.sm)
                    .foregroundStyle(Latte.mutedForeground)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Composer 输入框（NSTextView 包装：Enter 发送 / Shift+Enter 换行 / 自适应高度）

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onFocusChange: (Bool) -> Void

    private static let minHeight: CGFloat = 72
    private static let maxHeight: CGFloat = 176

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SubmitTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onFocusChange = onFocusChange

        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textColor = NSColor(Latte.foreground)
        textView.insertionPointColor = NSColor(Latte.primary)
        textView.allowsUndo = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .allowed
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SubmitTextView else { return }
        textView.onSubmit = onSubmit
        textView.onFocusChange = onFocusChange
        if textView.string != text {
            textView.string = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = nsView.documentView as? NSTextView else { return nil }
        context.coordinator.layoutManager(for: textView)?.ensureLayout(for: textView.textContainer!)
        let used = context.coordinator.layoutManager(for: textView)?
            .usedRect(for: textView.textContainer!).height ?? 0
        let height = min(max(used + textView.textContainerInset.height * 2 + 4, Self.minHeight), Self.maxHeight)
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: ComposerTextView

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func layoutManager(for textView: NSTextView) -> NSLayoutManager? {
            textView.layoutManager
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  textView.window?.firstResponder === textView else { return }
            parent.onFocusChange(true)
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChange(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onFocusChange(false)
        }
    }
}

/// Enter 发送 / Shift+Enter 换行；失焦时不做隐式提交（与 Windows textarea 一致）。
private final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Enter（含小键盘 Enter）= 发送；Shift+Enter = 换行；输入法组字期间一律不拦。
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let shift = event.modifierFlags.contains(.shift)
        let composing = hasMarkedText()
        if isReturn, !shift, !composing {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }
}
