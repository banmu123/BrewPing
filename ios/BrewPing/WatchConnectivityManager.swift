import Foundation
import WatchConnectivity
import Combine
import Speech
import AVFoundation

final class WatchConnectivityManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchConnectivityManager()

    @Published var lastReceivedText: String?
    @Published var lastReceivedType: String?
    var currentOnline: Bool?
    var currentSessionState: String?
    var currentAgentName: String = "OpenCode"
    var currentAgentMode: String = "session"
    var currentAgentID: String = "opencode"
    var knownAgents: [[String: String]] = [
        ["id": "opencode", "name": "OpenCode"],
        ["id": "claude-code", "name": "Claude"],
        ["id": "codex", "name": "Codex"]
    ]
    var knownDevices: [[String: String]] = []
    var activeDeviceID: String = ""
    /// 当前 Agent 的可切换模型（由 ContentView 从 ModelStore 同步过来）。
    /// 与 agents 走同一条通道，手表不自己发请求。
    var knownModels: [[String: String]] = []
    var activeModelID: String = ""

    /// App 是否在前台（由 ContentView 按 `scenePhase` 维护）。
    /// 用于决定"收到手表语音后要不要在本机回放一遍"：
    /// 后台被唤醒时用户并不在看界面，突然外放只会让人困惑。
    var appIsActive = false

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func pushStatus(online: Bool, sessionStateRaw: String, agentName: String? = nil, agentMode: String? = nil) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        let activated = session.activationState == .activated
        let paired = session.isPaired
        let name = agentName ?? currentAgentName
        let mode = agentMode ?? currentAgentMode
        guard activated, paired else { return }
        do {
            try session.updateApplicationContext([
                "macConnected": online,
                "sessionState": sessionStateRaw,
                "agentName": name,
                "agentMode": mode,
                "agents": knownAgents,
                "activeAgent": currentAgentID,
                "devices": knownDevices,
                "activeDevice": activeDeviceID,
                "models": knownModels,
                "activeModelId": activeModelID,
                // 语言偏好：手表照抄 iPhone 的设置，避免两端各维护一份。
                LanguageManager.syncKey: UserDefaults.standard
                    .string(forKey: LanguageManager.storageKey) ?? AppLanguage.system.rawValue
            ])
        } catch {
            BrewPingLog.watch.error("Status push failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// 用户刚在 iPhone 上换了语言时立刻推一次，不必等下一轮状态轮询。
    func pushLanguage() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired else { return }
        let value = UserDefaults.standard.string(forKey: LanguageManager.storageKey)
            ?? AppLanguage.system.rawValue
        do {
            var context = session.applicationContext
            context["macConnected"] = session.applicationContext["macConnected"] ?? false
            context[LanguageManager.syncKey] = value
            try session.updateApplicationContext(context)
        } catch {
            BrewPingLog.watch.error("Language push failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func sendCommandResult(status: String, text: String, duration: Double? = nil) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            BrewPingLog.watch.error("Session not activated, command result dropped: \(status, privacy: .public)")
            return
        }
        var message: [String: Any] = [
            "type": "commandResult",
            "status": status,
            "text": text
        ]
        if let duration { message["duration"] = duration }

        // Watch App 不在前台时 sendMessage 必然失败，
        // 原来直接丢弃结果，手表会永远停在 "Waiting..."——
        // 改用 transferUserInfo 排队，在手表 App 下次运行时送达。
        guard session.isReachable else {
            session.transferUserInfo(message)
            BrewPingLog.watch.info("Watch not reachable, queued command result: \(status, privacy: .public)")
            return
        }
        session.sendMessage(message, replyHandler: nil) { error in
            BrewPingLog.watch.error("Command result push failed (\(error.localizedDescription, privacy: .private)), queuing instead")
            session.transferUserInfo(message)
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            BrewPingLog.watch.error("WCSession activation error: \(error.localizedDescription, privacy: .private)")
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        session.activate()
    }

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleWatchMessage(message, replyHandler: nil)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        handleWatchMessage(message, replyHandler: replyHandler)
    }

    /// Watch 在 `isReachable == false` 时改用 transferUserInfo 排队投递，这里接收。
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleWatchMessage(userInfo, replyHandler: nil)
    }

    /// 收到 Watch 传来的音频文件。
    ///
    /// 关键约束：`file.fileURL` 指向系统的临时位置，
    /// **本方法返回后系统就会删除该文件**，所以必须在这里同步搬走，
    /// 不能把 fileURL 直接交给异步的语音识别流程（否则识别必然失败）。
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata ?? [:]
        let type = metadata["type"] as? String ?? ""
        guard type == "audioCommand" else {
            BrewPingLog.watch.error("Ignoring unexpected file transfer type=\(type, privacy: .public)")
            return
        }

        let ext = file.fileURL.pathExtension.isEmpty ? "m4a" : file.fileURL.pathExtension
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch_audio_\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: file.fileURL, to: localURL)
        } catch {
            BrewPingLog.watch.error("Failed to persist incoming audio: \(error.localizedDescription, privacy: .private)")
            sendCommandResult(status: "failed", text: "Audio save failed")
            return
        }

        let agentId = metadata["agentId"] as? String
        let localeId = metadata["locale"] as? String
        let sourceName = metadata["fileName"] as? String ?? file.fileURL.lastPathComponent
        let size = (try? localURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        BrewPingLog.watch.info("Audio file received \(sourceName, privacy: .private) (\(size, privacy: .public) bytes)")

        // 前台时把收到的语音原样回放一遍：
        // 这是用户唯一能"听到"录音确实完整送达的方式（识别结果只是文字）。
        // 后台唤醒不回放，避免用户看不到界面却突然外放。
        if appIsActive {
            WatchAudioPlayback.shared.play(localURL, label: sourceName)
        }

        transcribeAndForward(audioURL: localURL, agentId: agentId, localeIdentifier: localeId)
    }

    private func handleWatchMessage(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?) {
        let type = message["type"] as? String ?? "unknown"
        if type == "switchDevice" {
            guard let deviceId = message["deviceId"] as? String else {
                replyHandler?(["ok": false, "error": "missing deviceId"])
                return
            }
            BrewPingLog.watch.info("Watch switching to device \(deviceId, privacy: .private)")
            DispatchQueue.main.async {
                DeviceStore.shared.setActive(deviceId)
            }
            replyHandler?(["ok": true, "type": "ack"])
            return
        }
        if type == "requestStatus" {
            BrewPingLog.watch.debug("Watch requested status")
            replyHandler?([
                "macConnected": currentOnline ?? false,
                "sessionState": currentSessionState ?? "",
                "agentName": currentAgentName,
                "agentMode": currentAgentMode,
                "agents": currentAgentList(),
                "activeAgent": currentActiveAgentID,
                "devices": knownDevices,
                "activeDevice": activeDeviceID,
                "models": knownModels,
                "activeModelId": activeModelID,
                LanguageManager.syncKey: UserDefaults.standard
                    .string(forKey: LanguageManager.storageKey) ?? AppLanguage.system.rawValue
            ])
            return
        }
        if type == "switchAgent" {
            guard let agentId = message["agentId"] as? String else {
                replyHandler?(["ok": false, "error": "missing agentId"])
                return
            }
            BrewPingLog.watch.info("Watch switching to agent \(agentId, privacy: .public)")
            replyHandler?(["ok": true, "type": "ack"])
            switchMacAgent(to: agentId)
            return
        }
        if type == "switchModel" {
            guard let modelId = message["modelId"] as? String else {
                replyHandler?(["ok": false, "error": "missing modelId"])
                return
            }
            // agentId 可省略：手表切换的是"当前 Agent 的模型"，缺省用当前值。
            let agentId = (message["agentId"] as? String) ?? currentAgentID
            BrewPingLog.watch.info("Watch switching model to \(modelId, privacy: .public)")
            replyHandler?(["ok": true, "type": "ack"])
            switchMacModel(to: modelId, agentId: agentId)
            return
        }
        if type == "command" {
            let text = (message["text"] as? String) ?? (message["content"] as? String) ?? ""
            let agentId = message["agentId"] as? String
            BrewPingLog.command.info("Command received from Watch, agent=\(agentId ?? "default", privacy: .public)")
            replyHandler?(["ok": true, "type": "ack"])
            ensureAgentThenForward(text: text, agentId: agentId)
            return
        }
        if type == "audioCommand" {
            // 兼容旧版 Watch：把音频塞进 sendMessage 的字典里。
            // 该通道载荷上限约 65 KB，稍长的录音就会被系统拒绝，
            // 因此新版本已改用 transferFile（见 session(_:didReceive:)）。
            guard let audioData = message["audio"] as? Data, !audioData.isEmpty else {
                BrewPingLog.watch.error("audioCommand missing audio data (payload dropped or too large)")
                replyHandler?(["ok": false, "error": "no audio data"])
                sendCommandResult(status: "failed", text: "Audio payload missing or too large")
                return
            }
            let agentId = message["agentId"] as? String
            BrewPingLog.watch.info("Legacy inline audio command (\(audioData.count, privacy: .public) bytes)")
            let localURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("watch_audio_\(UUID().uuidString).m4a")
            do {
                try audioData.write(to: localURL)
            } catch {
                BrewPingLog.watch.error("Failed to write audio: \(error.localizedDescription, privacy: .private)")
                replyHandler?(["ok": false, "error": "cannot persist audio"])
                sendCommandResult(status: "failed", text: "Audio save failed")
                return
            }
            replyHandler?(["ok": true, "type": "ack"])
            transcribeAndForward(audioURL: localURL, agentId: agentId)
            return
        }
        let text = message["text"] as? String ?? ""
        BrewPingLog.watch.debug("Received from Watch: \(text, privacy: .private)")
        CommandReceiver.shared.receive(type: .status, text: text)
        DispatchQueue.main.async {
            self.lastReceivedType = type
            self.lastReceivedText = text
        }
        replyHandler?(["ok": true, "type": "ack"])
    }

    // MARK: - Active Device Resolution

    /// 在主线程读取当前生效设备。
    /// Watch 回调来自 WCSession 的后台队列，而 DeviceStore 是 @MainActor，
    /// 因此所有对 DeviceStore 的读取都统一切回主线程。
    private func onMainWithActiveDevice(_ body: @escaping (ManagedDevice?) -> Void) {
        Task { @MainActor in
            body(DeviceStore.shared.activeDevice)
        }
    }

    /// 切换 Mac 端的 active Agent
    private func switchMacAgent(to agentId: String) {
        onMainWithActiveDevice { device in
            guard let device,
                  var request = BrewPingHTTP.request(
                    device: device,
                    path: "/api/agents/\(agentId)/switch",
                    method: "POST",
                    timeout: 10
                  ) else {
                BrewPingLog.watch.info("No active device, skip switch to \(agentId, privacy: .public)")
                return
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            Task {
                do {
                    let (data, response) = try await BrewPingHTTP.session.data(for: request)
                    if BrewPingHTTP.isUnauthorized(response) {
                        BrewPingLog.watch.error("Agent switch rejected: device is not paired")
                        return
                    }
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let success = json?["success"] as? Bool ?? false
                    BrewPingLog.watch.info("Switch to \(agentId, privacy: .public) -> \(success ? "OK" : "failed", privacy: .public)")
                } catch {
                    BrewPingLog.watch.error("Switch agent error: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }

    /// 切换 Mac 端当前 Agent 的默认模型（`POST /api/agents/models/default`）。
    /// 走的是与 Agent 切换同一条通道：手表只发意图，真正落地由 iPhone 转给 Mac。
    private func switchMacModel(to modelId: String, agentId: String) {
        onMainWithActiveDevice { device in
            guard let device,
                  var request = BrewPingHTTP.request(
                    device: device,
                    path: "/api/agents/models/default",
                    method: "POST",
                    timeout: 10
                  ) else {
                BrewPingLog.watch.info("No active device, skip model switch")
                return
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "agentId": agentId,
                "modelId": modelId
            ])

            Task {
                do {
                    let (data, response) = try await BrewPingHTTP.session.data(for: request)
                    if BrewPingHTTP.isUnauthorized(response) {
                        BrewPingLog.watch.error("Model switch rejected: device is not paired")
                        return
                    }
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let success = json?["success"] as? Bool ?? false
                    BrewPingLog.watch.info("Model switch to \(modelId, privacy: .public) -> \(success ? "OK" : "failed", privacy: .public)")
                    // 让 iPhone 界面与手表同步：ModelStore 重新拉一次以刷新高亮。
                    await ModelStore.shared.refresh(device: device, agentID: agentId, force: true)
                } catch {
                    BrewPingLog.watch.error("Switch model error: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }

    /// 确保 Mac 端 active Agent 匹配后再发命令
    private func ensureAgentThenForward(text: String, agentId: String?) {
        let forward = {
            DispatchQueue.main.async {
                CommandReceiver.shared.receive(type: .command, text: text)
            }
        }

        onMainWithActiveDevice { device in
            guard let agentId, let device,
                  var switchReq = BrewPingHTTP.request(
                    device: device,
                    path: "/api/agents/\(agentId)/switch",
                    method: "POST",
                    timeout: 10
                  ) else {
                // 未指定 Agent 或没有可用设备：仍然转发，由上层决定如何提示
                forward()
                return
            }
            switchReq.setValue("application/json", forHTTPHeaderField: "Content-Type")

            Task {
                do {
                    let _ = try await BrewPingHTTP.session.data(for: switchReq)
                } catch {
                    BrewPingLog.watch.error("Pre-switch failed: \(error.localizedDescription, privacy: .private)")
                }
                // 无论切换是否成功，都转发命令
                forward()
            }
        }
    }

    /// 当前 agent 列表（同步到 Watch）
    private func currentAgentList() -> [[String: String]] {
        return knownAgents
    }

    private var currentActiveAgentID: String {
        return currentAgentID
    }

    // MARK: - Speech Permission

    /// 语音识别权限必须在**前台**拿到。
    ///
    /// App 被 WCSession 在后台唤醒时代理不了系统授权弹窗，
    /// 若此时 `authorizationStatus` 还是 `.notDetermined`，
    /// `recognitionTask` 会立刻失败 —— 手表只会看到 "Recognition failed"，无从排查。
    /// 因此在前台启动时主动请求一次，把权限提前确定下来。
    func requestSpeechAuthorizationIfNeeded() {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else {
            BrewPingLog.audio.debug("Speech authorization already = \(status.rawValue, privacy: .public)")
            return
        }
        SFSpeechRecognizer.requestAuthorization { newStatus in
            BrewPingLog.audio.info("Speech authorization request -> \(newStatus.rawValue, privacy: .public)")
        }
    }

    // MARK: - Speech Recognition

    /// 一轮识别所需的全部对象。
    /// 必须保持强引用：`SFSpeechRecognizer` / `SFSpeechRecognitionTask`
    /// 若在识别过程中被释放，识别会被静默取消，
    /// 表现为"文件已送达但永远没有结果"。
    private final class RecognitionSession {
        let recognizer: SFSpeechRecognizer
        let request: SFSpeechURLRecognitionRequest
        var task: SFSpeechRecognitionTask?

        init(recognizer: SFSpeechRecognizer, request: SFSpeechURLRecognitionRequest) {
            self.recognizer = recognizer
            self.request = request
        }
    }

    /// 按轮次（token）保存，而不是单槽位保存：
    /// 连续模式下多段录音可能并发识别，单槽位会让先结束的那轮
    /// 把仍在识别中的 recognizer 一起释放掉。
    private var activeRecognitions: [UUID: RecognitionSession] = [:]

    /// 把 Watch 传来的 `locale`（如 `zh-Hant-TW`）对到 `SFSpeechRecognizer` 真正支持的 locale 上。
    ///
    /// 为什么不能直接 `SFSpeechRecognizer(locale: Locale(identifier: raw))`：
    ///  1. Watch 端 `Locale.current.identifier` 常带脚本子标签（`zh-Hans-CN`），
    ///     而 `supportedLocales()` 里只有 `zh-CN`，直接构造返回 nil，
    ///     旧代码于是静默回退 `en-US` —— 中文用户说完只会得到 "No speech detected"；
    ///  2. `supportedLocales()` 是 `Set`，`first(where:)` 的取用顺序不确定，
    ///     同一段语音在不同运行里可能被送进不同语言的模型。
    /// 所以这里改成「先排序、再打分」：结果确定，且优先挑区域 / 文字系统一致的候选。
    ///
    /// 子标签全部手工拆解，不用 `Locale.languageCode/script/region`：
    /// 那套新 API 的可用性在各平台不一致，而这里的需求用字符串拆解就够了，且可离线实测。
    private func makeRecognizer(preferredIdentifier: String?) -> SFSpeechRecognizer? {
        // 排序消除 Set 遍历顺序的不确定性
        let supported = SFSpeechRecognizer.supportedLocales().sorted { $0.identifier < $1.identifier }

        func bestMatch(_ rawIdentifier: String) -> SFSpeechRecognizer? {
            let normalized = normalizeLocaleIdentifier(rawIdentifier)
            let wanted = localeSubtags(of: normalized)
            guard !wanted.language.isEmpty else { return nil }
            let wantedScript = effectiveScript(language: wanted.language, script: wanted.script, region: wanted.region)

            var best: (score: Int, locale: Locale)?
            for candidate in supported {
                let id = candidate.identifier.lowercased()
                let info = localeSubtags(of: id)
                guard info.language == wanted.language else { continue }
                var score = 10                                                          // 同语言即可用
                if id == normalized { score += 100 }                                    // 完全一致
                if let wantedRegion = wanted.region, info.region == wantedRegion { score += 40 }  // 同区域
                if let wantedScript,
                   effectiveScript(language: info.language, script: info.script, region: info.region) == wantedScript {
                    score += 20                                                         // 同文字系统
                }
                if best == nil || score > best!.score { best = (score, candidate) }
            }
            // candidate 来自 supportedLocales()，构造必然成功；用 flatMap 避免强解包
            return best.flatMap { SFSpeechRecognizer(locale: $0.locale) }
        }

        if let preferredIdentifier, let recognizer = bestMatch(preferredIdentifier) {
            return recognizer
        }
        // 请求的语言没有对应模型时退化到设备语言，而不是无脑 en-US。
        for language in Locale.preferredLanguages {
            if let recognizer = bestMatch(language) { return recognizer }
        }
        return SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    /// `zh_Hans_CN` → `zh-hans-cn`
    private func normalizeLocaleIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    /// 拆 BCP-47 子标签。语言码 2~3 位；脚本 4 位字母；区域 2 位字母或 3 位数字。
    private func localeSubtags(of identifier: String) -> (language: String, script: String?, region: String?) {
        let parts = normalizeLocaleIdentifier(identifier).split(separator: "-").map(String.init)
        guard let language = parts.first, !language.isEmpty else { return ("", nil, nil) }
        // 首段是 4 位纯字母说明标识符本身就畸形（如 `hans-CN`），不要拿它当语言
        if language.count == 4, language.allSatisfy({ $0.isLetter }) { return ("", nil, nil) }

        var script: String?
        var region: String?
        for part in parts.dropFirst() {
            if part.count == 4, part.allSatisfy({ $0.isLetter }) {
                if script == nil { script = part }
            } else if (part.count == 2 && part.allSatisfy({ $0.isLetter }))
                        || (part.count == 3 && part.allSatisfy({ $0.isNumber })) {
                if region == nil { region = part }
            }
        }
        return (language, script, region)
    }

    /// 有效文字系统：标识符里显式写了就用显式的，否则按语言 + 区域补一个。
    /// `zh-TW` / `zh-HK` / `zh-MO` 都不带脚本子标签，但它们实际是繁体 ——
    /// 不补这一步，繁体用户会被配到简体模型 `zh-CN` 上。
    private func effectiveScript(language: String, script: String?, region: String?) -> String? {
        if let script { return script }
        guard language == "zh" else { return nil }
        switch region {
        case "tw", "hk", "mo": return "hant"
        default: return nil
        }
    }

    /// 将 Watch 发来的音频文件转为文字，然后走已有的 command 链路。
    /// `audioURL` 必须是已经落在本 App 临时目录、不会被系统回收的文件。
    private func transcribeAndForward(audioURL: URL, agentId: String?, localeIdentifier: String? = nil) {
        // 权限先行：否则后台唤醒时识别必然失败，且错误信息没有指向性。
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            let status = SFSpeechRecognizer.authorizationStatus()
            BrewPingLog.audio.error("Speech recognition not authorized (status=\(status.rawValue, privacy: .public))")
            try? FileManager.default.removeItem(at: audioURL)
            sendCommandResult(status: "failed", text: "Speech recognition not authorized")
            return
        }

        guard let recognizer = makeRecognizer(preferredIdentifier: localeIdentifier) else {
            BrewPingLog.audio.error("No speech recognizer available for locale \(localeIdentifier ?? "auto", privacy: .private)")
            try? FileManager.default.removeItem(at: audioURL)
            sendCommandResult(status: "failed", text: "Speech recognition not available")
            return
        }
        guard recognizer.isAvailable else {
            BrewPingLog.audio.error("Speech recognizer not currently available (locale=\(recognizer.locale.identifier, privacy: .public))")
            try? FileManager.default.removeItem(at: audioURL)
            sendCommandResult(status: "failed", text: "Speech recognition not available")
            return
        }
        BrewPingLog.audio.info("Recognizer locale = \(recognizer.locale.identifier, privacy: .public)")

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.taskHint = .dictation
        request.shouldReportPartialResults = false

        let recognition = RecognitionSession(recognizer: recognizer, request: request)
        let token = UUID()
        activeRecognitions[token] = recognition

        let started = Date()
        recognition.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let error {
                BrewPingLog.audio.error("Speech recognition error: \(error.localizedDescription, privacy: .private)")
                self.activeRecognitions.removeValue(forKey: token)
                try? FileManager.default.removeItem(at: audioURL)
                self.sendCommandResult(status: "failed", text: "Recognition failed: \(error.localizedDescription)")
                return
            }

            guard let result, result.isFinal else { return }

            let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            let elapsed = Date().timeIntervalSince(started)
            // 转写结果属于用户内容，标记 .private。
            BrewPingLog.audio.info("Recognized in \(String(format: "%.1f", elapsed), privacy: .public)s: \(text, privacy: .private)")

            self.activeRecognitions.removeValue(forKey: token)
            try? FileManager.default.removeItem(at: audioURL)

            guard !text.isEmpty else {
                self.sendCommandResult(status: "failed", text: "No speech detected")
                return
            }

            // 确保 Agent 匹配后转发命令
            DispatchQueue.main.async {
                self.ensureAgentThenForward(text: text, agentId: agentId)
            }
        }
    }
}

// MARK: - WatchAudioPlayback

/// 把 Watch 传来的录音在本机回放一次。
///
/// 目的很窄：让用户能"听见"录音确实完整送达了。
/// 识别结果只是文字，无法反映"录到了什么"，音量太小、录串了都看不出来。
///
/// 只在 App 前台播放（由调用方判断），后台唤醒不出声。
/// 播放器持有已打开的 file descriptor，因此识别流程随后删除该文件
/// 不会打断播放（POSIX 下 unlink 已打开的文件是安全的）。
final class WatchAudioPlayback: NSObject, AVAudioPlayerDelegate {
    static let shared = WatchAudioPlayback()

    private var player: AVAudioPlayer?

    private override init() {
        super.init()
    }

    func play(_ url: URL, label: String) {
        do {
            // .ambient：与其他 App 音频共存、跟随静音开关，不会打断用户正在听的东西。
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default)
            try session.setActive(true)

            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            self.player = player          // 必须强引用，否则播放会被立刻中断
            player.play()
            BrewPingLog.audio.debug("Playing back watch audio \(label, privacy: .private)")
        } catch {
            BrewPingLog.audio.error("Audio playback skipped: \(error.localizedDescription, privacy: .private)")
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        BrewPingLog.audio.debug("Audio playback finished (ok=\(flag, privacy: .public))")
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        BrewPingLog.audio.error("Audio playback decode error: \(error?.localizedDescription ?? "unknown", privacy: .private)")
    }
}
