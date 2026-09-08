import SwiftUI
import WatchKit

struct VoiceCommandView: View {
    @ObservedObject var sessionManager: WatchSessionManager
    @StateObject private var audioRecorder = WatchAudioRecorder()
    @State private var commandText = ""
    @State private var continuousMode = false
    @State private var showTranscribing = false

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
                        Text("Sent")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        ProgressView()
                        Text("Waiting...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if continuousMode {
                        Color.clear.frame(height: 1).onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                startVoiceInput()
                            }
                        }
                    }
                }
            case .completed(let text):
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(durationSuffix("Done"))
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if continuousMode {
                        Color.clear.frame(height: 1).onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                sessionManager.commandState = .idle
                                startVoiceInput()
                            }
                        }
                    } else {
                        Button("New Command") {
                            sessionManager.commandState = .idle
                            commandText = ""
                        }
                        .font(.caption2)
                    }
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Text(durationSuffix("Failed"))
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if continuousMode {
                        Button("Continue") {
                            sessionManager.commandState = .idle
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                startVoiceInput()
                            }
                        }
                        .font(.caption2)
                    } else {
                        Button("Retry") {
                            sessionManager.commandState = .idle
                        }
                        .font(.caption2)
                    }
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

    // MARK: - 空闲状态

    @ViewBuilder
    private var idleControls: some View {
        VStack(spacing: 8) {
            if audioRecorder.isRecording {
                // 正在录音
                recordingView
            } else if showTranscribing {
                // 正在识别
                HStack(spacing: 6) {
                    ProgressView()
                    Text("Recognizing...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                // 录音按钮
                Button {
                    startVoiceInput()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 14))
                        Text(continuousMode ? "Start Listening" : "Speak")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(continuousMode ? Color.green.opacity(0.3) : Color.blue.opacity(0.25))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                // 连续模式开关
                Button {
                    continuousMode.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: continuousMode ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(continuousMode ? .green : .secondary)
                            .font(.system(size: 11))
                        Text("Continuous")
                            .font(.system(size: 10))
                            .foregroundStyle(continuousMode ? .green : .secondary)
                    }
                }
                .buttonStyle(.plain)

                // 文字输入备用
                HStack(spacing: 4) {
                    TextField("Type...", text: $commandText, axis: .vertical)
                        .lineLimit(1...3)
                        .font(.caption2)

                    Button {
                        sendTextCommand()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(commandText.isEmpty ? .gray : .green)
                    }
                    .buttonStyle(.plain)
                    .disabled(commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - 录音中

    private var recordingView: some View {
        VStack(spacing: 6) {
            // 音频电平
            HStack(spacing: 2) {
                ForEach(0..<7, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(barColor(for: i))
                        .frame(width: 3, height: barHeight(for: i))
                }
                Spacer()
                if audioRecorder.hasSpeech {
                    Text("Listening...")
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                } else {
                    Text("Speak now")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            }
            .frame(height: 18)

            // 录音时长提示
            Text("Speak your command — auto-stops when you're quiet")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // 停止按钮
            Button {
                audioRecorder.cancelRecording()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 音频电平条

    private func barHeight(for index: Int) -> CGFloat {
        let normalized = CGFloat(audioRecorder.audioLevel) * 7
        return CGFloat(index) < normalized ? CGFloat(6 + index * 2) : 4
    }

    private func barColor(for index: Int) -> Color {
        let normalized = CGFloat(audioRecorder.audioLevel) * 7
        if CGFloat(index) < normalized {
            return index < 4 ? .green : (index < 6 ? .yellow : .red)
        }
        return .gray.opacity(0.2)
    }

    // MARK: - 语音输入

    private func startVoiceInput() {
        guard sessionManager.reachable else {
            sessionManager.lastError = "iPhone not connected"
            return
        }

        audioRecorder.startRecording { [self] audioData in
            DispatchQueue.main.async {
                guard let audioData else {
                    // 录音失败
                    if continuousMode {
                        continuousMode = false
                    }
                    return
                }
                // 发送音频到 iPhone 识别
                self.showTranscribing = true
                self.sessionManager.sendAudioCommand(audioData)
            }
        }
    }

    // MARK: - 文字发送

    private func sendTextCommand() {
        let trimmed = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessionManager.sendCommand(trimmed)
        commandText = ""
    }
}
