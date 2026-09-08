import Foundation
import AVFoundation

/// Watch 端录音器：点击录音 + 静音自动停止
final class WatchAudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var audioLevel: Float = 0
    @Published var hasSpeech = false

    private var recorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private var silenceTimer: Timer?
    private var completion: ((Data?) -> Void)?

    private let silenceTimeout: TimeInterval = 1.5
    private let levelThreshold: Float = -20.0 // dB

    private let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("breping_cmd.m4a")

    private let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.low.rawValue,
        AVEncoderBitRateKey: 16000
    ]

    // MARK: - 录音控制

    /// 开始录音，完成后回调音频数据（AAC m4a）
    func startRecording(completion: @escaping (Data?) -> Void) {
        self.completion = completion
        hasSpeech = false

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true)

            recorder = try AVAudioRecorder(url: tempURL, settings: settings)
            recorder?.delegate = self
            recorder?.isMeteringEnabled = true
            recorder?.record()

            isRecording = true
            startLevelMonitoring()
        } catch {
            print("WatchAudioRecorder: start failed - \(error)")
            completion(nil)
        }
    }

    /// 手动停止录音
    func stopRecording() {
        guard isRecording else { return }
        stopLevelMonitoring()
        recorder?.stop()
        // delegate 的 audioRecorderDidFinishRecording 会处理后续
    }

    func cancelRecording() {
        stopLevelMonitoring()
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        isRecording = false
        completion = nil
        try? AVAudioSession.sharedInstance().setActive(false)
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
            // 检测到声音
            hasSpeech = true
            resetSilenceTimer()
        } else if hasSpeech {
            // 说过话后进入静音，开始计时
            startSilenceTimerIfNeeded()
        }
        // 如果从未说过话，不触发静音停止（等用户说话）
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

    // MARK: - AVAudioRecorderDelegate

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        stopLevelMonitoring()
        isRecording = false
        audioLevel = 0

        guard flag else {
            completion?(nil)
            completion = nil
            try? AVAudioSession.sharedInstance().setActive(false)
            return
        }

        let data = try? Data(contentsOf: tempURL)
        try? FileManager.default.removeItem(at: tempURL)
        try? AVAudioSession.sharedInstance().setActive(false)

        completion?(data)
        completion = nil
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        print("WatchAudioRecorder: encode error - \(error?.localizedDescription ?? "unknown")")
        stopLevelMonitoring()
        isRecording = false
        audioLevel = 0
        completion?(nil)
        completion = nil
    }
}
