import Foundation
import WatchConnectivity
import Combine
import Speech

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
                "activeAgent": currentAgentID
            ])
        } catch {
            print("BrewPing iPhone: status push failed: \(error.localizedDescription)")
        }
    }

    func sendCommandResult(status: String, text: String, duration: Double? = nil) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            print("BrewPing iPhone: watch not reachable, command result kept for context only")
            return
        }
        var message: [String: Any] = [
            "type": "commandResult",
            "status": status,
            "text": text
        ]
        if let duration { message["duration"] = duration }
        session.sendMessage(message, replyHandler: nil) { error in
            print("BrewPing iPhone: command result push failed: \(error.localizedDescription)")
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            print("BrewPing iPhone WCSession activation error: \(error.localizedDescription)")
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

    private func handleWatchMessage(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?) {
        let type = message["type"] as? String ?? "unknown"
        if type == "requestStatus" {
            print("BrewPing iPhone: watch requested status -> online=\(currentOnline ?? false) session=\(currentSessionState ?? "")")
            replyHandler?([
                "macConnected": currentOnline ?? false,
                "sessionState": currentSessionState ?? "",
                "agentName": currentAgentName,
                "agentMode": currentAgentMode,
                "agents": currentAgentList(),
                "activeAgent": currentActiveAgentID
            ])
            return
        }
        if type == "switchAgent" {
            guard let agentId = message["agentId"] as? String else {
                replyHandler?(["ok": false, "error": "missing agentId"])
                return
            }
            print("BrewPing iPhone: watch switching to agent: \(agentId)")
            replyHandler?(["ok": true, "type": "ack"])
            switchMacAgent(to: agentId)
            return
        }
        if type == "command" {
            let text = (message["text"] as? String) ?? (message["content"] as? String) ?? ""
            let agentId = message["agentId"] as? String
            print("Command received from Watch: agentId=\(agentId ?? "default") text=\(text)")
            replyHandler?(["ok": true, "type": "ack"])
            ensureAgentThenForward(text: text, agentId: agentId)
            return
        }
        if type == "audioCommand" {
            guard let audioData = message["audio"] as? Data else {
                print("BrewPing iPhone: audioCommand missing audio data")
                replyHandler?(["ok": false, "error": "no audio data"])
                return
            }
            let agentId = message["agentId"] as? String
            print("BrewPing iPhone: audio command received (\(audioData.count) bytes) agentId=\(agentId ?? "default")")
            replyHandler?(["ok": true, "type": "ack"])
            transcribeAndForward(audioData: audioData, agentId: agentId)
            return
        }
        let text = message["text"] as? String ?? ""
        print("Received from Watch:\n\(text)")
        CommandReceiver.shared.receive(type: .status, text: text)
        DispatchQueue.main.async {
            self.lastReceivedType = type
            self.lastReceivedText = text
        }
        replyHandler?(["ok": true, "type": "ack"])
    }

    // MARK: - Agent Switching

    /// 切换 Mac 端的 active Agent
    private func switchMacAgent(to agentId: String) {
        let host = UserDefaults.standard.string(forKey: "brewping.macAddress") ?? ""
        let port = UserDefaults.standard.string(forKey: "brewping.port") ?? "8787"
        guard !host.isEmpty, let url = URL(string: "http://\(host):\(port)/api/agents/\(agentId)/switch") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let success = json?["success"] as? Bool ?? false
                print("BrewPing iPhone: switch to \(agentId) -> \(success ? "OK" : "failed")")
            } catch {
                print("BrewPing iPhone: switch agent error: \(error)")
            }
        }
    }

    /// 确保 Mac 端 active Agent 匹配后再发命令
    private func ensureAgentThenForward(text: String, agentId: String?) {
        if let agentId {
            // 先切 Agent，再发命令
            let host = UserDefaults.standard.string(forKey: "brewping.macAddress") ?? ""
            let port = UserDefaults.standard.string(forKey: "brewping.port") ?? "8787"
            guard !host.isEmpty, let switchURL = URL(string: "http://\(host):\(port)/api/agents/\(agentId)/switch") else {
                CommandReceiver.shared.receive(type: .command, text: text)
                return
            }

            var switchReq = URLRequest(url: switchURL)
            switchReq.httpMethod = "POST"
            switchReq.timeoutInterval = 10

            Task {
                do {
                    let _ = try await URLSession.shared.data(for: switchReq)
                } catch {
                    print("BrewPing iPhone: pre-switch failed: \(error)")
                }
                // 无论切换是否成功，都转发命令
                DispatchQueue.main.async {
                    CommandReceiver.shared.receive(type: .command, text: text)
                }
            }
        } else {
            CommandReceiver.shared.receive(type: .command, text: text)
        }
    }

    /// 当前 agent 列表（同步到 Watch）
    private func currentAgentList() -> [[String: String]] {
        return knownAgents
    }

    private var currentActiveAgentID: String {
        return currentAgentID
    }

    // MARK: - Speech Recognition

    /// 将 Watch 发来的音频转为文字，然后走已有的 command 链路
    private func transcribeAndForward(audioData: Data, agentId: String?) {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("watch_audio.m4a")
        do {
            try audioData.write(to: tempURL)
        } catch {
            print("BrewPing iPhone: failed to write audio: \(error)")
            sendCommandResult(status: "failed", text: "Audio save failed")
            return
        }

        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard recognizer?.isAvailable == true else {
            print("BrewPing iPhone: speech recognizer not available")
            sendCommandResult(status: "failed", text: "Speech recognition not available")
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: tempURL)
        request.taskHint = .dictation
        request.shouldReportPartialResults = false

        recognizer?.recognitionTask(with: request) { [weak self] result, error in
            defer {
                try? FileManager.default.removeItem(at: tempURL)
            }

            if let error {
                print("BrewPing iPhone: speech recognition error: \(error)")
                self?.sendCommandResult(status: "failed", text: "Recognition failed: \(error.localizedDescription)")
                return
            }

            guard let result, result.isFinal else { return }
            let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            print("BrewPing iPhone: recognized: \"\(text)\"")

            guard !text.isEmpty else {
                self?.sendCommandResult(status: "failed", text: "No speech detected")
                return
            }

            // 确保 Agent 匹配后转发命令
            DispatchQueue.main.async {
                self?.ensureAgentThenForward(text: text, agentId: agentId)
            }
        }
    }
}
