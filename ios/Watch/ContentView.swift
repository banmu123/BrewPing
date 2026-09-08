import SwiftUI
import WatchConnectivity

@main
struct BrewPingWatchApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var sessionManager = WatchSessionManager()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // MARK: - Agent 切换区（可左右滑动）
                agentSwipeSection

                // MARK: - 连接状态
                connectionStatusSection

                if sessionManager.reachable {
                    // MARK: - 语音命令
                    VoiceCommandView(sessionManager: sessionManager)
                }

                if let error = sessionManager.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 4)
        }
        .onAppear {
            sessionManager.activate()
        }
    }

    // MARK: - Agent 滑动切换

    private var agentSwipeSection: some View {
        VStack(spacing: 4) {
            // 可左右滑动的 Agent 卡片
            TabView(selection: $sessionManager.activeAgentIndex) {
                ForEach(Array(sessionManager.agents.enumerated()), id: \.element.id) { index, agent in
                    agentCard(agent)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .frame(height: 52)
            .onChange(of: sessionManager.activeAgentIndex) { newIndex in
                sessionManager.switchToAgent(index: newIndex)
            }

            // 滑动提示
            if sessionManager.agents.count > 1 {
                Text("← swipe to switch →")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func agentCard(_ agent: WatchAgent) -> some View {
        VStack(spacing: 2) {
            // Agent 名称
            HStack(spacing: 4) {
                Text(agentIcon(for: agent.id))
                    .font(.system(size: 14))
                Text(agent.name)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
            }

            // 状态标签
            if agent.id == sessionManager.activeAgentID {
                Text(statusLabel)
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

    private func agentIcon(for agentId: String) -> String {
        switch agentId {
        case "opencode":    return "⌥"
        case "claude-code": return "◈"
        case "codex":       return "⌘"
        default:            return "●"
        }
    }

    private var statusLabel: String {
        switch sessionManager.agentMode {
        case "session":
            return sessionManager.sessionState == "running" ? "● running" : "○ idle"
        default:
            return "● ready"
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
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(sessionManager.reachable ? Color.secondary : Color.red)
            }

            if sessionManager.reachable {
                HStack(spacing: 4) {
                    Circle()
                        .fill(macDotColor)
                        .frame(width: 6, height: 6)
                    Text(macStatusText)
                        .font(.caption2)
                        .foregroundStyle(macDotColor == Color.green ? Color.secondary : Color.red)
                }
            }
        }
    }

    private var statusText: String {
        if sessionManager.activationState != .activated {
            return "Connecting..."
        }
        return sessionManager.reachable ? "Connected" : "iPhone Not Connected"
    }

    private var macDotColor: Color {
        switch (sessionManager.macConnected, sessionManager.sessionState) {
        case (true, "running"): return .green
        case (true, _): return .orange
        case (_, _): return .red
        }
    }

    private var macStatusText: String {
        if sessionManager.agentMode != "session" {
            return "Mac: \(sessionManager.agentName) Ready"
        }
        switch (sessionManager.macConnected, sessionManager.sessionState) {
        case (true, "running"): return "Mac: \(sessionManager.agentName) Running"
        case (true, _): return "Mac: Session Stopped"
        case (_, _): return "Mac: Offline"
        }
    }
}
