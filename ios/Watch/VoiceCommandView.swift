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

    // MARK: - 麦克风 = 透明输入框的"皮肤"
    //
    // 🚨 点麦克风弹不出键盘的根因：程序化聚焦（`@FocusState.wrappedValue = true`）
    //    在 watchOS 上不可靠；而旧版"点输入框弹键盘"走的是**系统原生点击聚焦**。
    //    所以这里反过来：把透明 TextField 铺满按钮区域，麦克风图标只是
    //    `allowsHitTesting(false)` 的视觉层 —— 用户点的是麦克风的样子，
    //    命中的是输入框，走和旧版完全相同的原生路径。
    //
    // 聚焦后（键盘弹出）：麦克风淡出、输入框显形（奶白文字、居中、最多 3 行），
    // 说完/打完键盘收起即失焦 → 自动发送（手表键盘没有回车键）。

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

            inputArea
        }
        .padding(.horizontal, 4)
    }

    private var inputArea: some View {
        ZStack {
            // 视觉层：麦克风 / 转圈 / ✓（输入时淡出，且不拦截点击）
            statusVisual
                .allowsHitTesting(false)

            // 交互层：透明输入框 —— 空闲时几乎全透明但保留点击命中
            TextField("Type...", text: $draft)
                .font(.system(size: 13))
                .foregroundStyle(Color.bpOnBackground)
                .multilineTextAlignment(.center)
                .lineLimit(1...3)
                .focused($inputFocused)
                .onSubmit { sendDraft() }
                .opacity(isEditing ? 1 : 0.02)
                .disabled(inFlight)   // 执行中锁定：等回复到了才能进行下一次
                .frame(minHeight: 52)
        }
        .frame(maxWidth: .infinity)
    }

    private var isEditing: Bool {
        inputFocused || hasDraft
    }

    /// 视觉层三态：🎤 麦克风（空闲）→ ⏳ loading（锁定）→ ✓ 完成（短暂）→ 🎤。
    private var statusVisual: some View {
        Group {
            switch sessionManager.commandState {
            case .sending, .sent:
                // 执行中：按钮本身就是 loading
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
                    .font(.system(size: 24))
                    .foregroundStyle(sessionManager.activationState == .activated
                                     ? Color.bpOnBackground : Color.bpOnBackgroundMuted)
            }
        }
        .frame(width: 52, height: 52)
        .background(Circle().fill(
            isCompletedState ? Color.bpSuccess.opacity(0.35) : Color.bpOnBackgroundMuted.opacity(0.30)
        ))
        .frame(maxWidth: .infinity)
    }

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 🚨 `.completed` 带 String 关联值，不能用 `==` 比较，只能模式匹配。
    private var isCompletedState: Bool {
        if case .completed = sessionManager.commandState { return true }
        return false
    }

    private var inFlight: Bool {
        switch sessionManager.commandState {
        case .sending, .sent: return true
        default: return false
        }
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
