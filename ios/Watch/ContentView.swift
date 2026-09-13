import SwiftUI
import WatchConnectivity

@main
struct BrewPingWatchApp: App {
    @StateObject private var language = WatchLanguageManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                // 与 iPhone 端同款：locale 驱动 SwiftUI 的 Text 本地化，
                // .id 强制重建让已渲染的文案换语言。
                .environment(\.locale, language.locale)
                .id(language.preferredLanguage)
                // 奶白主题固定浅色外观（与 macOS 桌面端同一决策）。
                // 否则系统前景色（navigationTitle 等）在深色外观下是白色，
                // 铺在奶白底上直接隐形。
                .preferredColorScheme(.light)
        }
    }
}

struct ContentView: View {
    @StateObject private var sessionManager = WatchSessionManager()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // MARK: - 设备切换
                    deviceSection

                    // MARK: - 对话目录
                    conversationsEntry

                    // MARK: - 连接状态
                    connectionStatusSection

                    // 发送入口在**对话详情页底部**（与 iOS / macOS 同构）；
                    // Agent / 模型切换交给手机与桌面端，手表只看记录 + 在对话里续聊。

                    if let error = sessionManager.lastError {
                        // error 是动态内容（设备返回 / WCSession 错误），不做本地化
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.bpDestructiveBright)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
            // 🚨 导航标题是系统代渲染，preferredColorScheme 只能保证不是白色；
            //    要拿铁的深咖棕必须显式 foregroundStyle。
            .navigationTitle(Text("BrewPing").foregroundStyle(Color.bpOnBackground))
            .bpScreenBackground()
        }
        .onAppear {
            sessionManager.activate()
            // iPhone 端可能已在 Watch 启动前 push 过语言偏好；确保本端 bundle 已就位。
            WatchLanguageManager.shared.applyLanguage()
        }
    }

    // MARK: - 设备切换（左右箭头 + 当前值）

    /// 🚨 不用矮的 `TabView(.page)`：手表上把 `TabView` 压到几十 pt 高时，
    /// 页码正常但**卡片文字会渲染成空白**（项目已知坑）。改为「箭头 + 当前值」。
    @ViewBuilder
    private var deviceSection: some View {
        if sessionManager.devices.isEmpty {
            sectionLabel(Text("No device"))
        } else if sessionManager.devices.count == 1, let device = sessionManager.devices.first {
            HStack(spacing: 5) {
                Image(systemName: device.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.bpPrimary)
                Text(verbatim: device.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.bpForeground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .bpCardStyle(cornerRadius: 8)
        } else {
            VStack(spacing: 3) {
                stepper(
                    left: { sessionManager.stepDevice(by: -1) },
                    right: { sessionManager.stepDevice(by: 1) }
                ) {
                    HStack(spacing: 5) {
                        Image(systemName: activeDevice?.icon ?? "desktopcomputer")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.bpPrimary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: activeDevice?.name ?? "")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.bpForeground)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text(verbatim: activeDevice?.osLabel ?? "")
                                .font(.system(size: 8))
                                .foregroundStyle(Color.bpMutedForeground)
                        }
                    }
                }
                sectionLabel(Text("← device →"))
            }
        }
    }

    private var activeDevice: WatchDevice? {
        guard sessionManager.activeDeviceIndex < sessionManager.devices.count else { return nil }
        return sessionManager.devices[sessionManager.activeDeviceIndex]
    }

    // MARK: - 通用步进器

    /// 「左箭头 + 内容 + 右箭头」。横向滑动手势并存（`simultaneousGesture`，
    /// 否则会抢掉箭头的点击），纵向滚动继续交给外层 ScrollView。
    private func stepper<Content: View>(
        left: @escaping () -> Void,
        right: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 6) {
            chevronButton("chevron.left", action: left)

            content()
                .frame(maxWidth: .infinity)

            chevronButton("chevron.right", action: right)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .bpCardStyle(cornerRadius: 8)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    // 只认「明确横向」的滑动（abs(dx) > 30 且横向分量占优），
                    // 纵向手势让给外层 ScrollView。
                    guard abs(dx) > 30, abs(dx) > abs(dy) else { return }
                    if dx < 0 { right() } else { left() }
                }
        )
    }

    private func chevronButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.bpPrimary)
                .frame(width: 22, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 小字提示（如「← device →」）
    private func sectionLabel(_ text: Text) -> some View {
        text
            .font(.system(size: 8))
            .foregroundStyle(Color.bpOnBackgroundMuted)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - 对话目录入口

    private var conversationsEntry: some View {
        NavigationLink {
            WatchConversationListView(sessionManager: sessionManager)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.bpPrimary)
                Text("Conversations")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.bpForeground)
                Spacer(minLength: 0)
                if sessionManager.conversationsLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else if !sessionManager.conversations.isEmpty {
                    Text("\(sessionManager.conversations.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.bpMutedForeground)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.bpMutedForeground)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .bpCardStyle(cornerRadius: 8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 连接状态

    private var connectionStatusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(sessionManager.reachable ? Color.bpSuccess : Color.bpDestructive)
                    .frame(width: 6, height: 6)
                statusText
                    .font(.system(size: 11))
                    .foregroundStyle(sessionManager.reachable ? Color.bpMutedForeground : Color.bpDestructive)
            }

            if sessionManager.reachable {
                HStack(spacing: 4) {
                    Circle()
                        .fill(macDotColor)
                        .frame(width: 6, height: 6)
                    macStatusText
                        .font(.system(size: 11))
                        .foregroundStyle(macDotColor == Color.bpSuccess ? Color.bpMutedForeground : Color.bpDestructive)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .bpCardStyle(cornerRadius: 8)
    }

    private var statusText: Text {
        if sessionManager.activationState != .activated {
            return Text("Connecting...")
        }
        return sessionManager.reachable
            ? Text("Connected")
            : Text("iPhone Not Connected")
    }

    private var macDotColor: Color {
        switch (sessionManager.macConnected, sessionManager.sessionState) {
        case (true, "running"): return Color.bpSuccess
        case (true, _):         return Color.bpWarning
        case (_, _):            return Color.bpDestructive
        }
    }

    /// 拼接文案：直接走 `Text` 多段拼接，避开 LocalizedStringKey 不支持插值。
    @ViewBuilder
    private var macStatusText: some View {
        let name = sessionManager.agentName
        if sessionManager.agentMode != "session" {
            Text("Mac: \(name) Ready")
        } else {
            switch (sessionManager.macConnected, sessionManager.sessionState) {
            case (true, "running"):
                Text("Mac: \(name) Running")
            case (true, _):
                Text("Mac: Session Stopped")
            case (_, _):
                Text("Mac: Offline")
            }
        }
    }
}
