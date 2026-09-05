import Foundation
import WatchConnectivity
import Combine

final class WatchConnectivityManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchConnectivityManager()

    @Published var lastReceivedText: String?
    @Published var lastReceivedType: String?
    var currentOnline: Bool?
    var currentSessionState: String?

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func pushStatus(online: Bool, sessionStateRaw: String) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        let activated = session.activationState == .activated
        let paired = session.isPaired
        print("BrewPing iPhone: pushStatus online=\(online) state=\(sessionStateRaw) activated=\(activated) paired=\(paired)")
        guard activated, paired else { return }
        do {
            try session.updateApplicationContext([
                "macConnected": online,
                "sessionState": sessionStateRaw
            ])
            print("BrewPing iPhone: context pushed")
        } catch {
            print("BrewPing iPhone: status push failed: \(error.localizedDescription)")
        }
    }

    func sendCommandResult(status: String, text: String) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            print("BrewPing iPhone: watch not reachable, command result kept for context only")
            return
        }
        session.sendMessage([
            "type": "commandResult",
            "status": status,
            "text": text
        ], replyHandler: nil) { error in
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
                "sessionState": currentSessionState ?? ""
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
