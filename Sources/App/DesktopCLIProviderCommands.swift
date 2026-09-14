import Foundation

// ─── 桌面命令面：「厂商原生配置」四套（对齐 Windows 端同名 tauri 命令）──────────
//
// 与 Windows `lib.rs` 的命令逐条对应（函数名 = 命令名驼峰化）：
//
//   opencode（列表）
//     get_opencode_providers    → openCodeProviders()
//     save_opencode_provider    → saveOpenCodeProvider(_:)
//     delete_opencode_provider  → deleteOpenCodeProvider(id:)
//
//   claude（**单例** —— settings.json 只有一份，所以是"当前这一份"而非列表）
//     get_claude_provider       → claudeProvider()
//     save_claude_provider      → saveClaudeProvider(_:)
//     delete_claude_provider    → deleteClaudeProvider()   ← 无 id 参数
//
//   codex（列表 + 切换生效项）
//     get_codex_providers       → codexProviders()
//     save_codex_provider       → saveCodexProvider(_:)
//     delete_codex_provider     → deleteCodexProvider(id:)
//     activate_codex_provider   → activateCodexProvider(id:)
//
//   pi（列表 + 切换默认项）
//     get_pi_providers          → piProviders()
//     save_pi_provider          → savePiProvider(_:)
//     delete_pi_provider        → deletePiProvider(id:)
//     activate_pi_provider      → activatePiProvider(id:model:)
//
// 🔴 这四个模块直接读写**用户真实 CLI 配置**（`~/.claude/settings.json` 等），
//    不是 BrewPing 自己的库。所有写操作都走各自模块的进程内写锁。

extension DesktopCommands {

    // MARK: - OpenCode（写 ~/.config/opencode/opencode.json）

    public static func openCodeProviders() -> OpenCodeProvidersInfo {
        OpenCodeProviderConfigStore.list()
    }

    public static func saveOpenCodeProvider(_ entry: OpenCodeProviderEntry) throws -> OpenCodeProvidersInfo {
        try OpenCodeProviderConfigStore.save(entry)
    }

    public static func deleteOpenCodeProvider(id: String) throws -> OpenCodeProvidersInfo {
        try OpenCodeProviderConfigStore.delete(id: id)
    }

    // MARK: - Claude Code（写 ~/.claude/settings.json，单例）

    public static func claudeProvider() -> ClaudeProvidersInfo {
        ClaudeConfigStore.get()
    }

    public static func saveClaudeProvider(_ entry: ClaudeProviderEntry) throws -> ClaudeProvidersInfo {
        try ClaudeConfigStore.save(entry)
    }

    public static func deleteClaudeProvider() throws -> ClaudeProvidersInfo {
        try ClaudeConfigStore.delete()
    }

    // MARK: - Codex（写 ~/.codex/config.toml）

    public static func codexProviders() -> CodexProvidersInfo {
        CodexProviderConfigStore.list()
    }

    public static func saveCodexProvider(_ entry: CodexProviderEntry) throws -> CodexProvidersInfo {
        try CodexProviderConfigStore.save(entry)
    }

    public static func deleteCodexProvider(id: String) throws -> CodexProvidersInfo {
        try CodexProviderConfigStore.delete(id: id)
    }

    public static func activateCodexProvider(id: String) throws -> CodexProvidersInfo {
        try CodexProviderConfigStore.activate(id: id)
    }

    // MARK: - pi（写 ~/.pi/agent/{models,settings}.json）

    public static func piProviders() -> PiProvidersInfo {
        PiProviderConfigStore.list()
    }

    public static func savePiProvider(_ entry: PiProviderEntry) throws -> PiProvidersInfo {
        try PiProviderConfigStore.save(entry)
    }

    public static func deletePiProvider(id: String) throws -> PiProvidersInfo {
        try PiProviderConfigStore.delete(id: id)
    }

    public static func activatePiProvider(id: String, model: String?) throws -> PiProvidersInfo {
        try PiProviderConfigStore.activate(id: id, model: model)
    }
}
