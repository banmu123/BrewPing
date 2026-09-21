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
    /// 用户是否正停在底部。上翻阅读时置为 false，自动跟随随之中止。
    @State private var atBottom = true

    /// 是否正在接收增量（决定助手气泡用轻量渲染还是完整 Markdown）。
    private var isStreaming: Bool {
        guard let phase = app.run?.phase else { return false }
        return phase == .streaming || phase == .stalled
    }

    /// 是否显示执行状态指示器（提交 / 排队 / 等首字 / 生成中 / 停止中 / 卡住）。
    private var showIndicator: Bool {
        app.run?.phase.isActive == true
    }

    private var canSend: Bool {
        !app.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !app.isBusy
    }

    var body: some View {
        VStack(spacing: 0) {
            if app.messages.isEmpty && !showIndicator {
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
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        MessageList(messages: app.messages, isStreaming: isStreaming)

                        if showIndicator {
                            ConversationColumn { RunStatusIndicator() }
                        }

                        // 贴底锚点 + 自身位置上报（判断用户是否还在底部）
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: BottomAnchorKey.self,
                                        value: geo.frame(in: .named("chatScroll")).maxY
                                    )
                                }
                            )
                    }
                    .padding(.vertical, 16)
                    .scrollTargetLayoutCompat()
                }
                .coordinateSpace(name: "chatScroll")
                .onPreferenceChange(BottomAnchorKey.self) { maxY in
                    // 锚点落在视口下沿附近（含 48pt 容差）→ 认为用户在底部
                    atBottom = maxY <= outer.size.height + 48
                }
                .onChange(of: app.messages) { _ in
                    // 用户上翻阅读时**绝不**强制跳底，否则长回复根本读不了。
                    guard atBottom else { return }
                    followBottom(proxy)
                }
                .onChange(of: app.run?.phase) { _ in
                    guard atBottom else { return }
                    followBottom(proxy)
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .overlay(alignment: .bottomTrailing) {
                    if !atBottom {
                        jumpToLatest(proxy)
                            .padding(.trailing, 20)
                            .padding(.bottom, 12)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// 跟随底部：流式帧每秒多次抵达，带动画会排队、视觉上反而像卡顿，
    /// 因此流式期直接贴底，普通消息才保留过渡动画。
    private func followBottom(_ proxy: ScrollViewProxy) {
        if isStreaming {
            proxy.scrollTo("bottom", anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func jumpToLatest(_ proxy: ScrollViewProxy) -> some View {
        Button {
            atBottom = true
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                Text(i18n.t(.chatJumpToLatest))
                    .font(LatteFont.font10)
            }
            .foregroundStyle(Latte.primaryForeground)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Latte.primary)
            .clipShape(Capsule())
            .latteShadow(LatteShadow.panel)
        }
        .buttonStyle(.plain)
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

                        // 忙碌时发送钮换成停止钮：手动终止生成（含 headless 型 Agent）。
                        // 「正在停止」期间禁用，避免用户重复点击；停止请求超时仍未确认时
                        // 由状态机重新开放（见 RunIndicator.showsStop）。
                        if app.isBusy {
                            let stopping = app.run?.phase == .stopping
                            Button {
                                Task { await app.stopGeneration() }
                            } label: {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Latte.primaryForeground)
                                    .frame(width: 32, height: 32)
                                    .background(Latte.destructive.opacity(stopping ? 0.5 : 1))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(stopping)
                            .help(stopping ? i18n.t(.chatStopping) : i18n.t(.barStop))
                            .accessibilityLabel(i18n.t(.barStop))
                        } else {
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
    @EnvironmentObject private var app: DesktopAppState
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
            VStack(alignment: .leading, spacing: 8) {
                Text(msg.text)
                    .font(LatteFont.mono)
                    .foregroundStyle(Latte.warning)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // 失败必须能**就地处置**：重试 / 查看终端 / 复制错误。
                // 只给顶部那条会自动消失的错误条，用户根本来不及反应。
                HStack(spacing: 8) {
                    errorAction(i18n.t(.chatRetry), systemImage: "arrow.clockwise") {
                        Task { await app.retry(commandId: msg.commandId) }
                    }
                    errorAction(i18n.t(.chatViewTerminal), systemImage: "terminal") {
                        app.dockOpen = true
                    }
                    errorAction(i18n.t(.chatCopyError), systemImage: "doc.on.doc") {
                        app.copyToPasteboard(msg.text)
                    }
                }
            }
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
            if isStreaming && msg.id.hasPrefix("streaming_") {
                // Markdown 每帧都要全量分块、解析内联样式；长回复在高频更新下会
                // 显著掉帧。流式期先轻量展示原文，落库后自动换成完整 Markdown。
                StreamingAssistantMessage(text: msg.text)
                    .padding(.bottom, 20)
            } else {
                // 助手消息：无头像无角标，Markdown 直接通栏排版
                MarkdownView(text: msg.text)
                    .padding(.bottom, 20)
            }
        }
    }

    private func timeLabel(_ ms: Double?) -> String? {
        guard let ms, ms > 0 else { return nil }
        return DesktopDateFormat.messageTime(ms, locale: i18n.locale)
    }

    /// 失败消息下方的就地操作按钮（克制的次级样式，不跟主操作抢视线）。
    private func errorAction(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 10, weight: .medium))
                Text(title).font(LatteFont.font10)
            }
            .foregroundStyle(Latte.secondaryForeground)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Latte.muted)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 执行状态指示器

/// 底部锚点的滚动位置上报（判断用户是否还停在底部）。
private struct BottomAnchorKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 执行状态指示器：把状态机如实翻译成「现在到底在做什么」+ 已耗时 + 可执行操作。
///
/// 只反映**真实执行状态**，不展示也不伪造模型的隐藏思维链。
/// 内部的 `TimelineView` 每秒自更新一次，因此耗时与「已沉默多久」会持续走动 ——
/// 用户不必靠猜来判断是不是卡住了。
struct RunStatusIndicator: View {
    @EnvironmentObject private var i18n: I18n
    @EnvironmentObject private var app: DesktopAppState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let run = app.run, run.phase.isActive {
                indicator(run.indicator(now: context.date))
                    .padding(.bottom, 16)
            }
        }
    }

    private func indicator(_ info: RunIndicator) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if info.kind == .stopping || info.kind == .stopConfirmTimeout {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Latte.destructive)
                } else {
                    ThinkingDot()
                }

                Text(primaryText(info))
                    .font(LatteFont.xs)
                    .foregroundStyle(Latte.mutedForeground)

                Text(secondsLabel(info))
                    .font(LatteFont.font10)
                    .foregroundStyle(Latte.mutedForeground.opacity(0.7))
                    // 数字宽度固定，避免每秒刷新时文字左右抖动
                    .monospacedDigit()

                Spacer(minLength: 0)
            }

            if let detail = detailText(info) {
                Text(detail)
                    .font(LatteFont.font10)
                    .foregroundStyle(Latte.warning)
            }

            if info.showsStop || info.showsTerminal {
                HStack(spacing: 8) {
                    if info.showsTerminal {
                        smallAction(i18n.t(.chatViewTerminal), systemImage: "terminal") {
                            app.dockOpen = true
                        }
                    }
                    if info.showsStop {
                        smallAction(i18n.t(.barStop), systemImage: "stop.fill") {
                            Task { await app.stopGeneration() }
                        }
                    }
                }
            }
        }
    }

    /// 主文案：直接说明当前处在哪个真实阶段。
    private func primaryText(_ info: RunIndicator) -> String {
        switch info.kind {
        case .submitting: return i18n.t(.chatSubmitting)
        case .queued: return i18n.t(.chatQueued)
        case .thinking: return i18n.t(.chatConnecting)
        case .waitingLong: return i18n.t(.chatStillWorking)
        case .streaming: return i18n.t(.chatGenerating)
        case .stalled: return i18n.t(.chatNoNewOutput)
        case .stopping: return i18n.t(.chatStopping)
        case .stopConfirmTimeout: return i18n.t(.chatStopUnconfirmed)
        }
    }

    /// 耗时：提交/排队/等首字看总耗时；已在生成看「距上次输出」。
    private func secondsLabel(_ info: RunIndicator) -> String {
        if let silent = info.sinceLastOutputSeconds,
           info.kind == .streaming || info.kind == .stalled {
            return i18n.t(.chatSinceLastOutput, ["sec": "\(silent)"])
        }
        return i18n.t(.chatElapsed, ["sec": "\(info.elapsedSeconds)"])
    }

    /// 补充说明：只在「可能让人怀疑卡住」的阶段出现。
    private func detailText(_ info: RunIndicator) -> String? {
        switch info.kind {
        case .waitingLong, .stalled:
            return i18n.t(.chatStalledHint)
        case .stopConfirmTimeout:
            return i18n.t(.chatStopUnconfirmedHint)
        default:
            return nil
        }
    }

    private func smallAction(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 9, weight: .medium))
                Text(title).font(LatteFont.font10)
            }
            .foregroundStyle(Latte.secondaryForeground)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Latte.muted)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 流式回复的低开销渲染：不在每一帧做 Markdown 解析，同时保留明确的生成状态。
/// 最终转录落库后会由 `MarkdownView` 替代，因此代码块、表格等仍以完整样式呈现。
private struct StreamingAssistantMessage: View {
    @EnvironmentObject private var i18n: I18n
    var text: String

    @State private var cursorVisible = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                ThinkingDot()
                Text(i18n.t(.chatGenerating))
                    .font(LatteFont.font10)
                    .foregroundStyle(Latte.mutedForeground)
            }

            Text(verbatim: text + (cursorVisible ? "▍" : " "))
                .font(LatteFont.base)
                .foregroundStyle(Latte.foreground)
                .lineSpacing(LatteFont.baseLineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                cursorVisible = false
            }
        }
    }
}

// MARK: - 空态 Landing

struct LandingGreeting: View {
    @EnvironmentObject private var i18n: I18n
    var agentName: String

    var body: some View {
        GeometryReader { proxy in
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
                // 🚨 垂直居中的关键：内容区至少撑满视口高（不足一屏时居中，
                // 超长时仍可滚动）。原来直接放进 ScrollView → 内容顶在页首。
                .frame(minHeight: proxy.size.height)
                .padding(.horizontal, 16)
            }
        }
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

/// 输入框外壳：内边距 + 占位符 + 高度。
///
/// 🚨 高度**不走 `sizeThatFits`**，由 AppKit 量完通过 `onHeightChange` 回调给
///    SwiftUI，再显式 `.frame(height:)`。原因有两个：
///    1. SwiftUI 求理想尺寸时会用 `ProposedViewSize.unspecified`（width = nil），
///       此时 `nsView.bounds.width` 还是 0，量出来的结果会退化成 1pt 宽 ——
///       配合 `.fixedSize` 就把输入框塌没了（点不进、打不了字的另一个来源）；
///    2. `sizeThatFits` 里反复改 `textView.frame` 会在布局期间再触发布局，容易回环。
struct ComposerInput: View {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onFocusChange: (Bool) -> Void

    /// 文本内容高度（不含上下内边距）。初始值 = 最小高度。
    @State private var contentHeight: CGFloat = ComposerTextView.minContentHeight

    var body: some View {
        ComposerTextView(
            text: $text,
            onSubmit: onSubmit,
            onFocusChange: onFocusChange,
            onHeightChange: { height in
                guard abs(height - contentHeight) > 0.5 else { return }
                contentHeight = height
            }
        )
        .padding(.top, 14)        // pt-3.5
        .padding(.bottom, 6)      // pb-1.5
        .padding(.horizontal, 16) // px-4
        // 含内边距的总高：72…176（对齐 Windows `min-h-[72px] max-h-44`，border-box）
        .frame(height: contentHeight + 20)
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
    var onSubmit: () -> Void
    var onFocusChange: (Bool) -> Void
    var onHeightChange: (CGFloat) -> Void

    /// 内容区高度范围（不含 SwiftUI 侧 14+6 的内边距）。
    /// Windows：`min-h-[72px] max-h-44` 且 Tailwind 是 border-box，
    /// 即 72/176 **包含** `pt-3.5`(14) + `pb-1.5`(6)，所以内容区是 52…156。
    static let minContentHeight: CGFloat = 52
    static let maxContentHeight: CGFloat = 156

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // 🚨 必须用 `NSTextView.scrollableTextView()` 构造。手写
        //    `NSScrollView() + NSTextView(frame: .zero)` 时 documentView 的 frame
        //    是 .zero，AppKit 不替它布局 → 文本框不可见也不可点击。
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
        // 容器宽度跟随 textView 宽度；高度放开，由 layout 后量出真实内容高度。
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
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
            // 🚨 首字母丢失的根因修复：SwiftUI 可能携带**滞后的 binding 快照**
            // 调用本方法（如 textDidBeginEditing 先于 textDidChange 触发渲染），
            // 此刻用户刚敲的字符已在 textView 里、但还没经 delegate 推给 binding
            // —— 若无条件回写就会把刚输入的字母抹掉。
            // 判据：textView 的内容 ≠ coordinator 最后一次向 binding 推送的值
            // ⇒ AppKit 侧有更更新的编辑在途 → 以 AppKit 为准，跳过本次回写
            //（delegate 随后会推送真值，下轮渲染自然对齐）。
            // 只有 textView 与 lastPushed 一致（AppKit 无在途编辑）时，binding
            // 的差异才是真正的**外部变更**（发送后清空 / 切对话恢复草稿）→ 回写。
            if textView.string == context.coordinator.lastPushedToBinding {
                textView.string = text
            }
        }
        // 宽度变化（窗口缩放）后重新量高
        context.coordinator.reportHeight()
    }

    /// 量文本在**当前宽度**下的自然高度。不修改 textView.frame（避免布局回环）。
    static func contentHeight(of textView: NSTextView) -> CGFloat {
        guard let container = textView.textContainer, let manager = textView.layoutManager else {
            return minContentHeight
        }
        manager.ensureLayout(for: container)
        let used = ceil(manager.usedRect(for: container).height)
        return min(max(used, minContentHeight), maxContentHeight)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: NSTextView?
        /// 最后一次经 delegate 推给 binding 的文本（updateNSView 区分「滞后快照」
        /// 与「外部真变更」的判据，见 updateNSView 内注释）。
        var lastPushedToBinding = ""
        private var lastReported: CGFloat = 0

        init(_ parent: ComposerTextView) { self.parent = parent }

        /// 把内容高度报给 SwiftUI（唯一的高度来源）。
        /// 宽度还没被 SwiftUI 分配出来时跳过，等下一次 updateNSView 再报。
        func reportHeight() {
            guard let textView, textView.frame.width > 1 else { return }
            let height = ComposerTextView.contentHeight(of: textView)
            guard abs(height - lastReported) > 0.5 else { return }
            lastReported = height

            // document 高度用**未钳制**的自然高度：超出上限时 document 比 clip 高，
            // NSScrollView 才会真的滚起来（等价 textarea 的 max-h-44 行为）。
            if let container = textView.textContainer, let manager = textView.layoutManager {
                manager.ensureLayout(for: container)
                let natural = ceil(manager.usedRect(for: container).height)
                let target = max(natural, Self.minContentHeight)
                if abs(textView.frame.size.height - target) > 0.5 {
                    textView.frame.size.height = target
                }
            }
            parent.onHeightChange(height)
        }

        private static let minContentHeight = ComposerTextView.minContentHeight

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
            lastPushedToBinding = textView.string
            parent.text = textView.string
            reportHeight()
        }

        func textDidBeginEditing(_ notification: Notification) { parent.onFocusChange(true) }
        func textDidEndEditing(_ notification: Notification) { parent.onFocusChange(false) }
    }
}
