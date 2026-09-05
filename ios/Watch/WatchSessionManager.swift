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

final class WatchSessionManager: NSObject, ObservableObject, WCSessionDelegate {
    @Published var reachable = false
    @Published var activationState: WCSessionActivationState = .notActivated
    @Published var lastSentText: String?
    @Published var lastError: String?
    @Published var macConnected: Bool?
    @Published var sessionState: String?
    @Published var commandState: CommandSendState = .idle

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    private var stateTimer: Timer?
    private var requestedStatus = false
    private var statusRequestTicks = 0

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
        }
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
        print("BrewPing watch: requesting status")
        session.sendMessage(["type": "requestStatus"], replyHandler: { [weak self] reply in
            DispatchQueue.main.async {
                guard let self else { return }
                print("BrewPing watch: status reply \(reply)")
                if let mac = reply["macConnected"] as? Bool { self.macConnected = mac }
                if let state = reply["sessionState"] as? String { self.sessionState = state.isEmpty ? nil : state }
            }
        }, errorHandler: { [weak self] error in
            DispatchQueue.main.async {
                print("BrewPing watch: status request failed: \(error.localizedDescription)")
                self?.requestedStatus = false
            }
        })
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
        applyContext(session.receivedApplicationContext)
    }

    func sendCommand(_ text: String) {
        guard let session else {
            DispatchQueue.main.async { self.commandState = .failed("WatchConnectivity unsupported") }
            return
        }
        guard session.activationState == .activated, session.isReachable else {
            DispatchQueue.main.async { self.commandState = .failed("iPhone App Not Connected") }
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            DispatchQueue.main.async { self.commandState = .failed("Empty command") }
            return
        }
        print("BrewPing watch: command send requested: \(trimmed)")
        DispatchQueue.main.async { self.commandState = .sending }
        session.sendMessage([
            "type": "command",
            "text": trimmed,
            "content": trimmed
        ], replyHandler: { [weak self] _ in
            DispatchQueue.main.async {
                print("BrewPing watch: command delivered")
                self?.commandState = .sent(trimmed)
                self?.lastError = nil
            }
        }, errorHandler: { [weak self] error in
            DispatchQueue.main.async {
                print("BrewPing watch: command send failed: \(error.localizedDescription)")
                self?.commandState = .failed(error.localizedDescription)
            }
        })
    }

    func autoCommandTest(text: String = "修复登录页面", timeoutSeconds: TimeInterval = 25) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let session, session.activationState == .activated, session.isReachable {
                sendCommand(text)
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        print("BrewPing watch auto-command timed out waiting for iPhone")
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        print("BrewPing watch: status synced \(applicationContext)")
        applyContext(applicationContext)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.reachable = session.isReachable
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message["type"] as? String == "commandResult" else { return }
        let status = message["status"] as? String ?? ""
        let text = message["text"] as? String ?? ""
        print("BrewPing watch: command result received status=\(status) text=\(text)")
        DispatchQueue.main.async {
            if status == "completed" || status == "completed_with_raw" {
                self.commandState = .completed(text)
            } else {
                self.commandState = .failed(text.isEmpty ? "Command failed" : text)
            }
        }
    }
}
