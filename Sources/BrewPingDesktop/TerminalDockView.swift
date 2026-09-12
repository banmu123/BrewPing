import BrewPingCore
import SwiftUI

// ─── 终端 dock（可折叠；per-agent 原始输出，旁路角色）──────────────────────────
//
// 对齐 App.tsx 的终端区与 `app.css` 的 `.terminal-output` / `.output-line` /
// `.blinking-cursor` / `.scanline-overlay` / `.terminal-empty` / `.no-agent-placeholder`。

struct TerminalDockView: View {
    @EnvironmentObject private var i18n: I18n
    @EnvironmentObject private var app: DesktopAppState

    @State private var cursorVisible = true

    var body: some View {
        VStack(spacing: 0) {
            header

            if let terminal = app.activeTerminal {
                outputArea(terminal)
            } else {
                placeholder
            }
        }
        .frame(height: 224)
        .background(Latte.card)
        .overlay(alignment: .top) { LatteDivider() }
    }

    // MARK: 标题行

    private var header: some View {
        HStack(spacing: 0) {
            Text(i18n.t(.barTerminalOf, ["agent": app.convAgentName]))
                .font(LatteFont.font10.weight(.semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Latte.mutedForeground)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Button {
                    Task { await app.clearTerminal() }
                } label: {
                    Text(i18n.t(.commonClear))
                        .font(LatteFont.xs)
                        .foregroundStyle(Latte.foreground)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: 6)

                Button {
                    app.dockOpen = false
                } label: {
                    Text(i18n.t(.commonCollapse))
                        .font(LatteFont.xs)
                        .foregroundStyle(Latte.foreground)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: 6)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .overlay(alignment: .bottom) { LatteDivider(opacity: 0.6) }
    }

    // MARK: 输出区

    private func outputArea(_ terminal: TerminalAgentStateDTO) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    if terminal.outputLines.isEmpty {
                        terminalEmpty
                    } else {
                        ForEach(terminal.outputLines) { line in
                            OutputLineView(line: line)
                        }
                    }

                    Text("█")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Latte.primary)
                        .opacity(cursorVisible ? 0.8 : 0.2)

                    Color.clear.frame(height: 1).id("terminalBottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
            .background(Latte.terminalBg)
            .overlay {
                // `.scanline-overlay`：极淡的暖棕扫描线
                ScanlineOverlay()
                    .allowsHitTesting(false)
            }
            .onChange(of: terminal.outputLines.count) { _ in
                proxy.scrollTo("terminalBottom", anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo("terminalBottom", anchor: .bottom)
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    cursorVisible = false
                }
            }
        }
    }

    private var terminalEmpty: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("brewping ❯ ")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Latte.primary.opacity(0.75))
            Text("Waiting for commands...")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Latte.mutedForeground.opacity(0.9))
            Text("Send a message from iPhone or Watch")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Latte.mutedForeground.opacity(0.65))
            Text("═══════════════════════════════════════")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Latte.mutedForeground.opacity(0.25))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Text("brewping ❯ ")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Latte.primary.opacity(0.75))
            Text("No agents available")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Latte.outputSystem)
            Text("Install opencode, claude, or codex to get started")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Latte.mutedForeground.opacity(0.65))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Latte.terminalBg)
    }
}

// MARK: - 输出行

private struct OutputLineView: View {
    var line: TerminalLineDTO

    private var isUserInput: Bool { line.type == "system" && line.text.hasPrefix("> ") }
    private var isRemote: Bool { line.text.contains("[iOS]") || line.text.contains("[Watch]") }

    var body: some View {
        if isUserInput {
            HStack(alignment: .top, spacing: 0) {
                Text("brewping ❯ ")
                    .font(.system(size: 12, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Latte.primary)
                Text(String(line.text.dropFirst(2)))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Latte.outputUserInput)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 0.5)
        } else {
            Text(line.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 0.5)
        }
    }

    private var color: Color {
        switch line.type {
        case "error": return Latte.warning
        case "system": return isRemote ? Latte.outputRemote : Latte.outputSystem
        default: return Latte.outputNormal
        }
    }
}

// MARK: - 扫描线

private struct ScanlineOverlay: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            while y < size.height {
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                    with: .color(Latte.outputNormal.opacity(0.025))
                )
                y += 3
            }
        }
        .opacity(0.5)
    }
}
