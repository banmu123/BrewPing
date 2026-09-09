import SwiftUI
import BrewPingCore

struct MenuBarView: View {
    @ObservedObject var core: DesktopCore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Text("BrewPing")
                    .font(.headline)
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(core.isRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(core.isRunning ? "Online" : "Offline")
                        .font(.caption)
                        .foregroundStyle(core.isRunning ? .green : .red)
                }
            }

            Divider()

            // Device Info
            infoRow("Device", core.deviceName)
            infoRow("Device ID", String(core.deviceId.prefix(16)) + (core.deviceId.count > 16 ? "..." : ""))
            if let ip = core.lanIP {
                infoRow("IP", ip)
            }
            if let port = core.httpPort {
                infoRow("Port", "\(port)")
            }

            Divider()

            // Agents
            VStack(alignment: .leading, spacing: 4) {
                Text("Agents")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(core.agents.filter { $0.installed }, id: \.id) { agent in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption2)
                        Text(agent.name)
                            .font(.callout)
                        Spacer()
                        if let version = agent.version {
                            Text(version)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                let notInstalled = core.agents.filter { !$0.installed }
                if !notInstalled.isEmpty {
                    ForEach(notInstalled, id: \.id) { agent in
                        HStack(spacing: 6) {
                            Image(systemName: "circle")
                                .foregroundStyle(.gray)
                                .font(.caption2)
                            Text(agent.name)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Not Installed")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()

            // Show Terminal
            Button {
                TerminalWindowManager.shared.showTerminal()
            } label: {
                HStack {
                    Image(systemName: "terminal")
                    Text("Show Terminal")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .font(.callout)
            .padding(.vertical, 2)

            Divider()

            // Quit
            Button("Quit BrewPing") {
                core.stop()
                NSApplication.shared.terminate(nil)
            }
            .font(.callout)
        }
        .padding(12)
        .frame(width: 260)
        .task {
            // 打开菜单时刷新状态
            await core.refreshStatus()
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
