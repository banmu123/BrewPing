import SwiftUI
import BrewPingCore

/// Agent 终端输出视图：真实终端风格，绿色磷光屏
struct AgentTerminalView: View {
    @ObservedObject var state: AgentTerminalState

    // MARK: - 终端配色
    private let bg      = Color(red: 0.06, green: 0.06, blue: 0.06)       // #0F0F0F
    private let green   = Color(red: 0.30, green: 0.85, blue: 0.40)       // 终端绿
    private let dimGreen = Color(red: 0.18, green: 0.50, blue: 0.24)      // 暗绿
    private let amber   = Color(red: 1.00, green: 0.72, blue: 0.30)       // 错误琥珀
    private let cyan    = Color(red: 0.40, green: 0.80, blue: 1.00)       // 系统青
    private let promptStr = "brewping ❯ "

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // 主输出区域
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if state.outputLines.isEmpty {
                            emptyPlaceholder
                        } else {
                            ForEach(state.outputLines) { line in
                                outputLineView(line)
                                    .id(line.id)
                            }
                        }
                        // 闪烁光标
                        blinkingCursor
                            .id("cursor")
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: state.outputLines.count) { _ in
                    if let lastLine = state.outputLines.last {
                        withAnimation(.easeOut(duration: 0.05)) {
                            proxy.scrollTo(lastLine.id, anchor: .bottom)
                        }
                    }
                }
            }

            // 扫描线叠加层
            scanlineOverlay
                .allowsHitTesting(false)
        }
        .background(bg)
    }

    // MARK: - 空状态

    private var emptyPlaceholder: some View {
        VStack(spacing: 12) {
            Text(promptStr)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(dimGreen)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Waiting for commands...")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(dimGreen.opacity(0.7))
            Text("Send a message from iPhone or Watch")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(dimGreen.opacity(0.5))

            Text("═══════════════════════════════════════")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(dimGreen.opacity(0.15))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
    }

    // MARK: - 输出行

    @ViewBuilder
    private func outputLineView(_ line: OutputLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if line.type == .system {
                // 系统消息 — 青色
                Text(line.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(systemColor(for: line))
            } else if line.text.hasPrefix("> ") {
                // 用户输入行 — 带绿色 prompt
                Text(promptStr)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(green)
                Text(String(line.text.dropFirst(2)))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.92))
            } else {
                Text(line.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(textColor(for: line.type))
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 0.5)
    }

    // MARK: - 闪烁光标

    private var blinkingCursor: some View {
        Text("█")
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(green)
            .opacity(state.status == .running ? 1 : 0.8)
            .animation(
                state.status == .running
                    ? .easeInOut(duration: 0.4).repeatForever(autoreverses: true)
                    : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: UUID() // 触发持续动画
            )
    }

    // MARK: - 扫描线

    private var scanlineOverlay: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let lineSpacing: CGFloat = 3
                var y: CGFloat = 0
                while y < size.height {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(.black.opacity(0.06)), lineWidth: 1)
                    y += lineSpacing
                }
            }
        }
        .opacity(0.5)
    }

    // MARK: - 颜色

    private func systemColor(for line: OutputLine) -> Color {
        if line.text.contains("[iOS]") || line.text.contains("[Watch]") {
            return cyan
        }
        return dimGreen.opacity(0.8)
    }

    private func textColor(for type: OutputType) -> Color {
        switch type {
        case .normal:  return green.opacity(0.85)
        case .error:   return amber
        case .system:  return dimGreen.opacity(0.8)
        }
    }
}
