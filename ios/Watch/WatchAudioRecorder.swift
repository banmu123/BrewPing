import Foundation
import AVFoundation

/// 录音失败原因：用于把具体失败环节回显到 Watch UI，
/// 避免所有失败都表现为同一句 "No audio recorded" 而无法定位。
enum WatchRecorderError: LocalizedError {
    case audioSession(String)
    case recorderCreation(String)
    case encodeFailed
    case emptyRecording

    var errorDescription: String? {
        switch self {
        case .audioSession(let detail):  return LW("Audio session failed: %@", detail)
        case .recorderCreation(let detail): return LW("Recorder failed: %@", detail)
        case .encodeFailed:              return LW("Audio encoding failed")
        case .emptyRecording:            return LW("No audio captured")
        }
    }
}

/// Watch 端录音器：点击录音 + 静音自动停止。
///
/// 产物是一个落盘的 `.m4a` 文件（而非内存 Data）：
/// WatchConnectivity 的 `sendMessage` 载荷上限只有约 65 KB，
/// 音频必须走 `transferFile` 才能可靠送达 iOS。
/// 文件所有权交给调用方（WatchSessionManager），
/// 在 `session(_:didFinish:)` 传输结束后由发送方删除。
final class WatchAudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var audioLevel: Float = 0
    @Published var hasSpeech = false

    private var recorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private var silenceTimer: Timer?
    private var completion: ((Result<URL, WatchRecorderError>) -> Void)?
    private var finished = false
    private var currentURL: URL?

    /// 静音判定阈值（dBFS）。
    /// 腕上麦克风在正常说话距离下的 `averagePower` 多在 -35 ~ -20 dB，
    /// 原值 -20 dB 偏高，轻声说话时 `hasSpeech` 永远不会置位，
    /// 静音自动停止因此永不触发。
    private let levelThreshold: Float = -35.0
    /// 连续多少个 100ms 采样高于阈值才认定“开始说话”，避免单次爆音误判。
    private let speechOnsetFrames = 2
    private var voicedFrameCount = 0

    private let silenceTimeout: TimeInterval = 1.2
    /// 录音硬上限：超时强制停止，保证一定会回调。
    private let maxDuration: TimeInterval = 12.0

    private let filePrefix = "brewping_cmd_"

    // MARK: - 录音控制

    /// 开始录音。完成（手动 / 静音 / 超时）后回调音频文件 URL。
    /// 文件不会被自动删除，由调用方在传输完成后清理。
    func startRecording(completion: @escaping (Result<URL, WatchRecorderError>) -> Void) {
        self.completion = completion
        finished = false
        hasSpeech = false
        voicedFrameCount = 0
        audioLevel = 0

        purgeStaleFiles()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filePrefix)\(UUID().uuidString).m4a")
        currentURL = url

        // 注意：`.duckOthers` 仅对 playAndRecord / playback / ambient / multiRoute 有效，
        // 与 `.record` 组合属于非法选项，setCategory 会抛错并使整段录音直接失败。
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
        } catch {
            // `.measurement` 不可用时退回默认模式，尽量不因模式问题整体失败
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .default)
                try session.setActive(true)
            } catch {
                WatchLog.audio.error("Audio session failed: \(error.localizedDescription, privacy: .private)")
                finish(.failure(.audioSession(error.localizedDescription)))
                return
            }
        }

        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            WatchLog.audio.error("Recorder creation failed: \(error.localizedDescription, privacy: .private)")
            try? AVAudioSession.sharedInstance().setActive(false)
            finish(.failure(.recorderCreation(error.localizedDescription)))
            return
        }

        recorder?.delegate = self
        recorder?.isMeteringEnabled = true
        guard recorder?.record() == true else {
            WatchLog.audio.error("record() returned false")
            try? AVAudioSession.sharedInstance().setActive(false)
            finish(.failure(.recorderCreation("record() returned false")))
            return
        }

        isRecording = true
        startLevelMonitoring()

        // 安全超时：即使静音检测未触发，也必须在 maxDuration 内结束并回调
        DispatchQueue.main.asyncAfter(deadline: .now() + maxDuration) { [weak self] in
            guard let self, self.isRecording else { return }
            WatchLog.audio.info("Force stop after \(self.maxDuration, privacy: .public)s timeout")
            self.stopRecording()
        }

        WatchLog.audio.info("Recording started -> \(url.lastPathComponent, privacy: .private)")
    }

    /// 手动停止录音（delegate 的 audioRecorderDidFinishRecording 负责回调）
    func stopRecording() {
        guard isRecording else { return }
        stopLevelMonitoring()
        recorder?.stop()
    }

    func cancelRecording() {
        stopLevelMonitoring()
        // 必须先失效回调：`stop()` 可能同步回调 delegate，
        // 若先 stop 再置空，被取消的录音会被当成正常结果发出去。
        completion = nil
        finished = true
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        isRecording = false
        audioLevel = 0
        if let url = currentURL {
            try? FileManager.default.removeItem(at: url)
        }
        currentURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - 音量监控 + 静音检测

    private func startLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateLevel()
        }
    }

    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    private func updateLevel() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)

        // -50dB → 0.0,  0dB → 1.0
        let normalized = max(0, min(1, (power + 50) / 50))
        audioLevel = normalized

        if power > levelThreshold {
            voicedFrameCount += 1
            if voicedFrameCount >= speechOnsetFrames {
                hasSpeech = true
                resetSilenceTimer()
            }
        } else {
            voicedFrameCount = 0
            if hasSpeech {
                // 说过话后进入静音，开始计时
                startSilenceTimerIfNeeded()
            }
            // 如果从未说过话，不触发静音停止（等用户说话，由 maxDuration 兜底）
        }
    }

    private func startSilenceTimerIfNeeded() {
        guard silenceTimer == nil else { return }
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
            self?.stopRecording()
        }
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    // MARK: - 收尾

    /// 保证回调只发生一次
    private func finish(_ result: Result<URL, WatchRecorderError>) {
        guard !finished else { return }
        finished = true
        stopLevelMonitoring()
        isRecording = false
        audioLevel = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let block = completion
        completion = nil
        block?(result)
    }

    /// 清理上次可能残留（传输失败 / 进程被杀）的录音文件
    private func purgeStaleFiles() {
        let dir = FileManager.default.temporaryDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-600)
        for item in items where item.lastPathComponent.hasPrefix(filePrefix) {
            let created = (try? item.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < cutoff {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    // MARK: - AVAudioRecorderDelegate

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        WatchLog.audio.info("didFinishRecording successfully=\(flag, privacy: .public)")
        stopLevelMonitoring()

        guard flag else {
            WatchLog.audio.error("Recording failed")
            finish(.failure(.encodeFailed))
            return
        }

        guard let url = currentURL, FileManager.default.fileExists(atPath: url.path) else {
            finish(.failure(.emptyRecording))
            return
        }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        WatchLog.audio.info("Audio file size = \(size, privacy: .public) bytes")
        guard size > 0 else {
            try? FileManager.default.removeItem(at: url)
            finish(.failure(.emptyRecording))
            return
        }

        finish(.success(url))
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        WatchLog.audio.error("Encode error: \(error?.localizedDescription ?? "unknown", privacy: .private)")
        finish(.failure(.encodeFailed))
    }

    // MARK: - 录音参数

    /// 16 kHz 单声道 AAC，语音识别足够且体积可控。
    private let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        AVEncoderBitRateKey: 32000
    ]
}
