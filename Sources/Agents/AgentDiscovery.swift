import Foundation

enum SystemCommand {
    static func run(executablePath: String, arguments: [String], timeoutSeconds: TimeInterval) -> (exitCode: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let completed = DispatchSemaphore(value: 0)
        let queue = DispatchQueue.global(qos: .userInitiated)
        queue.async {
            process.waitUntilExit()
            completed.signal()
        }
        guard completed.wait(timeout: .now() + timeoutSeconds) == .success else {
            process.terminate()
            return nil
        }
        let handle = pipe.fileHandleForReading
        let data = handle.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }

    static func locate(command: String) -> String? {
        guard let result = run(executablePath: "/usr/bin/which", arguments: [command], timeoutSeconds: 5),
              result.exitCode == 0 else { return nil }
        let line = result.output
            .split(separator: "\n")
            .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard line.hasPrefix("/") else { return nil }
        return line
    }

    static func firstLine(_ output: String, maxCharacters: Int = 64) -> String? {
        let line = output
            .split(separator: "\n")
            .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !line.isEmpty else { return nil }
        return String(line.prefix(maxCharacters))
    }
}

final class AgentDiscovery {
    static let catalog: [AgentDefinition] = [
        AgentDefinition(
            id: "opencode",
            name: "OpenCode",
            command: "opencode",
            versionArguments: ["--version"],
            fallbackPath: OpenCodeAgent.executablePath
        ),
        AgentDefinition(
            id: "claude-code",
            name: "Claude Code",
            command: "claude",
            versionArguments: ["--version"],
            fallbackPath: nil
        ),
        AgentDefinition(
            id: "codex",
            name: "Codex CLI",
            command: "codex",
            versionArguments: ["--version"],
            fallbackPath: nil
        ),
        AgentDefinition(
            id: "aider",
            name: "Aider",
            command: "aider",
            versionArguments: ["--version"],
            fallbackPath: nil
        )
    ]

    static let cacheInterval: TimeInterval = 60

    private let lock = NSLock()
    private var cached: [DetectedAgent] = []
    private var cachedAt: Date?

    static let shared = AgentDiscovery()

    private init() {}

    func discover(force: Bool = false) -> [DetectedAgent] {
        lock.lock()
        if !force, let cachedAt = cachedAt, Date().timeIntervalSince(cachedAt) < AgentDiscovery.cacheInterval, !cached.isEmpty {
            let result = cached
            lock.unlock()
            return result
        }
        lock.unlock()

        let group = DispatchGroup()
        let resultQueue = DispatchQueue(label: "BrewPing agent discovery")
        var results: [DetectedAgent] = []
        results.reserveCapacity(AgentDiscovery.catalog.count)

        for definition in AgentDiscovery.catalog {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let agent = AgentDiscovery.detect(definition)
                resultQueue.sync { results.append(agent) }
                group.leave()
            }
        }
        group.wait()

        let sorted = results.sorted { lhs, rhs in
            let lIndex = AgentDiscovery.catalog.firstIndex { $0.id == lhs.id } ?? .max
            let rIndex = AgentDiscovery.catalog.firstIndex { $0.id == rhs.id } ?? .max
            return lIndex < rIndex
        }

        lock.lock()
        cached = sorted
        cachedAt = Date()
        lock.unlock()
        return sorted
    }

    private static func detect(_ definition: AgentDefinition) -> DetectedAgent {
        var executablePath = SystemCommand.locate(command: definition.command)
        if executablePath == nil, let fallback = definition.fallbackPath,
           FileManager.default.isExecutableFile(atPath: fallback) {
            executablePath = fallback
        }
        guard let path = executablePath else {
            return DetectedAgent(
                id: definition.id,
                name: definition.name,
                command: definition.command,
                installed: false,
                version: nil
            )
        }
        let version = SystemCommand.run(
            executablePath: path,
            arguments: definition.versionArguments,
            timeoutSeconds: 8
        ).flatMap { result in
            SystemCommand.firstLine(result.output)
        }
        return DetectedAgent(
            id: definition.id,
            name: definition.name,
            command: definition.command,
            installed: true,
            version: version
        )
    }
}
