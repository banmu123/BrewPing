import Foundation

enum CommandStatus: String, Codable {
    case queued, sent, working, completed, completedWithRaw = "completed_with_raw", failed
}

struct CommandInfo: Codable {
    var commandId: String
    var sessionId: String
    var text: String
    var createdAt: Date
    var status: CommandStatus
    var response: String?
    var rawOutput: String?
    var error: String?
    var duration: TimeInterval?
    var completedAt: Date?
}

final class CommandStore {
    static let shared = CommandStore()

    private let lock = NSLock()
    private var commands: [String: CommandInfo] = [:]
    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            self.directory = SessionManager.shared.directory.appendingPathComponent("commands", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        loadPersisted()
    }

    private func fileURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    private func loadPersisted() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let info = try? JSONDecoder().decode(CommandInfo.self, from: data) {
                commands[info.commandId] = info
            }
        }
    }

    func create(text: String, sessionId: String) -> CommandInfo {
        let info = CommandInfo(
            commandId: CommandStore.newID(),
            sessionId: sessionId,
            text: text,
            createdAt: Date(),
            status: .queued,
            response: nil,
            rawOutput: nil,
            error: nil,
            duration: nil,
            completedAt: nil
        )
        lock.lock()
        commands[info.commandId] = info
        lock.unlock()
        persist(info)
        return info
    }

    func get(_ id: String) -> CommandInfo? {
        lock.lock()
        defer { lock.unlock() }
        return commands[id]
    }

    /// 只读快照（按创建时间升序）。供 ProtocolStateService 投影使用。
    func all() -> [CommandInfo] {
        lock.lock()
        defer { lock.unlock() }
        return commands.values.sorted { $0.createdAt < $1.createdAt }
    }

    func update(_ id: String, _ mutate: (inout CommandInfo) -> Void) {
        var updated: CommandInfo?
        lock.lock()
        if var info = commands[id] {
            mutate(&info)
            commands[id] = info
            updated = info
        }
        lock.unlock()
        if let info = updated { persist(info) }
    }

    private func persist(_ info: CommandInfo) {
        guard let data = try? JSONEncoder().encode(info) else { return }
        try? data.write(to: fileURL(info.commandId), options: .atomic)
    }

    static func newID() -> String {
        "cmd_" + UUID().uuidString
    }
}
