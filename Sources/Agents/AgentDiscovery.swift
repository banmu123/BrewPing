import Foundation

public enum SystemCommand {
    public static func conventionalSearchPaths() -> [String] {
        var paths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin"
        ]
        let nvmVersions = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.nvm/versions/node"
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: nvmVersions) {
            for version in contents {
                let bin = "\(nvmVersions)/\(version)/bin"
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: bin, isDirectory: &isDirectory), isDirectory.boolValue {
                    paths.append(bin)
                }
            }
        }
        return paths
    }

    public static func run(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        additionalPATHEntries: [String] = [],
        workingDirectory: String? = nil
    ) -> (exitCode: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        // 对话级工作目录（headless 型 Agent）：子进程在指定目录下执行
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        if !additionalPATHEntries.isEmpty {
            var environment = ProcessInfo.processInfo.environment
            let current = environment["PATH"] ?? "/usr/bin:/bin"
            let existing = Set(current.split(separator: ":").map(String.init))
            let additions = additionalPATHEntries.filter { !existing.contains($0) }
            if !additions.isEmpty {
                // 前置注入：`#!/usr/bin/env node` 类 shim 必须优先解析到匹配的运行时
                environment["PATH"] = (additions + [current]).joined(separator: ":")
            }
            process.environment = environment
        }
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
        guard let result = run(executablePath: "/usr/bin/which",
                               arguments: [command],
                               timeoutSeconds: 5,
                               additionalPATHEntries: conventionalSearchPaths()),
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

public final class AgentDiscovery {
    public static let catalog: [AgentDefinition] = [
        AgentDefinition(
            id: "opencode",
            name: "OpenCode",
            command: "opencode",
            versionArguments: ["--version"]
        ),
        AgentDefinition(
            id: "claude-code",
            name: "Claude Code",
            command: "claude",
            versionArguments: ["--version"]
        ),
        AgentDefinition(
            id: "codex",
            name: "Codex CLI",
            command: "codex",
            versionArguments: ["--version"]
        ),
        AgentDefinition(
            id: "aider",
            name: "Aider",
            command: "aider",
            versionArguments: ["--version"]
        )
    ]

    static let cacheInterval: TimeInterval = 60

    private let lock = NSLock()
    private var cached: [DetectedAgent] = []
    private var cachedAt: Date?
    /// 上次成功扫描的结果，用于失败时保留已知配置。
    private var lastSuccessful: [DetectedAgent] = []

    public static let shared = AgentDiscovery()

    private init() {}

    public func discover(force: Bool = false) -> [DetectedAgent] {
        lock.lock()
        if !force, let cachedAt = cachedAt,
           Date().timeIntervalSince(cachedAt) < AgentDiscovery.cacheInterval,
           !cached.isEmpty {
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
        // 有至少一个已安装的 Agent → 视为成功扫描，保留为基准
        if sorted.contains(where: { $0.installed }) {
            lastSuccessful = sorted
            cached = sorted
            cachedAt = Date()
            lock.unlock()
            return sorted
        } else if !lastSuccessful.isEmpty {
            // 扫描全部返回未安装（可能是 PATH/环境瞬时问题）→ 保留上一次已知配置
            cached = lastSuccessful
            cachedAt = Date()
            lock.unlock()
            return lastSuccessful
        } else {
            cached = sorted
            cachedAt = Date()
            lock.unlock()
            return sorted
        }
    }

    private static func detect(_ definition: AgentDefinition) -> DetectedAgent {
        guard let path = SystemCommand.locate(command: definition.command) else {
            return DetectedAgent(
                id: definition.id,
                name: definition.name,
                command: definition.command,
                installed: false,
                version: nil,
                path: nil
            )
        }
        let version = SystemCommand.run(
            executablePath: path,
            arguments: definition.versionArguments,
            timeoutSeconds: 8,
            additionalPATHEntries: [(path as NSString).deletingLastPathComponent]
        ).flatMap { result in
            SystemCommand.firstLine(result.output)
        }
        return DetectedAgent(
            id: definition.id,
            name: definition.name,
            command: definition.command,
            installed: true,
            version: version,
            path: path
        )
    }
}
