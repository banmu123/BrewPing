import Foundation
import WatchConnectivity
import Combine

final class WatchSessionManager: NSObject, ObservableObject, WCSessionDelegate {
    @Published var reachable = false
    @Published var activationState: WCSessionActivationState = .notActivated
    @Published var lastSentText: String?
    @Published var lastError: String?

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    private var stateTimer: Timer?

    func activate() {
        guard let session, session.activationState != .activated else { return }
        session.delegate = self
        session.activate()
        startStateTimer()
    }

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
                print("BrewPing watch: iPhone reachable=\(reachable)")
            }
            self.reachable = reachable
            self.activationState = session.activationState
        }
    }

    func sendTest(text: String = "Hello from Watch") {
        guard let session else {
            DispatchQueue.main.async { self.lastError = "WatchConnectivity unsupported" }
            return
        }
        guard session.activationState == .activated, session.isReachable else {
            DispatchQueue.main.async { self.lastError = "iPhone App Not Connected" }
            return
        }
        let message: [String: Any] = ["type": "test", "text": text]
        print("BrewPing watch: send requested")
        session.sendMessage(message, replyHandler: { [weak self] _ in
            DispatchQueue.main.async {
                print("BrewPing watch: message delivered")
                self?.lastError = nil
            }
        }, errorHandler: { [weak self] error in
            DispatchQueue.main.async {
                print("BrewPing watch: send failed: \(error.localizedDescription)")
                self?.lastError = "Send failed: \(error.localizedDescription)"
            }
        })
        DispatchQueue.main.async {
            self.lastSentText = text
        }
    }

    func autoSendTest(timeoutSeconds: TimeInterval = 20) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if session?.activationState == .activated, session?.isReachable == true {
                sendTest()
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        print("BrewPing watch auto-send timed out waiting for iPhone")
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.activationState = activationState
            self.reachable = session.isReachable
            if let error {
                print("BrewPing watch activation error: \(error.localizedDescription)")
            }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.reachable = session.isReachable
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let text = message["text"] as? String {
            print("BrewPing watch received: \(text)")
        }
    }
}
