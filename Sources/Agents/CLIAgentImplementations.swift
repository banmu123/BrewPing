import Foundation

final class ClaudeCodeAgent: HeadlessCLIAgent {
    init(modelId: String? = nil) {
        super.init(id: "claude-code", name: "Claude Code", modelId: modelId)
    }

    override func executionArguments(_ command: String) -> [String] {
        var args = ["-p", command, "--output-format", "text"]
        if let modelId { args += ["--model", modelId] }
        return args
    }
}

final class CodexAgent: HeadlessCLIAgent {
    init(modelId: String? = nil) {
        super.init(id: "codex", name: "Codex CLI", modelId: modelId)
    }

    override func executionArguments(_ command: String) -> [String] {
        var args = ["exec", "--skip-git-repo-check", "-s", "workspace-write", command]
        if let modelId { args += ["--model", modelId] }
        return args
    }
}

final class AiderAgent: HeadlessCLIAgent {
    init(modelId: String? = nil) {
        super.init(id: "aider", name: "Aider", modelId: modelId)
    }

    override func executionArguments(_ command: String) -> [String] {
        var args = ["--message", command, "--yes-always", "--no-auto-commits"]
        if let modelId { args += ["--model", modelId] }
        return args
    }
}
