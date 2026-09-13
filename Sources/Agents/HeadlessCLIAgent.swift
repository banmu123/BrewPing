import Foundation

/// 一次性 CLI 型 Agent 基类：检测安装 → 拼装参数 → 无 TTY 执行 → 统一解析输出。
class HeadlessCLIAgent: CodingAgent {
    let id: String
    let name: String
    let modelId: String?

    init(id: String, name: String, modelId: String? = nil) {
        self.id = id
        self.name = name
        self.modelId = modelId
    }

    /// 子类覆写：把自然语言 command 转成 CLI 参数。
    func executionArguments(_ command: String) -> [String] {
        [command]
    }

    func detect() -> DetectedAgent? {
        AgentDiscovery.shared.discover().first { $0.id == id && $0.installed }
    }

    func execute(_ command: String) -> AgentResult {
        execute(command, workdir: nil)
    }

    /// 带**对话级工作目录**的执行入口（目录由调用方校验过存在性）。
    func execute(_ command: String, workdir: String?) -> AgentResult {
        execute(command, workdir: workdir, onLaunch: nil)
    }

    /// `onLaunch` 在子进程真正启动后被调用一次（供外部登记句柄以支持手动停止）。
    func execute(_ command: String, workdir: String?, onLaunch: ((Process) -> Void)?) -> AgentResult {
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
        // 关键：把检测到的可执行文件目录注入子进程 PATH，
        // 让 `#!/usr/bin/env node` 类 shim 解析到与该 Agent 匹配的运行时。
        let executableDir = (path as NSString).deletingLastPathComponent
        guard let run = SystemCommand.run(
            executablePath: path,
            arguments: arguments,
            timeoutSeconds: executionTimeoutSeconds,
            additionalPATHEntries: [executableDir],
            workingDirectory: workdir,
            onLaunch: onLaunch
        ) else {
            return result(.failed, "Failed to launch \(name) (\(path)).")
        }

        let output = AgentOutputCleaner.clean(run.output)
        if run.exitCode == 0, !output.isEmpty {
            return result(.completed, output)
        }
        if run.exitCode == 0, output.isEmpty {
            return result(.completed, "(no output)", "(no output)")
        }
        // 非零退出码：用 ErrorClassifier 识别真实失败原因
        let failureReason = ErrorClassifier.classify(output: output, exitCode: run.exitCode) ?? .processExited
        let summary = ErrorClassifier.summarize(output: output, reason: failureReason)
        return result(.failed, output.isEmpty ? "\(name) exited with code \(run.exitCode)." : output, summary)
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
