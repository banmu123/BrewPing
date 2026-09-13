import BrewPingCore
import SwiftUI

// ─── 桌面端根视图（App.tsx 的 return 结构）────────────────────────────────────
//
// 结构逐层对齐 Windows：
//   VStack
//   ├── 标题栏条（macOS 交给系统红绿灯，条本身仅作拖拽区）
//   └── HStack
//       ├── Sidebar（悬浮圆角卡片，四周留缝）
//       └── Main（错误条 / 顶栏 / 会话区 / 终端 dock）
//   最外层 overlay：设置弹窗（点遮罩、Esc、✕ 关闭）

struct DesktopRootView: View {
    @EnvironmentObject private var i18n: I18n
    @EnvironmentObject private var app: DesktopAppState

    var body: some View {
        Group {
            if app.loading {
                loadingScreen
            } else {
                content
            }
        }
        .background(Latte.background)
        .frame(minWidth: 520, minHeight: 520)
        .onAppear { app.start() }
    }

    // ─── 启动占位（`.no-agent-placeholder`）──────────────────────────────────

    private var loadingScreen: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                Text("brewping ❯ ").foregroundStyle(Latte.primary.opacity(0.75))
                Text("Starting BrewPing...").foregroundStyle(Latte.outputSystem)
            }
            .font(LatteFont.mono)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Latte.terminalBg)
    }

    // ─── 主结构 ───────────────────────────────────────────────────────────────

    private var content: some View {
        VStack(spacing: 0) {
            WindowDragStrip()

            HStack(spacing: 0) {
                SidebarView()

                // 只在这里量一次主区宽度，注入环境供会话内容列使用 ——
                // 逐处用 GeometryReader 会抢走 VStack 的剩余高度，把 composer 顶飞。
                GeometryReader { proxy in
                    main
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .environment(\.viewportWidth, proxy.size.width)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .overlay {
            if app.settingsOpen {
                SettingsView()
            }
        }
    }

    // ─── 主区域 ───────────────────────────────────────────────────────────────

    private var main: some View {
        VStack(spacing: 0) {
            if let error = app.error {
                errorBanner(error)
            }

            topBar

            ChatView()

            if app.dockOpen {
                TerminalDockView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 派生副作用（模型 / 目录跟随、busy 轮询）在这里挂载后同步一次
        .onAppear { app.syncFollowedState() }
        .onChange(of: app.effectiveAgentId) { _ in app.syncFollowedState() }
        .onChange(of: app.activeConvId) { _ in app.syncFollowedState() }
        .onChange(of: app.isBusy) { _ in app.syncFollowedState() }
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(LatteFont.font10)
            .foregroundStyle(Latte.destructive)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Latte.destructive.opacity(0.10))
            .overlay(alignment: .bottom) { LatteDivider(opacity: 0.35) }
            .onTapGesture { app.error = nil }
    }

    /// 顶栏：与内容同底色、无分隔线，标题随对话自动生成。
    private var topBar: some View {
        HStack(spacing: 8) {
            Text(app.activeConv?.title ?? i18n.t(.topNewChat))
                .font(LatteFont.sm.weight(.medium))
                .foregroundStyle(Latte.foreground)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(app.convAgentName)
                .font(LatteFont.font10)
                .foregroundStyle(Latte.secondaryForeground.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Latte.secondary)
                .clipShape(Capsule())
                .fixedSize()

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                RuntimeDot(state: app.runtimeState)
                Text(runtimeText)
                    .font(LatteFont.font10)
                    .foregroundStyle(Latte.mutedForeground)
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(height: LatteMetrics.headerHeight)
    }

    private var runtimeText: String {
        switch app.runtimeState {
        case "online": return i18n.t(.topOnline)
        case "starting": return i18n.t(.topStarting)
        default: return i18n.t(.topOffline)
        }
    }
}
