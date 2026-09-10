import Foundation
import WatchConnectivity
import Combine

enum CommandSendState: Equatable {
    case idle
    case sending
    case sent(String)
    case completed(String)
    case failed(String)
}

struct WatchAgent: Identifiable, Equatable {
    let id: String
    let name: String
}

struct WatchDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let osType: String  // "mac", "windows", "linux"

    var icon: String {
        switch osType {
        case "windows": return "pc"
        case "linux":   return "terminal"
        default:        return "desktopcomputer"
        }
    }

    var osLabel: String {
        switch osType {
        case "windows": return "Win"
        case "linux":   return "Linux"
        default:        return "Mac"
        }
    }
}

final class WatchSessionManager: NSObject, ObservableObject, WCSessionDelegate {
    @Published var reachable = false
    @Published var activationState: WCSessionActivationState = .notActivated
    @Published var lastSentText: String?
    @Published var lastError: String?
    @Published var macConnected: Bool?
    @Published var sessionState: String?
    @Published var agentName: String = "OpenCode"
    @Published var agentMode: String = "session"
    @Published var commandState: CommandSendState = .idle
    @Published var lastCommandDuration: Double?

    // MARK: - Multi-Agent
    @Published var agents: [WatchAgent] = [
        WatchAgent(id: "opencode", name: "OpenCode"),
        WatchAgent(id: "claude-code", name: "Claude"),
        WatchAgent(id: "codex", name: "Codex")
    ]
    @Published var activeAgentIndex: Int = 0

    // MARK: - Multi-Device
    @Published var devices: [WatchDevice] = []
    @Published var activeDeviceIndex: Int = 0

    var activeAgentID: String {
        guard activeAgentIndex < agents.count else { return "opencode" }
        return agents[activeAgentIndex].id
    }

    var activeDeviceID: String {
        guard activeDeviceIndex < devices.count else { return "" }
        return devices[activeDeviceIndex].id
    }

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    private var stateTimer: Timer?
    private var requestedStatus = false
    private var statusRequestTicks = 0

    /// 正在排队的音频文件传输。`transferFile` 没有回复回调，
    /// 完成/失败只能从 `session(_:didFinish:)` 得知，
    /// 因此需要按文件名跟踪，避免把别的传输结果算到当前命令上。
    private var audioTransfers: [WCSessionFileTransfer] = []
    private var pendingAudioFileNames: Set<String> = []

    func activate() {
        guard let session, session.activationState != .activated else { return }
        session.delegate = self
        session.activate()
        startStateTimer()
        applyContext(session.receivedApplicationContext)
    }

    private func applyContext(_ context: [String: Any]) {
        DispatchQueue.main.async {
            if let mac = context["macConnected"] as? Bool {
                self.macConnected = mac
            }
            if let state = context["sessionState"] as? String, !state.isEmpty {
                self.sessionState = state
            }
            if let name = context["agentName"] as? String, !name.isEmpty {
                self.agentName = name
            }
            if let mode = context["agentMode"] as? String, !mode.isEmpty {
                self.agentMode = mode
            }
            // 同步 Agent 列表
            if let agentList = context["agents"] as? [[String: String]] {
                let parsed = agentList.compactMap { dict -> WatchAgent? in
                    guard let id = dict["id"], let name = dict["name"] else { return nil }
                    return WatchAgent(id: id, name: name)
                }
                if !parsed.isEmpty {
                    self.agents = parsed
                }
            }
            if let activeId = context["activeAgent"] as? String,
               let idx = self.agents.firstIndex(where: { $0.id == activeId }) {
                self.activeAgentIndex = idx
            }
            // 同步设备列表
            if let deviceList = context["devices"] as? [[String: String]] {
                let parsed = deviceList.compactMap { dict -> WatchDevice? in
                    guard let id = dict["id"], let name = dict["name"] else { return nil }
                    return WatchDevice(id: id, name: name, osType: dict["os"] ?? "mac")
                }
                if !parsed.isEmpty {
                    self.devices = parsed
                }
            }
            if let activeDevId = context["activeDevice"] as? String,
               let idx = self.devices.firstIndex(where: { $0.id == activeDevId }) {
                self.activeDeviceIndex = idx
            }
        }
    }

    // MARK: - Agent Switching

    func switchToAgent(index: Int) {
        guard index >= 0, index < agents.count else { return }
        activeAgentIndex = index
        let agent = agents[index]
        let agentId = agent.id
        agentName = agent.name

        guard let session, session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(
            ["type": "switchAgent", "agentId": agentId],
            replyHandler: { [weak self] reply in
                DispatchQueue.main.async {
                    self?.requestStatusSync()
                }
            },
            errorHandler: { error in
                print("BrewPing watch: switchAgent failed: \(error.localizedDescription)")
            }
        )
    }

    func nextAgent() {
        let next = (activeAgentIndex + 1) % agents.count
        switchToAgent(index: next)
    }

    func previousAgent() {
        let prev = (activeAgentIndex - 1 + agents.count) % agents.count
        switchToAgent(index: prev)
    }

    // MARK: - Device Switching

    func switchToDevice(index: Int) {
        guard index >= 0, index < devices.count else { return }
        activeDeviceIndex = index
        let deviceId = devices[index].id

        guard let session, session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(
            ["type": "switchDevice", "deviceId": deviceId],
            replyHandler: { [weak self] reply in
                DispatchQueue.main.async {
                    self?.requestStatusSync()
                }
            },
            errorHandler: { error in
                print("BrewPing watch: switchDevice failed: \(error.localizedDescription)")
            }
        )
    }

    // MARK: - State Refresh

    private func startStateTimer() {
        guard stateTimer == nil else { return }
        stateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
    }

    func refreshState() {
        guard let session else { return }
        DispatchQueue.main.async {
            let reachable = session.isReachable
            if self.reachable != reachable {
                if reachable { self.requestedStatus = false }
            }
            self.reachable = reachable
            self.activationState = session.activationState
            self.statusRequestTicks += 1
            let needsStatus = self.macConnected == nil
            let periodicRefresh = self.statusRequestTicks % 8 == 0
            if session.activationState == .activated, reachable, needsStatus || periodicRefresh {
                self.requestStatusSync()
            }
        }
    }

    func requestStatusSync() {
        guard let session, session.activationState == .activated, session.isReachable else {
            requestedStatus = false
            return
        }
        guard !requestedStatus else { return }
        requestedStatus = true
        session.sendMessage(["type": "requestStatus"], replyHandler: { [weak self] reply in
            DispatchQueue.main.async {
                guard let self else { return }
                if let mac = reply["macConnected"] as? Bool { self.macConnected = mac }
                if let state = reply["sessionState"] as? String { self.sessionState = state.isEmpty ? nil : state }
                if let name = reply["agentName"] as? String, !name.isEmpty { self.agentName = name }
                if let mode = reply["agentMode"] as? String, !mode.isEmpty { self.agentMode = mode }
                if let agentList = reply["agents"] as? [[String: String]] {
                    let parsed = agentList.compactMap { dict -> WatchAgent? in
                        guard let id = dict["id"], let name = dict["name"] else { return nil }
                        return WatchAgent(id: id, name: name)
                    }
                    if !parsed.isEmpty { self.agents = parsed }
                }
                if let activeId = reply["activeAgent"] as? String,
                   let idx = self.agents.firstIndex(where: { $0.id == activeId }) {
                    self.activeAgentIndex = idx
                }
                // 同步设备列表
                if let deviceList = reply["devices"] as? [[String: String]] {
                    let parsed = deviceList.compactMap { dict -> WatchDevice? in
                        guard let id = dict["id"], let name = dict["name"] else { return nil }
                        return WatchDevice(id: id, name: name, osType: dict["os"] ?? "mac")
                    }
                    if !parsed.isEmpty { self.devices = parsed }
                }
                if let activeDevId = reply["activeDevice"] as? String,
                   let idx = self.devices.firstIndex(where: { $0.id == activeDevId }) {
                    self.activeDeviceIndex = idx
                }
            }
        }, errorHandler: { [weak self] error in
            DispatchQueue.main.async {
                self?.requestedStatus = false
            }
        })
    }

    // MARK: - Commands

    func sendCommand(_ text: String) {
        guard let session else {
            DispatchQueue.main.async { self.commandState = .failed("WatchConnectivity unsupported") }
            return
        }
        guard session.activationState == .activated else {
            DispatchQueue.main.async { self.commandState = .failed("iPhone App Not Connected") }
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            DispatchQueue.main.async { self.commandState = .failed("Empty command") }
            return
        }
        let payload: [String: Any] = [
            "type": "command",
            "text": trimmed,
            "content": trimmed,
            "agentId": activeAgentID
        ]
        DispatchQueue.main.async { self.commandState = .sending }

        // sendMessage 只在 iPhone App 处于前台时可用；
        // 不可达时退回 transferUserInfo（排队投递，会在 App 下次运行时送达）。
        guard session.isReachable else {
            session.transferUserInfo(payload)
            DispatchQueue.main.async { self.commandState = .sent(trimmed) }
            return
        }

        session.sendMessage(payload, replyHandler: { [weak self] _ in
            DispatchQueue.main.async {
                self?.commandState = .sent(trimmed)
                self?.lastError = nil
            }
        }, errorHandler: { [weak self] error in
            print("BrewPing watch: sendMessage failed, falling back to transferUserInfo: \(error.localizedDescription)")
            session.transferUserInfo(payload)
            DispatchQueue.main.async {
                self?.commandState = .sent(trimmed)
            }
        })
    }

    // MARK: - WCSession Delegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.activationState = activationState
            self.reachable = session.isReachable
        }
        applyContext(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        applyContext(applicationContext)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.reachable = session.isReachable
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        applyCommandResult(message)
    }

    /// iPhone 在不可达时会用 transferUserInfo 排队回传结果，
    /// 由系统在 Watch App 下次运行时投递。
    /// 注意：不要给参数写默认值，`WCSessionDelegate` 是 @objc 协议，
    /// 带默认值的方法在见证协议要求时会有歧义。
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        applyCommandResult(userInfo)
    }

    /// 音频文件传输结束（成功或失败）。此时才能安全删除本地录音文件。
    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let name = fileTransfer.file.fileURL.lastPathComponent
        guard pendingAudioFileNames.contains(name) else { return }
        pendingAudioFileNames.remove(name)
        audioTransfers.removeAll { $0 === fileTransfer }
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)

        DispatchQueue.main.async {
            if let error {
                print("BrewPing watch: audio transfer failed - \(error.localizedDescription)")
                self.commandState = .failed("Send failed: \(error.localizedDescription)")
            } else if case .sent = self.commandState {
                // 只在仍处于"已送出"时更新文案，
                // 避免覆盖已经到达的 commandResult 结果。
                self.commandState = .sent("Audio delivered")
            }
        }
    }

    private func applyCommandResult(_ message: [String: Any]) {
        guard message["type"] as? String == "commandResult" else { return }
        let status = message["status"] as? String ?? ""
        let text = message["text"] as? String ?? ""
        let duration = message["duration"] as? Double
        DispatchQueue.main.async {
            self.lastCommandDuration = duration
            if status == "completed" || status == "completed_with_raw" {
                self.commandState = .completed(text)
            } else {
                self.commandState = .failed(text.isEmpty ? "Command failed" : text)
            }
        }
    }

    // MARK: - Audio Commands

    /// 把录音文件发送到 iPhone 做语音识别。
    ///
    /// 使用 `transferFile` 而不是 `sendMessage`，原因有二：
    ///  1. `sendMessage` 的载荷上限约 65 KB，一段 10s+ 的 AAC 录音随时会超限
    ///     并返回 WCErrorCodePayloadTooLarge；
    ///  2. `sendMessage` 要求 iPhone App 正在前台（`isReachable`），
    ///     而"用手表发语音"的典型场景恰恰是手机在口袋里。
    ///     `transferFile` 会排队并在后台投递。
    /// 因此这里只要求会话已激活，不再要求 reachable。
    func sendAudioCommand(fileURL: URL, duration: TimeInterval? = nil) {
        guard let session else {
            try? FileManager.default.removeItem(at: fileURL)
            DispatchQueue.main.async { self.commandState = .failed("WatchConnectivity unsupported") }
            return
        }
        guard session.activationState == .activated else {
            try? FileManager.default.removeItem(at: fileURL)
            DispatchQueue.main.async { self.commandState = .failed("iPhone App Not Connected") }
            return
        }

        var metadata: [String: Any] = [
            "type": "audioCommand",
            "agentId": activeAgentID,
            "fileName": fileURL.lastPathComponent,
            "createdAt": Date().timeIntervalSince1970,
            "locale": Locale.current.identifier
        ]
        if let duration { metadata["duration"] = duration }

        let transfer = session.transferFile(fileURL, metadata: metadata)
        audioTransfers.append(transfer)
        pendingAudioFileNames.insert(fileURL.lastPathComponent)

        print("BrewPing watch: queued audio transfer \(fileURL.lastPathComponent) reachable=\(session.isReachable)")
        // 排队成功即视为已送出：transferFile 是排队式投递，
        // 若一直停在 .sending，手机长时间离线时 UI 会永久卡住。
        // 真正的失败在 session(_:didFinish:) 里降级为 .failed。
        DispatchQueue.main.async { self.commandState = .sent("Audio sent") }
    }

    // MARK: - Legacy

    func sendTest(text: String = "Hello from Watch") {
        guard let session else { return }
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["type": "test", "text": text], replyHandler: nil, errorHandler: nil)
        DispatchQueue.main.async { self.lastSentText = text }
    }
}
