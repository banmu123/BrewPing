import Foundation

final class PTYManager {
    static let shared = PTYManager()

    private(set) var session: PTYSession?

    func startProcess(
        path: String,
        argvName: String,
        environment: [String: String],
        logFileURL: URL?
    ) throws -> PTYSession {
        let session = PTYSession(logFileURL: logFileURL)
        try session.spawn(path: path, argvName: argvName, environment: environment)
        self.session = session
        return session
    }

    func clear() {
        session = nil
    }
}
