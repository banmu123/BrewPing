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
                if sessionManager.reachable {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(macDotColor)
                            .frame(width: 8, height: 8)
                        Text(macStatusText)
                            .font(.caption2)
                            .foregroundStyle(macDotColor == Color.green ? Color.secondary : Color.red)
                    }
                    if let state = sessionManager.sessionState {
                        Text("Session: \(state == "running" ? "Running" : "Stopped")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    VoiceCommandView(sessionManager: sessionManager)
                }
                if let error = sessionManager.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
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
            if ProcessInfo.processInfo.arguments.contains("-brewping-auto-command") {
                await sessionManager.autoCommandTest()
            }
        }
    }

    private var statusText: String {
        if sessionManager.activationState != .activated {
            return "Connecting..."
        }
        return sessionManager.reachable ? "Connected" : "iPhone App Not Connected"
    }

    private var macDotColor: Color {
        switch (sessionManager.macConnected, sessionManager.sessionState) {
        case (true, "running"): return .green
        case (true, _): return .orange
        case (_, _): return .red
        }
    }

    private var macStatusText: String {
        if sessionManager.agentMode != "session" {
            return "Mac: \(sessionManager.agentName) Ready"
        }
        switch (sessionManager.macConnected, sessionManager.sessionState) {
        case (true, "running"): return "Mac: \(sessionManager.agentName) Running"
        case (true, _): return "Mac: Session Stopped"
        case (_, _): return "Mac: Offline"
        }
    }
}
