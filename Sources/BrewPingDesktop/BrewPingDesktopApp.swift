import SwiftUI
import BrewPingCore

@main
struct BrewPingDesktopApp: App {
    @StateObject private var core = DesktopCore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(core: core)
        } label: {
            Label("BrewPing", systemImage: "cup.and.saucer.fill")
        }
        .menuBarExtraStyle(.window)

        Settings {
            EmptyView()
        }
    }
}

/// 管理终端窗口的单例
final class TerminalWindowManager {
    static let shared = TerminalWindowManager()
    private var window: NSWindow?

    func showTerminal() {
        if let window = window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = TerminalWindow()
        let hostingView = NSHostingView(rootView: contentView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BrewPing Terminal"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func closeTerminal() {
        window?.close()
    }
}
