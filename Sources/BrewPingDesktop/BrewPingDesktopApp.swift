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
