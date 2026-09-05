import Foundation

final class OpenCodeAgent: TerminalAgent {
    static let executablePath = "/Users/banmu/.opencode/bin/opencode"
    static let interactiveMarker = "Ask anything"
    static let pasteStart = "\u{1b}[200~"
    static let pasteEnd = "\u{1b}[201~"

    let sessionID = UUID()
    let cwd: String
    private let manager: PTYManager
    private(set) var lastExitCode: Int32?

    init(manager: PTYManager = .shared) {
        self.manager = manager
        self.cwd = FileManager.default.currentDirectoryPath
    }

    var pid: Int32? {
        guard let session = manager.session else { return nil }
        return session.isChildAlive() ? session.childPID : nil
    }

    var isRunning: Bool {
        manager.session?.isChildAlive() ?? false
    }

    var currentExitCode: Int32? {
        guard let session = manager.session, session.didExit else { return nil }
        return session.exitCodeValue
    }

    var ptyOutputLength: Int? {
        manager.session?.outputLength
    }

    func ptyText(from offset: Int) -> String? {
        manager.session?.text(from: offset)
    }

    var ptySessionRef: PTYSession? {
        manager.session
    }

    func start() throws {
        let session = try manager.startProcess(
            path: Self.executablePath,
            argvName: "opencode",
            environment: ["TERM": "xterm-256color"],
            logFileURL: SessionManager.shared.openCodeLogURL
        )
        try waitUntilInteractive(session)
    }

    private func waitUntilInteractive(_ session: PTYSession) throws {
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            if session.outputText.contains(Self.interactiveMarker) { return }
            if !session.isChildAlive() { throw AgentError.childDied("during startup") }
            usleep(250_000)
        }
        throw AgentError.startupTimeout
    }

    func sendMessage(_ text: String) throws {
        guard let session = manager.session, session.isChildAlive() else {
            throw AgentError.notStarted
        }
        let offset = session.outputLength
        guard session.write(Self.pasteStart + text + Self.pasteEnd) else {
            throw AgentError.sendWriteFailed
        }
        usleep(300_000)
        guard session.write("\r") else {
            throw AgentError.sendWriteFailed
        }
        let needle = PTYText.normalized(text)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let haystack = PTYText.normalized(session.text(from: offset))
            if haystack.contains(needle) { return }
            if !session.isChildAlive() { throw AgentError.childDied("while sending") }
            usleep(250_000)
        }
        throw AgentError.echoNotConfirmed("message echo not observed in PTY output")
    }

    func stop() throws {
        guard let session = manager.session else { throw AgentError.notStarted }
        let result = session.shutdown()
        lastExitCode = result.code
        manager.clear()
        if !result.clean {
            throw AgentError.stopFailed("opencode exit status \(result.code)")
        }
    }
}
