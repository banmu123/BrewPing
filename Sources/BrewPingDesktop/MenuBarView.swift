import SwiftUI
import BrewPingCore

struct MenuBarView: View {
    @ObservedObject var core: DesktopCore
    /// 菜单打开时从 ConversationStore 拉一次快照（点行切换激活对话）。
    @State private var conversationSummaries: [ConversationSummary] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Text("BrewPing")
                    .font(.headline)
                Spacer()
                runtimeBadge
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

            // Conversations（多对话；与 Windows 端 / iOS 端同一份数据）
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Conversations")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        conversationSummaries = ConversationStore.shared.list(includeArchived: false)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh conversations")
                }
                if conversationSummaries.isEmpty {
                    Text("No conversations yet — send a message from iPhone or terminal.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let activeID = ConversationStore.shared.activeConversation()
                    ForEach(conversationSummaries) { summary in
                        Button {
                            ConversationStore.shared.setActiveConversation(summary.id)
                            conversationSummaries = ConversationStore.shared.list(includeArchived: false)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: summary.id == activeID ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(summary.id == activeID ? Color.green : Color.secondary)
                                    .font(.caption2)
                                VStack(alignment: .leading, spacing: 1) {
                                    // 标题来自用户消息，是数据、不翻译
                                    Text(summary.title ?? "(untitled)")
                                        .font(.callout)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    HStack(spacing: 4) {
                                        // agent 名是数据、不翻译
                                        Text(verbatim: core.agents.first { $0.id == summary.agentId }?.name ?? summary.agentId)
                                        Text("·")
                                        Text("\(summary.messageCount) msgs")
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Set as the active conversation")
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
            // 打开菜单时刷新状态与对话列表
            await core.refreshStatus()
            conversationSummaries = ConversationStore.shared.list(includeArchived: false)
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

    /// 启动期间显示灰点 + "Starting…"，让用户能区分"还没好"和"真的没起来"。
    /// `.online` 之前（默认 `.idle`）会被渲染成红色 Offline 是误导——其实只是 brewping
    /// 自己进程刚拉起、agent 还没 spawn 完。`.starting` 把这段中间态显式画出来。
    @ViewBuilder
    private var runtimeBadge: some View {
        HStack(spacing: 5) {
            switch core.runtimeState {
            case .online:
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("Online").foregroundStyle(.green)
            case .starting:
                // 灰色 + 轻微脉动：用 .opacity 而不是 ProgressView，避免菜单栏弹窗抖动
                Circle().fill(Color.gray).frame(width: 8, height: 8)
                Text("Starting…").foregroundStyle(.secondary)
            case .offline, .idle:
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text("Offline").foregroundStyle(.red)
            }
        }
        .font(.caption)
    }
}
