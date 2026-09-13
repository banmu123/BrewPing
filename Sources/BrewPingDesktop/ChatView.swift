import AppKit
import BrewPingCore
import SwiftUI

// ─── 会话视图（chat-view.tsx 的 Swift 等价物）──────────────────────────────────
//
// 布局铁律（对齐 `conversation-layout.ts`）：滚动容器保持全宽，内容各自进列；
// 水平留白挂在列上，不挂在滚动容器上。列宽 = max-w-[46rem]（736pt）。

/// 会话内容列：`mx-auto w-full max-w-[46rem] px-3 sm:px-4`
///
/// 用注入的 `viewportWidth` 而不是逐处 GeometryReader —— 后者在 VStack 里会
/// 因为「GeometryReader 抢占剩余高度」把 composer 顶到奇怪的位置。宽度随窗口
/// 变化实时重算，列宽与留白都跟着变（对齐 Tailwind 的断点行为）。
struct ConversationColumn<Content: View>: View {
    @Environment(\.viewportWidth) private var viewportWidth
    @ViewBuilder var content: Content

    var body: some View {
        let column = LatteMetrics.columnWidth(available: viewportWidth)
        let inner = LatteMetrics.conversationWidth(available: viewportWidth)
        content
            .frame(width: inner, alignment: .leading)
            .frame(width: column, alignment: .center)
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
                        ConversationColumn {
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
        ConversationColumn {
            VStack(spacing: 0) {
                // 卡片上方独立条：工作目录展示与选择
                WorkdirPickerView()

                VStack(spacing: 0) {
                    ComposerInput(
                        text: Binding(get: { app.draftText }, set: { app.setDraftText($0) }),
                        placeholder: i18n.t(.chatPlaceholder, ["agent": app.convAgentName]),
                        onSubmit: submit,
                        onFocusChange: { composerFocused = $0 }
                    )

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
        ConversationColumn {
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

// MARK: - Composer 输入框
//
// 两层结构：
//   ComposerInput（SwiftUI）—— 负责内边距 / 占位符 / 高度钳制，尺寸与 Windows 的
//     `min-h-[72px] max-h-44` + `px-4 pt-3.5 pb-1.5` 严格对齐（Tailwind 是
//     border-box，72/176 **包含** 14+6 的上下内边距，所以内容区是 52…156）。
//   ComposerTextView（NSViewRepresentable）—— NSTextView，负责文字输入。
//
// 🚨 必须用 `NSTextView.scrollableTextView()` 建，不能手写
//    `NSScrollView() + NSTextView(frame: .zero)`：后者 documentView 的 frame 是
//    .zero，AppKit 不会替它布局 → 文本框不可见也不可点击，表现为「点不进、打不了字」。
//    （第一版就是这么错的。）
// 🚨 Enter 发送要走 `textView(_:doCommandBy:)` 而不是 `keyDown` 覆写：
//    前者是 NSTextView 的标准拦截点，输入法组字期间不会被调用，不会吞掉中文候选。

/// 输入框外壳：内边距 + 占位符 + 高度钳制。
struct ComposerInput: View {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onFocusChange: (Bool) -> Void

    var body: some View {
        ComposerTextView(
            text: $text,
            placeholder: placeholder,
            onSubmit: onSubmit,
            onFocusChange: onFocusChange
        )
        .padding(.top, 14)      // pt-3.5
        .padding(.bottom, 6)    // pb-1.5
        .padding(.horizontal, 16) // px-4
        // 🚨 不要写 .frame(minHeight: 72, maxHeight: 176)：那是**弹性**框，
        //    父级有余量时它会一路顶到 maxHeight 并把内容垂直居中 →
        //    输入框永远 176 高、文字浮在中间（第一版就是这个现象）。
        //    高度范围已在 sizeThatFits 里钳好（内容 52…156，含内边距即 72…176），
        //    fixedSize(vertical:) 保证父级不会再来拉伸它。
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Latte.mutedForeground.opacity(0.7))
                    .padding(.top, 14)
                    .padding(.leading, 16)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onFocusChange: (Bool) -> Void

    /// 内容区高度范围（不含 SwiftUI 侧 14+6 的内边距）。
    static let minContentHeight: CGFloat = 72 - 20    // 52
    static let maxContentHeight: CGFloat = 176 - 20   // 156

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // scrollableTextView() 会把 textContainer / autoresizingMask / min-maxSize
        // 全部按 AppKit 的约定装好（NSTextView 的标准构造路径）。
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.contentView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        configure(textView)
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        return scrollView
    }

    private func configure(_ textView: NSTextView) {
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textColor = NSColor(Latte.foreground)
        textView.insertionPointColor = NSColor(Latte.primary)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // 容器宽度跟随 textView 宽度；高度放开，由我们逐帧量出真实内容高度。
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        // 高度完全交给 sizeThatFits：不让 AppKit 的 minSize 锁死初始高度（否则
        // 输入框在窄内容时会撑到 scrollableTextView 的默认高度）。
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        context.coordinator.textView = textView
        if textView.string != text {
            textView.string = text
            textView.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        guard width > 1, let textView = context.coordinator.textView else {
            return CGSize(width: max(width, 1), height: Self.minContentHeight)
        }
        // 量出自然高度；超过上限的部分交给 NSScrollView 滚动（等价 max-h-44 之后出滚动条）。
        let used = Self.contentHeight(of: textView, width: width)
        return CGSize(width: width, height: min(max(used, Self.minContentHeight), Self.maxContentHeight))
    }

    /// 量文本在给定宽度下的自然高度，并把 textView 的 frame 同步过去
    /// （frame 高度用**未钳制**的值，这样超出上限时 NSScrollView 才会真的滚起来）。
    static func contentHeight(of textView: NSTextView, width: CGFloat) -> CGFloat {
        guard let container = textView.textContainer, let manager = textView.layoutManager else {
            return minContentHeight
        }
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 10_000)
        manager.ensureLayout(for: container)
        let used = ceil(manager.usedRect(for: container).height)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: max(used, minContentHeight))
        return used
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: NSTextView?

        init(_ parent: ComposerTextView) { self.parent = parent }

        /// Enter 发送 / Shift+Enter 换行。组字期间 AppKit 不会调用这里，
        /// 所以中文候选词的回车不受影响。
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            parent.onSubmit()
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            // 让 SwiftUI 重新量高（内容换行 / 删行时输入框跟着长高或缩短）。
            textView.invalidateIntrinsicContentSize()
        }

        func textDidBeginEditing(_ notification: Notification) { parent.onFocusChange(true) }
        func textDidEndEditing(_ notification: Notification) { parent.onFocusChange(false) }
    }
}
