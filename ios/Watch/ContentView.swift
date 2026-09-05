import SwiftUI
import WatchConnectivity

@main
struct BrewPingWatchApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var sessionManager = WatchSessionManager()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("BrewPing")
                    .font(.headline)
                HStack(spacing: 4) {
                    Circle()
                        .fill(sessionManager.reachable ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(sessionManager.reachable ? Color.secondary : Color.red)
                }
                if let error = sessionManager.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                Button {
                    sessionManager.sendTest()
                } label: {
                    Text("Send Test")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!sessionManager.reachable)
                if let sent = sessionManager.lastSentText {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last:")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(sent)
                            .font(.caption)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .onAppear {
            sessionManager.activate()
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("-brewping-auto-send") {
                await sessionManager.autoSendTest()
            }
        }
    }

    private var statusText: String {
        if sessionManager.activationState != .activated {
            return "Connecting..."
        }
        return sessionManager.reachable ? "Connected" : "iPhone App Not Connected"
    }
}
