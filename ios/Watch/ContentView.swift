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
        }
    }
}

struct ContentView: View {
    @StateObject private var sessionManager = WatchSessionManager()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // MARK: - 设备切换（可左右滑动）
                if sessionManager.devices.count > 1 {
                    deviceSwipeSection
                } else if let device = sessionManager.devices.first {
                    singleDeviceBanner(device)
                }

                // MARK: - Agent 切换区（可左右滑动）
                agentSwipeSection

                // MARK: - 模型切换区（可左右滑动）
                modelSwipeSection

                // MARK: - 连接状态
                connectionStatusSection

                // 语音入口只依赖会话是否激活：
                // 音频经 transferFile 排队投递，iPhone App 不在前台时同样能发。
                if sessionManager.activationState == .activated {
                    // MARK: - 语音命令
                    VoiceCommandView(sessionManager: sessionManager)
                }

                if let error = sessionManager.lastError {
                    // error 是动态内容（设备返回 / WCSession 错误），不做本地化
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 4)
        }
        .onAppear {
            sessionManager.activate()
            // iPhone 端可能已在 Watch 启动前 push 过语言偏好；确保本端 bundle 已就位。
            WatchLanguageManager.shared.applyLanguage()
        }
    }

    // MARK: - 设备滑动切换

    private var deviceSwipeSection: some View {
        VStack(spacing: 2) {
            TabView(selection: $sessionManager.activeDeviceIndex) {
                ForEach(Array(sessionManager.devices.enumerated()), id: \.element.id) { index, device in
                    deviceCard(device)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .frame(height: 40)
            .onChange(of: sessionManager.activeDeviceIndex) { _, newIndex in
                sessionManager.switchToDevice(index: newIndex)
            }

            Text("← swipe device →")
                .font(.system(size: 7))
                .foregroundStyle(.tertiary)
        }
    }

    private func singleDeviceBanner(_ device: WatchDevice) -> some View {
        HStack(spacing: 4) {
            Image(systemName: device.icon)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(device.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    private func deviceCard(_ device: WatchDevice) -> some View {
        HStack(spacing: 6) {
            Image(systemName: device.icon)
                .font(.system(size: 12))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Text(device.osLabel)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.08))
        )
    }

    // MARK: - Agent 滑动切换

    private var agentSwipeSection: some View {
        VStack(spacing: 4) {
            TabView(selection: $sessionManager.activeAgentIndex) {
                ForEach(Array(sessionManager.agents.enumerated()), id: \.element.id) { index, agent in
                    agentCard(agent)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .frame(height: 52)
            .onChange(of: sessionManager.activeAgentIndex) { _, newIndex in
                sessionManager.switchToAgent(index: newIndex)
            }

            if sessionManager.agents.count > 1 {
                Text("← swipe to switch →")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func agentCard(_ agent: WatchAgent) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Text(agentIcon(for: agent.id))
                    .font(.system(size: 14))
                Text(agent.name)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
            }

            if agent.id == sessionManager.activeAgentID {
                statusLabelText
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(statusColor)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.08))
        )
    }

    // MARK: - 模型滑动切换

    /// 与 Agent 切换同一套交互（左右滑动），小屏上不需要弹层。
    /// 只有真的有得选（`models.count > 1`）才出现。
    @ViewBuilder
    private var modelSwipeSection: some View {
        if sessionManager.canSwitchModel {
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Button {
                        sessionManager.stepModel(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 24)
                    }
                    .buttonStyle(.plain)

                    // 当前生效的模型名（用户配置的数据，不翻译）
                    Text(verbatim: sessionManager.activeModelName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)

                    Button {
                        sessionManager.stepModel(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 24)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.08))
                )

                // 有多个模型时才提示可以切换
                if sessionManager.models.count > 1 {
                    Text("← switch model →")
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func agentIcon(for agentId: String) -> String {
        switch agentId {
        case "opencode":    return "⌥"
        case "claude-code": return "◈"
        case "codex":       return "⌘"
        default:            return "●"
        }
    }

    /// 返回 `Text` 而不是 `String` —— 强制走 LocalizedStringKey 路径做本地化。
    private var statusLabelText: Text {
        switch sessionManager.agentMode {
        case "session":
            return sessionManager.sessionState == "running"
                ? Text("● running")
                : Text("○ idle")
        default:
            return Text("● ready")
        }
    }

    private var statusColor: Color {
        if sessionManager.agentMode == "session" {
            return sessionManager.sessionState == "running" ? .green : .orange
        }
        return .green
    }

    // MARK: - 连接状态

    private var connectionStatusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(sessionManager.reachable ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                statusText
                    .font(.caption2)
                    .foregroundStyle(sessionManager.reachable ? Color.secondary : Color.red)
            }

            if sessionManager.reachable {
                HStack(spacing: 4) {
                    Circle()
                        .fill(macDotColor)
                        .frame(width: 6, height: 6)
                    macStatusText
                        .font(.caption2)
                        .foregroundStyle(macDotColor == Color.green ? Color.secondary : Color.red)
                }
            }
        }
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
        case (true, "running"): return .green
        case (true, _): return .orange
        case (_, _): return .red
        }
    }

    /// 拼接文案：直接走 `Text` 多段拼接，避开 LocalizedStringKey 不支持插值。
    /// Watch 屏幕太小不需要精细样式，名字与"Ready/Running"直接拼成一句。
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
