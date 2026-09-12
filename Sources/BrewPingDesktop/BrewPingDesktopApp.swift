import AppKit
import BrewPingCore
import SwiftUI

// ─── BrewPing Desktop（macOS）──────────────────────────────────────────────────
//
// 与 Windows 桌面端的形态对齐：**一个主窗口**承载全部交互（侧栏 + 会话 + 终端 dock
// + 设置弹窗），不再是纯菜单栏应用。
//
// macOS 平台适配（唯一的形态差异）：
//   · 主窗口用系统标题栏（`.hiddenTitleBar` → 红绿灯浮在 28pt 拖拽条上），
//     不做 Windows 那样的自绘最小化/最大化/关闭按钮 —— 这是 macOS 的窗口惯例；
//   · 保留一个菜单栏项，承担 Windows **托盘**的职责（查看状态 / 显示配对码 /
//     打开主窗口 / 退出）。

@main
struct BrewPingDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var core = DesktopCore.shared
    @StateObject private var i18n = I18n()
    @StateObject private var app = DesktopAppState.shared

    var body: some Scene {
        Window("BrewPing", id: "main") {
            DesktopRootView()
                .environmentObject(i18n)
                .environmentObject(app)
                .background(Latte.background)
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1080, height: 720)

        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(i18n)
                .environmentObject(app)
                .environmentObject(core)
        } label: {
            Label("BrewPing", systemImage: "cup.and.saucer.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

/// 负责进程级生命周期：启动 HTTP 服务 / Bonjour 广播 / Agent 发现。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            DesktopCore.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            DesktopCore.shared.stop()
        }
    }

    /// 关闭主窗口不退出进程（菜单栏项仍在）；这是 macOS 上「桌面端常驻」的惯例，
    /// 也与 Windows 端托盘常驻的语义一致。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
