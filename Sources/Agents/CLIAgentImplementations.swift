import Foundation

final class ClaudeCodeAgent: HeadlessCLIAgent {
    init() {
        super.init(id: "claude-code", name: "Claude Code")
    }

    override func executionArguments(_ command: String) -> [String] {
        ["-p", command, "--output-format", "text"]
    }
}

final class CodexAgent: HeadlessCLIAgent {
    init() {
        super.init(id: "codex", name: "Codex CLI")
    }

    override func executionArguments(_ command: String) -> [String] {
        ["exec", command]
    }
}

final class AiderAgent: HeadlessCLIAgent {
    init() {
        super.init(id: "aider", name: "Aider")
    }

    override func executionArguments(_ command: String) -> [String] {
        ["--message", command, "--yes-always", "--no-auto-commits"]
    }
}
