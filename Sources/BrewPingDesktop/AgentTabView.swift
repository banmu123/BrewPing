import SwiftUI
import BrewPingCore

/// Agent Tab 栏：终端风格绿色主题
struct AgentTabView: View {
    let agents: [AgentInfo]
    @Binding var activeAgentID: String
    var onSelect: (String) -> Void

    // 终端配色
    private let green   = Color(red: 0.30, green: 0.85, blue: 0.40)
    private let dimGreen = Color(red: 0.18, green: 0.50, blue: 0.24)
    private let amber   = Color(red: 1.00, green: 0.72, blue: 0.30)
    private let red     = Color(red: 1.00, green: 0.45, blue: 0.40)

    var body: some View {
        HStack(spacing: 0) {
            // 左侧 Logo
            HStack(spacing: 6) {
                Text("☕")
                    .font(.system(size: 11))
                Text("BrewPing")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(green.opacity(0.85))
            }
            .padding(.leading, 14)
            .padding(.trailing, 16)

            // 分隔线
            Rectangle()
                .fill(dimGreen.opacity(0.2))
                .frame(width: 1, height: 16)

            // Tab 按钮
            ForEach(agents) { agent in
                tabButton(agent)
            }

            Spacer()

            // 状态指示
            HStack(spacing: 4) {
                Circle()
                    .fill(green)
                    .frame(width: 5, height: 5)
                    .opacity(0.8)
                Text("ONLINE")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(dimGreen.opacity(0.7))
            }
            .padding(.trailing, 14)
        }
        .frame(height: 34)
        .background(Color(red: 0.07, green: 0.07, blue: 0.07))
        .overlay(
            Rectangle()
                .fill(dimGreen.opacity(0.15))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    @ViewBuilder
    private func tabButton(_ agent: AgentInfo) -> some View {
        let isActive = agent.id == activeAgentID

        Button {
            onSelect(agent.id)
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor(for: agent.status))
                    .frame(width: 5, height: 5)

                Text(agent.name)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular, design: .monospaced))
                    .foregroundColor(isActive ? green : dimGreen.opacity(0.65))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isActive
                    ? green.opacity(0.08)
                    : Color.clear
            )
            .cornerRadius(3)
        }
        .buttonStyle(.plain)
    }

    private func statusColor(for status: AgentStatus) -> Color {
        switch status {
        case .idle:     return dimGreen.opacity(0.5)
        case .running:  return green
        case .error:    return red
        case .stopped:  return amber
        }
    }
}
