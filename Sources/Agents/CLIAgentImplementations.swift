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

final class PiAgent: HeadlessCLIAgent {
    init(modelId: String? = nil) {
        super.init(id: "pi", name: "pi", modelId: modelId)
    }

    /// 与 Windows `command_runner::headless_args` 的 `"pi"` 分支逐字对齐：
    /// `pi -p <text>`（print 模式：响应打印后退出），用户选过模型再追加 `--model <id>`。
    override func executionArguments(_ command: String) -> [String] {
        var args = ["-p", command]
        if let modelId { args += ["--model", modelId] }
        return args
    }
}
