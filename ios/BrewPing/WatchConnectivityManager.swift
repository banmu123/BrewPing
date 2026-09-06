import Foundation
import WatchConnectivity
import Combine

final class WatchConnectivityManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchConnectivityManager()

    @Published var lastReceivedText: String?
    @Published var lastReceivedType: String?
    var currentOnline: Bool?
    var currentSessionState: String?
    var currentAgentName: String = "OpenCode"
    var currentAgentMode: String = "session"

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
                "agentMode": mode
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
                "agentMode": currentAgentMode
            ])
            return
        }
        if type == "command" {
            let text = (message["text"] as? String) ?? (message["content"] as? String) ?? ""
            print("Command received from Watch:\n\(text)")
            CommandReceiver.shared.receive(type: .command, text: text)
            replyHandler?(["ok": true, "type": "ack"])
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
}
