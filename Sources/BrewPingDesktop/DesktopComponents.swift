import BrewPingCore
import SwiftUI

// ─── 共用小部件（拿铁主题的原子组件）────────────────────────────────────────────
//
// 对应 Windows 侧 `app.css` 里的 `.runtime-dot` / `.status-dot` / `.thinking-dot`
// 与 shadcn/ui 的 Button / Badge 变体。

// MARK: - 运行时状态点

/// `.runtime-dot.online / .starting / .offline`
struct RuntimeDot: View {
    var state: String
    var size: CGFloat = 6

    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(state == "starting" ? (pulse ? 1 : 0.25) : 1)
            .onAppear {
                guard state == "starting" else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }

    private var color: Color {
        switch state {
        case "online": return Latte.success
        case "starting": return Latte.mutedForeground.opacity(0.55)
        default: return Latte.destructive
        }
    }
}

/// `.runtime-label`
struct RuntimeLabel: View {
    var state: String
    var text: String
    var font: Font = LatteFont.font9

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
    }

    private var color: Color {
        switch state {
        case "online": return Latte.success
        case "starting": return Latte.mutedForeground.opacity(0.75)
        default: return Latte.destructive
        }
    }
}

/// 「正在思考」占位指示点（`.thinking-dot`）
struct ThinkingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Latte.primary)
            .frame(width: 6, height: 6)
            .opacity(pulse ? 1 : 0.25)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

// MARK: - 按钮

/// shadcn/ui 的 Button 变体（default / outline / ghost）与 size（sm）。
struct LatteButtonStyle: ButtonStyle {
    enum Variant { case primary, outline, ghost }

    var variant: Variant = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LatteFont.sm)
            .foregroundStyle(foreground(configuration))
            .background(background(configuration))
            .overlay {
                if variant == .outline {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Latte.border, lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed && variant == .primary ? 0.9 : 1)
    }

    private func foreground(_ config: Configuration) -> Color {
        switch variant {
        case .primary: return Latte.primaryForeground
        case .outline, .ghost: return Latte.foreground
        }
    }

    private func background(_ config: Configuration) -> Color {
        switch variant {
        case .primary: return Latte.primary
        case .outline: return Latte.background
        case .ghost: return config.isPressed ? Latte.accent : .clear
        }
    }
}

/// Badge 变体（env 卡片用）。
struct LatteBadge: View {
    enum Variant { case success, warning, muted }

    var variant: Variant
    var text: String

    var body: some View {
        Text(text)
            .font(LatteFont.font9)
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 0)
            .background(background)
            .clipShape(Capsule())
    }

    private var foreground: Color {
        switch variant {
        case .success: return Latte.success
        case .warning: return Latte.warning
        case .muted: return Latte.mutedForeground
        }
    }

    private var background: Color {
        switch variant {
        case .success: return Latte.success.opacity(0.12)
        case .warning: return Latte.warning.opacity(0.12)
        case .muted: return Latte.muted
        }
    }
}

// MARK: - 分隔线

struct LatteDivider: View {
    var opacity: Double = 1
    var body: some View {
        Rectangle()
            .fill(Latte.border.opacity(opacity))
            .frame(height: 1)
    }
}

// MARK: - 悬停高亮（`.hover:bg-accent`）

/// 给任意行套上「悬停浅棕面」的行为，等价于 CSS 的 `hover:bg-accent`。
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = 6
    var enabled: Bool = true
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(hovering && enabled ? Latte.accent : .clear)
            )
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = 6, enabled: Bool = true) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, enabled: enabled))
    }
}

// MARK: - 整窗拖拽条

/// Windows 无边框窗口自绘的标题栏条（`h-7`）。macOS 上保留同高度的**可拖拽条**，
/// 但窗口控制交给系统红绿灯按钮 —— 这是 macOS 的平台惯例，也是唯一的取舍点。
struct WindowDragStrip: View {
    var body: some View {
        ZStack {
            Latte.background
            DraggableArea()
        }
        .frame(height: LatteMetrics.titleBarHeight)
    }
}

private struct DraggableArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}
