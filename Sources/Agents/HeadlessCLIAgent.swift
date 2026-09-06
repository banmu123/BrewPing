import Foundation

/// 一次性 CLI 型 Agent 基类：检测安装 → 拼装参数 → 无 TTY 执行 → 统一解析输出。
class HeadlessCLIAgent: CodingAgent {
    let id: String
    let name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// 子类覆写：把自然语言 command 转成 CLI 参数。
    func executionArguments(_ command: String) -> [String] {
        [command]
    }

    func detect() -> DetectedAgent? {
        AgentDiscovery.shared.discover().first { $0.id == id && $0.installed }
    }

    func execute(_ command: String) -> AgentResult {
        let started = Date()
        func result(_ status: AgentExecutionStatus, _ output: String, _ summary: String? = nil) -> AgentResult {
            AgentResult(
                id: "run_" + UUID().uuidString,
                agentID: id,
                agentName: name,
                status: status,
                summary: summary ?? AgentResultSummary.make(from: output),
                filesChanged: [],
                durationSeconds: Date().timeIntervalSince(started),
                output: String(output.prefix(8000))
            )
        }

        guard let detected = detect(), let path = Self.executablePath(detected) else {
            return result(.failed, "Agent \(name) is not installed on this Mac.")
        }

        let arguments = executionArguments(command)
        guard let run = SystemCommand.run(
            executablePath: path,
            arguments: arguments,
            timeoutSeconds: executionTimeoutSeconds
        ) else {
            return result(.failed, "Failed to launch \(name) (\(path)).")
        }

        let output = AgentOutputCleaner.clean(run.output)
        guard run.exitCode == 0 else {
            let message = output.isEmpty ? "\(name) exited with code \(run.exitCode)." : output
            return result(.failed, message)
        }
        guard !output.isEmpty else {
            return result(.completed, "(no output)", "(no output)")
        }
        return result(.completed, output)
    }

    private static func executablePath(_ detected: DetectedAgent) -> String? {
        guard let path = detected.path, path.hasPrefix("/") else { return nil }
        return path
    }
}

enum AgentResultSummary {
    static func make(from output: String) -> String {
        let firstLine = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return String(firstLine.prefix(200))
    }
}

enum AgentOutputCleaner {
    static func clean(_ raw: String) -> String {
        PTYText.stripANSI(raw)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
