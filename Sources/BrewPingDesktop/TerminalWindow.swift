import SwiftUI
import AppKit
import BrewPingCore

/// 以 AppKit 方式按需打开终端窗口。
/// 菜单栏应用（LSUIElement）不适合用 SwiftUI `Window` scene——那会在启动时自动弹窗。
@MainActor
final class TerminalWindowController {
    static let shared = TerminalWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: TerminalWindow())
        let win = NSWindow(contentViewController: hosting)
        win.title = "BrewPing Terminal"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 760, height: 480))
        win.isReleasedWhenClosed = false
        win.center()

        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Multi-Agent Terminal 窗口：真实终端风格
struct TerminalWindow: View {
    @StateObject private var viewModel = TerminalViewModel()
    @ObservedObject private var core = DesktopCore.shared
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

    // 终端配色
    private let bg      = Color(red: 0.06, green: 0.06, blue: 0.06)
    private let barBg   = Color(red: 0.08, green: 0.08, blue: 0.08)
    private let green   = Color(red: 0.30, green: 0.85, blue: 0.40)
    private let dimGreen = Color(red: 0.18, green: 0.50, blue: 0.24)

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Tab 栏
            AgentTabView(
                agents: viewModel.registeredAgents,
                activeAgentID: $viewModel.activeAgentID,
                isOnline: core.isRunning,
                onSelect: { agentId in
                    viewModel.switchToAgent(agentId)
                }
            )

            // MARK: - 终端输出区域
            if let state = currentTerminalState {
                AgentTerminalView(state: state)
            } else {
                noAgentPlaceholder
            }

            // MARK: - 输入栏
            inputBar
        }
        .frame(minWidth: 680, minHeight: 420)
        .background(bg)
    }

    private var currentTerminalState: AgentTerminalState? {
        viewModel.terminalState(for: viewModel.activeAgentID)
    }

    // MARK: - 输入栏

    private var inputBar: some View {
        HStack(spacing: 8) {
            Text("❯")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(green)

            TextField("Type a command...", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
                .tint(green)
                .focused($isInputFocused)
                .onSubmit {
                    sendCommand()
                }

            Button(action: sendCommand) {
                Text("SEND")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(inputText.trimmingCharacters(in: .whitespaces).isEmpty
                        ? dimGreen.opacity(0.5)
                        : green)
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Rectangle()
                .fill(barBg)
                .overlay(
                    Rectangle()
                        .fill(green.opacity(0.12))
                        .frame(height: 1),
                    alignment: .top
                )
        )
    }

    private func sendCommand() {
        let trimmed = inputText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        viewModel.sendInput(trimmed)
        inputText = ""
    }

    // MARK: - 空状态

    private var noAgentPlaceholder: some View {
        VStack(spacing: 10) {
            Text("brewping ❯ ")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(dimGreen)
            Text("No agents available")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(dimGreen.opacity(0.7))
            Text("Install opencode, claude, or codex to get started")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(dimGreen.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bg)
    }
}
