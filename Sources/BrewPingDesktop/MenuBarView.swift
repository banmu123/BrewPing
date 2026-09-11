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

            // Pairing：iPhone 端首次连接时需要用这里的配对码换取 token
            VStack(alignment: .leading, spacing: 4) {
                Text("Pairing")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let code = core.pairingCode {
                    HStack(spacing: 8) {
                        Text(code)
                            .font(.system(size: 18, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(code, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .help("Copy pairing code")
                        Button {
                            core.regeneratePairingCode()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .help("Generate a new pairing code (invalidates the current one)")
                    }
                    if let expiry = core.pairingCodeExpiresAt {
                        Text("Expires at \(expiry.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    // QR 码：iPhone 扫码后通过 brewping:// URL 自动唤起 App 并填好 host/port。
                    // 渲染前判 host/port 都有，否则提示"等待网络就绪"。
                    if let pairURL = core.pairingURL(code: code) {
                        VStack(alignment: .center, spacing: 6) {
                            PairingQRView(url: pairURL)
                            Text("Scan with BrewPing on iPhone")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                    } else {
                        Text("Waiting for network…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    Text("Or enter this code manually in the BrewPing iPhone app.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button {
                        core.revealPairingCode()
                    } label: {
                        HStack {
                            Image(systemName: "key")
                            Text("Show Pairing Code")
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .padding(.vertical, 2)
                }
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
