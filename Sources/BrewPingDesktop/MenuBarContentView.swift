import AppKit
import BrewPingCore
import SwiftUI

// ─── 菜单栏面板（Windows 托盘的 macOS 对应物）──────────────────────────────────
//
// Windows 的托盘菜单提供：状态、机器信息、显示配对码、打开主窗口、退出。
// macOS 用 MenuBarExtra（`.window` 样式）承载同一组动作，视觉沿用拿铁主题。

struct MenuBarContentView: View {
    @EnvironmentObject private var i18n: I18n
    @EnvironmentObject private var app: DesktopAppState
    @EnvironmentObject private var core: DesktopCore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("BrewPing").font(LatteFont.sm.weight(.semibold))
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    RuntimeDot(state: app.runtimeState, size: 6)
                    RuntimeLabel(state: app.runtimeState, text: runtimeText)
                }
            }

            LatteDivider()

            VStack(alignment: .leading, spacing: 4) {
                infoRow(i18n.t(.setDeviceName), core.deviceName)
                if let ip = core.lanIP {
                    infoRow(i18n.t(.setLanAddr), ip)
                }
                if let port = core.httpPort {
                    infoRow("Port", "\(port)")
                }
                infoRow(i18n.t(.setService), i18n.t(stateKey))
            }

            LatteDivider()

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    Task { await app.revealPairing() }
                    app.settingsOpen = true
                    app.settingsSection = .pairing
                    DesktopEventBus.shared.post(.pairingRevealed)
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "qrcode").font(.system(size: 11))
                        Text(i18n.t(.setShowCode)).font(LatteFont.xs)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: 6)

                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "macwindow").font(.system(size: 11))
                        Text(i18n.t(.topNewChat)).font(LatteFont.xs)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: 6)
            }

            LatteDivider()

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "power").font(.system(size: 11))
                    Text("Quit BrewPing").font(LatteFont.xs)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: 6)
        }
        .padding(10)
        .frame(width: 260)
        .background(Latte.background)
    }

    private var runtimeText: String {
        switch app.runtimeState {
        case "online": return i18n.t(.topOnline)
        case "starting": return i18n.t(.topStarting)
        default: return i18n.t(.topOffline)
        }
    }

    private var stateKey: LKey {
        switch app.runtimeState {
        case "online": return .stateOnline
        case "starting": return .stateStarting
        case "offline": return .stateOffline
        default: return .stateIdle
        }
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(LatteFont.font10)
                .foregroundStyle(Latte.mutedForeground)
                .frame(width: 72, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(LatteFont.font10)
                .foregroundStyle(Latte.foreground)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}
