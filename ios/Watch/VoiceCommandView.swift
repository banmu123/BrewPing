import SwiftUI

struct VoiceCommandView: View {
    @ObservedObject var sessionManager: WatchSessionManager
    @State private var commandText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch sessionManager.commandState {
            case .idle:
                idleControls
            case .sending:
                HStack(spacing: 6) {
                    ProgressView()
                    Text("Sending...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .sent(let text):
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "tray.and.arrow.up.fill")
                            .foregroundStyle(.blue)
                        Text("Command Sent")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        ProgressView()
                        Text("Waiting for Mac...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            case .completed(let text):
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(durationSuffix("Completed"))
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("New Command") {
                        sessionManager.commandState = .idle
                        commandText = ""
                    }
                    .font(.caption2)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Text(durationSuffix("Send failed"))
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        sessionManager.commandState = .idle
                    }
                    .font(.caption2)
                }
            }
        }
    }

    private func durationSuffix(_ base: String) -> String {
        if let d = sessionManager.lastCommandDuration {
            return String(format: "%@ · %.1fs", base, d)
        }
        return base
    }

    @ViewBuilder
    private var idleControls: some View {
        TextField("Tap to speak", text: $commandText, axis: .vertical)
            .lineLimit(1...4)
            .font(.caption)
        Button {
            sessionManager.sendCommand(commandText)
        } label: {
            Text("Send")
                .frame(maxWidth: .infinity)
        }
        .disabled(commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
