import SwiftUI
import WatchKit

// MARK: - 对话页底部输入栏
//
// 交互形态（用户指定）：**只有一个居中的麦克风大按钮**。
//   点麦克风 → 弹出系统键盘（底部自带听写键，语音 / 打字都行）
//   → 说完 / 打完（键盘收起即失焦）**自动发送**
//   → 发送期间按钮变 loading（🔒 锁定，不能再次发送）
//   → 回复到达（震动 .success）→ 按钮短暂变 ✓ → 恢复麦克风，可进行下一次。
//
// ⚠️ 为什么不是 presentTextInputController：那是 WKInterfaceController 的 API，
//    SwiftUI App 生命周期里没有 WKInterfaceController，编译期就不存在。
//    `@FocusState` 聚焦唤起的系统键盘同样覆盖"语音 + 打字"。

struct WatchComposer: View {
    @ObservedObject var sessionManager: WatchSessionManager
    let conversationId: String

    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private var inFlight: Bool {
        switch sessionManager.commandState {
        case .sending, .sent: return true
        default: return false
        }
    }

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 🚨 `.completed` 带 String 关联值，不能用 `==` 比较，只能模式匹配。
    private var isCompletedState: Bool {
        if case .completed = sessionManager.commandState { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 失败提示：只有失败时出现（点一下收回）
            if case .failed(let message) = sessionManager.commandState {
                // message 是动态内容（设备返回的错误），不做本地化
                Text(message)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.bpDestructive)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture { sessionManager.commandState = .idle }
            }

            composerCard
        }
        .onChange(of: sessionManager.commandState) { _, newState in
            if case .completed = newState {
                // 结果带对话 id：只刷新所属对话（旧版 iPhone 不带 id → 保持原行为）
                let owner = sessionManager.lastResultConversationId
                if owner == nil || owner == conversationId {
                    finishAndRefresh()
                }
            }
        }
        .onChange(of: inputFocused) { _, focused in
            // 键盘收起（说完话 / 点了别处）且还有内容 → 自动发送。
            // 这是"说完就发"的触发点：手表键盘没有回车键，失焦即提交。
            if !focused, hasDraft, !inFlight {
                sendDraft()
            }
        }
    }

    // MARK: - 输入区：失败提示 / 输入框（仅输入时出现）+ 居中麦克风
    // 🚨 用户指定：**不要奶白卡片底**，只留居中麦克风按钮悬浮在棕底上。
    //    失败提示与输入框直接铺底，配色用棕底专用 token。

    private var composerCard: some View {
        VStack(spacing: 6) {
            // 失败提示：铺底用提亮红（bpDestructive 在棕底上看不清），点一下收回
            if case .failed(let message) = sessionManager.commandState {
                // message 是动态内容（设备返回的错误），不做本地化
                Text(message)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.bpDestructiveBright)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture { sessionManager.commandState = .idle }
            }

            // 输入框只在唤起键盘 / 有草稿时出现；棕底上文字用奶白
            if inputFocused || hasDraft {
                TextField("Type...", text: $draft)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.bpOnBackground)
                    .focused($inputFocused)
                    .onSubmit { sendDraft() }
                    .padding(.horizontal, 6)
            }

            commandButton
        }
        .padding(.horizontal, 4)
    }

    /// 居中单按钮，三态：🎤 麦克风 → ⏳ loading（锁定）→ ✓ 完成（短暂）→ 🎤。
    private var commandButton: some View {
        Button {
            inputFocused = true
        } label: {
            Group {
                switch sessionManager.commandState {
                case .sending, .sent:
                    // 执行中：按钮本身就是 loading，取代原来那行小字"正在发送"
                    ProgressView()
                        .controlSize(.regular)
                        .tint(Color.bpOnBackground)
                case .completed:
                    // 回复到达后的短暂确认态（0.8s 后自动回到麦克风）
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.bpOnBackground)
                default:
                    Image(systemName: "mic.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(sessionManager.activationState == .activated
                                         ? Color.bpOnBackground : Color.bpOnBackgroundMuted)
                }
            }
            .frame(width: 52, height: 52)
            .background(Circle().fill(
                isCompletedState ? Color.bpSuccess.opacity(0.35) : Color.bpOnBackgroundMuted.opacity(0.35)
            ))
        }
        .buttonStyle(.plain)
        // 执行中锁定：等回复到了（震动 + ✓）才允许下一次
        .disabled(inFlight || sessionManager.activationState != .activated)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - 发送 / 收尾

    private func sendDraft() {
        guard hasDraft, !inFlight else { return }
        sessionManager.sendCommand(draft, conversationId: conversationId)
        draft = ""
        inputFocused = false
    }

    private func finishAndRefresh() {
        sessionManager.requestConversation(id: conversationId)
        // 稍作停留让 ✓ 可感知，然后回到麦克风
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if sessionManager.commandState != .idle {
                sessionManager.commandState = .idle
            }
        }
    }
}
