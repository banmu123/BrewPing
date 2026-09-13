import SwiftUI

// ─── 手表对话目录 + 迷你对话页 ─────────────────────────────────────────────────
//
// 数据由 iPhone 代抓（`WatchSessionManager.requestConversations` /
// `requestConversation`），手表不直连 Mac。
//
// 小屏适配要点：
//   · 目录只显示标题 + 一行元信息，超长标题最多两行；
//   · 对话页是「用户气泡靠右 / 助手通栏」的纯文本布局 —— 手表上渲染 Markdown
//     既挤又难读，与 iOS 端的富文本有意不同；
//   · 消息从新到旧排列时用倒序 + 顶部对齐，天然停在最新一条（不依赖 scrollTo）；
//   · 卡片高亮只靠 `bpAccent`，选中态不靠颜色对比度硬撑。

// MARK: - 对话目录

struct WatchConversationListView: View {
    @ObservedObject var sessionManager: WatchSessionManager

    var body: some View {
        Group {
            if sessionManager.conversationsLoading && sessionManager.conversations.isEmpty {
                loadingView
            } else if let error = sessionManager.conversationsError,
                      sessionManager.conversations.isEmpty {
                noticeView(error, icon: "exclamationmark.triangle", color: Color.bpDestructive)
            } else if sessionManager.conversations.isEmpty {
                noticeView(LW("No conversations yet"),
                           icon: "bubble.left.and.bubble.left.right", color: Color.bpMutedForeground)
            } else {
                // 🚨 watchOS 的 `.refreshable` 只在 `List` 上有下拉刷新，
                //    `ScrollView` 上不生效 —— 所以目录用 List 而不是 ScrollView。
                List {
                    ForEach(sessionManager.conversations) { conversation in
                        NavigationLink {
                            WatchConversationDetailView(
                                sessionManager: sessionManager,
                                conversation: conversation
                            )
                        } label: {
                            row(conversation)
                        }
                        .listRowBackground(Color.clear)
                        // 🚨 `.listRowSeparator` 在 watchOS 不可用（iOS 专属）。
                        //    watchOS 的 List 本来就不画 iOS 那种分隔线，
                        //    行间距由 `.listRowInsets` 控制，无需额外处理。
                        .listRowInsets(EdgeInsets(top: 3, leading: 2, bottom: 3, trailing: 2))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle(Text("Conversations").foregroundStyle(Color.bpOnBackground))
        .bpScreenBackground()
        .refreshable { sessionManager.requestConversations() }
        .onChange(of: sessionManager.commandState) { _, newState in
            // 命令结果一到就自动同步目录（条数 / 时间戳），不用手动下拉
            if newState != .idle, newState != .sending {
                sessionManager.requestConversations()
            }
        }
        .onAppear {
            // 目录跟着当前设备走，进入页面时拉一次最新数据
            sessionManager.requestConversations()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 6) {
            ProgressView()
            Text("Loading…")
                .font(.system(size: 12))
                .foregroundStyle(Color.bpOnBackgroundMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    private func noticeView(_ message: String, icon: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
            Text(verbatim: message)
                .font(.system(size: 12))
                .foregroundStyle(Color.bpMutedForeground)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.top, 24)
    }

    private func row(_ conversation: WatchConversation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if conversation.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.bpPrimary)
                }
                Text(verbatim: conversation.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.bpForeground)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            HStack(spacing: 4) {
                Text(verbatim: conversation.agentId)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(verbatim: "·")
                Text(verbatim: bpWatchTimeLabel(ms: conversation.updatedAtMs))
                Text(verbatim: "·")
                Text(verbatim: String(conversation.messageCount))
            }
            .font(.system(size: 9))
            .foregroundStyle(Color.bpMutedForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .bpCardStyle(cornerRadius: 8)
    }
}

// MARK: - 迷你对话页

struct WatchConversationDetailView: View {
    @ObservedObject var sessionManager: WatchSessionManager
    let conversation: WatchConversation

    var body: some View {
        Group {
            if sessionManager.detailLoading && sessionManager.conversationDetail == nil {
                loadingView
            } else if let error = sessionManager.detailError,
                      sessionManager.conversationDetail == nil {
                errorView(error)
            } else if let detail = sessionManager.conversationDetail {
                messageList(detail)
            } else {
                loadingView
            }
        }
        .navigationTitle(Text(verbatim: displayTitle).foregroundStyle(Color.bpOnBackground))
        .bpScreenBackground()
        // 输入栏钉在底部（safeAreaInset watchOS 8+ 可用）：与 iOS / macOS 同构，
        // 消息发送发生在**对话里面**。滚动内容自动为它让位。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WatchComposer(sessionManager: sessionManager, conversationId: conversation.id)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
        }
        .onAppear {
            // 从目录点进来时拉最新转录；返回再进来也会刷新
            sessionManager.requestConversation(id: conversation.id)
        }
    }

    private var displayTitle: String {
        let title = sessionManager.conversationDetail?.title ?? conversation.title
        return title
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)
            Text("Loading…")
                .font(.system(size: 12))
                .foregroundStyle(Color.bpOnBackgroundMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 18))
                .foregroundStyle(Color.bpWarning)
            Text(verbatim: message)
                .font(.system(size: 12))
                .foregroundStyle(Color.bpMutedForeground)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 8)
    }

    /// 倒序排列 + 顶部对齐：ScrollView 天然停在最新一条，
    /// 不需要 ScrollViewReader / scrollTo（小屏上那样还容易抖）。
    private func messageList(_ detail: WatchConversationDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // ScrollView 上 `.refreshable` 不可靠，刷新就做成一个明确的小按钮
                Button {
                    sessionManager.requestConversation(id: conversation.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Refresh")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(sessionManager.detailLoading ? Color.bpMutedForeground : Color.bpPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.bpMuted.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .disabled(sessionManager.detailLoading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 2)

                if detail.truncated {
                    Text("Earlier messages not shown")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.bpOnBackgroundMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 2)
                }

                // reversed()：最新一条在最上面（离标题最近），手表上不用滚动就能看到
                ForEach(detail.messages.reversed()) { message in
                    bubble(message)
                }

                if detail.messages.isEmpty {
                    Text("No messages yet")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.bpOnBackgroundMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 20)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func bubble(_ message: WatchChatMessage) -> some View {
        switch message.role {
        case "user":
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: message.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bpSecondaryForeground)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.bpSecondary)
                    )
                if message.createdAtMs > 0 {
                    Text(verbatim: bpWatchTimeLabel(ms: message.createdAtMs))
                        .font(.system(size: 8))
                        .foregroundStyle(Color.bpOnBackgroundMuted)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        case "error":
            Text(verbatim: message.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.bpDestructive)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case "system":
            Text(verbatim: message.text)
                .font(.system(size: 9))
                .foregroundStyle(Color.bpMutedForeground.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
        default:
            // 助手消息通栏排版：手表宽度有限，气泡两侧留白太浪费
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: message.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bpForeground)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    // 🚨 `.textSelection` 在 watchOS 不可用，去掉。
                if message.createdAtMs > 0 {
                    Text(verbatim: bpWatchTimeLabel(ms: message.createdAtMs))
                        .font(.system(size: 8))
                        .foregroundStyle(Color.bpOnBackgroundMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .bpCardStyle(cornerRadius: 10)
        }
    }
}
