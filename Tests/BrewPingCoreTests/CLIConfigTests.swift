import XCTest
@testable import BrewPingCore

/// 「厂商原生配置」四模块的不变量测试。
///
/// 对齐 Windows 各 `*_config.rs` 的 `#[cfg(test)]`：全部走 `*_at(path)` 显式路径入口
/// 或临时目录，**绝不碰用户真实配置**。
final class CLIConfigTests: XCTestCase {

    // ─── 工具 ────────────────────────────────────────────────────────────────

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("brewping-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func file(_ name: String) -> URL { tempDir.appendingPathComponent(name) }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func readText(_ url: URL) throws -> String {
        String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
    }

    // ═════════════════════════════════════════════════════════════════════════
    // MARK: - Claude（整体覆盖 + env 就地合并）
    // ═════════════════════════════════════════════════════════════════════════

    func testClaudeMergesEnvInPlaceAndKeepsOtherKeys() throws {
        let path = file("claude/settings.json")
        try write("""
        {
          "env": {
            "DISABLE_TELEMETRY": "1",
            "MCP_TIMEOUT": "30000"
          },
          "permissions": { "allow": ["mcp__pencil"] },
          "theme": "light"
        }
        """, to: path)

        let entry = ClaudeProviderEntry(
            baseURL: "https://api.example.com/anthropic",
            apiKey: "sk-test",
            tiers: [ClaudeTierEntry(tier: "sonnet", model: "m-1", name: "M1")]
        )
        _ = try ClaudeConfigStore.save(entry, at: path)

        let root = try readJSON(path)
        let env = root["env"] as? [String: Any] ?? [:]
        // 用户原有 env 键必须存活（这是"就地合并"的核心）
        XCTAssertEqual(env["DISABLE_TELEMETRY"] as? String, "1")
        XCTAssertEqual(env["MCP_TIMEOUT"] as? String, "30000")
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"] as? String, "https://api.example.com/anthropic")
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"] as? String, "sk-test")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_SONNET_MODEL"] as? String, "m-1")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"] as? String, "M1")
        // 顶层非 env 键必须存活
        XCTAssertNotNil(root["permissions"])
        XCTAssertEqual(root["theme"] as? String, "light")
    }

    func testClaudeSanitizeStripsCCSwitchInternalFields() throws {
        let path = file("claude/settings.json")
        try write("""
        { "api_format": "openai_chat", "env": { "apiFormat": "x", "KEEP": "1" } }
        """, to: path)
        _ = try ClaudeConfigStore.save(
            ClaudeProviderEntry(baseURL: "https://a.com", apiKey: "k"), at: path)

        let root = try readJSON(path)
        XCTAssertNil(root["api_format"], "顶层的 cc-switch 元字段必须被剥离")
        let env = root["env"] as? [String: Any] ?? [:]
        XCTAssertNil(env["apiFormat"], "env 内的元字段同样要剥离")
        XCTAssertEqual(env["KEEP"] as? String, "1")
    }

    func testClaudeEmptyValuesDeleteKeys() throws {
        let path = file("claude/settings.json")
        _ = try ClaudeConfigStore.save(ClaudeProviderEntry(
            baseURL: "https://a.com", apiKey: "k",
            tiers: [
                ClaudeTierEntry(tier: "sonnet", model: "m-1", name: "M1"),
                ClaudeTierEntry(tier: "opus", model: "m-2", name: "M2"),
            ]), at: path)

        // 第二档清空（表单语义 = 三档全量提交，空串档 = 删除该键）→ 键必须被删掉。
        // 注意：数组里缺档 = 不触碰（与 Windows claude_config.rs 一致，表单永远全量提交）。
        _ = try ClaudeConfigStore.save(ClaudeProviderEntry(
            baseURL: "https://a.com", apiKey: "k",
            tiers: [
                ClaudeTierEntry(tier: "sonnet", model: "m-1", name: "M1"),
                ClaudeTierEntry(tier: "opus", model: "", name: ""),
            ]), at: path)

        let env = (try readJSON(path))["env"] as? [String: Any] ?? [:]
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_SONNET_MODEL"] as? String, "m-1")
        XCTAssertNil(env["ANTHROPIC_DEFAULT_OPUS_MODEL"], "清空某档 = 删除该键")
        XCTAssertNil(env["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"])
    }

    func testClaudeDeleteKeepsUserSettingsAndDropsEmptyEnv() throws {
        let path = file("claude/settings.json")
        try write("""
        { "env": { "ANTHROPIC_BASE_URL": "https://a.com", "ANTHROPIC_AUTH_TOKEN": "k",
                   "ANTHROPIC_DEFAULT_SONNET_MODEL": "m", "DISABLE_TELEMETRY": "1" },
          "theme": "light" }
        """, to: path)
        let info = try ClaudeConfigStore.delete(at: path)

        XCTAssertFalse(info.configured)
        let root = try readJSON(path)
        XCTAssertEqual(root["theme"] as? String, "light", "删厂商不能带走用户设置")
        let env = root["env"] as? [String: Any] ?? [:]
        XCTAssertNil(env["ANTHROPIC_BASE_URL"])
        XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(env["ANTHROPIC_DEFAULT_SONNET_MODEL"])
        XCTAssertEqual(env["DISABLE_TELEMETRY"] as? String, "1", "env 里其余键要保留")
    }

    func testClaudeDeleteDropsEnvWhenItBecomesEmpty() throws {
        let path = file("claude/settings.json")
        try write("""
        { "env": { "ANTHROPIC_BASE_URL": "https://a.com" }, "theme": "light" }
        """, to: path)
        _ = try ClaudeConfigStore.delete(at: path)
        let root = try readJSON(path)
        XCTAssertNil(root["env"], "env 摘空后整个键应移除，不留噪音")
        XCTAssertEqual(root["theme"] as? String, "light")
    }

    func testClaudeValidatesBaseURL() throws {
        let path = file("claude/settings.json")
        XCTAssertThrowsError(try ClaudeConfigStore.save(
            ClaudeProviderEntry(baseURL: "", apiKey: "k"), at: path))
        XCTAssertThrowsError(try ClaudeConfigStore.save(
            ClaudeProviderEntry(baseURL: "ftp://a.com", apiKey: "k"), at: path))
    }

    func testClaudeReadDegradesOnInvalidRoot() throws {
        let path = file("claude/settings.json")
        try write("[1,2,3]", to: path)
        // 读路径不抛错（设置页不该整个炸掉），落成"未配置"
        let info = ClaudeConfigStore.get(at: path)
        XCTAssertFalse(info.configured)
        XCTAssertTrue(info.exists)
        // 写路径必须抛错（整体覆盖的前提是知道根长什么样）
        XCTAssertThrowsError(try ClaudeConfigStore.save(
            ClaudeProviderEntry(baseURL: "https://a.com"), at: path))
    }

    // ═════════════════════════════════════════════════════════════════════════
    // MARK: - Codex（TOML，保注释与其它段）
    // ═════════════════════════════════════════════════════════════════════════

    func testCodexSavePreservesCommentsAndOtherSections() throws {
        let path = file("codex/config.toml")
        try write("""
        # 我的 Codex 配置
        model = "old-model"

        [mcp_servers.node_repl]
        command = "/usr/bin/node"
        startup_timeout_sec = 120

        [mcp_servers.node_repl.env]
        NODE_PATH = "/opt/node"
        """, to: path)

        _ = try CodexProviderConfigStore.save(CodexProviderEntry(
            id: "my-deepseek", name: "My DeepSeek",
            baseURL: "https://api.deepseek.com/v1", wireApi: "responses",
            apiKey: "sk-x", model: "deepseek-chat"), at: path)

        let text = try readText(path)
        XCTAssertTrue(text.contains("# 我的 Codex 配置"), "注释必须保留")
        XCTAssertTrue(text.contains("[mcp_servers.node_repl]"), "其它表必须保留")
        XCTAssertTrue(text.contains("NODE_PATH = \"/opt/node\""), "嵌套表必须保留")
        XCTAssertTrue(text.contains("model_provider = \"my-deepseek\""))
        XCTAssertTrue(text.contains("[model_providers.my-deepseek]"))
        XCTAssertTrue(text.contains("name = \"My DeepSeek\""))

        let info = CodexProviderConfigStore.list(at: path)
        XCTAssertEqual(info.activeId, "my-deepseek")
        XCTAssertEqual(info.providers.count, 1)
        let provider = try XCTUnwrap(info.providers.first)
        XCTAssertEqual(provider.baseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(provider.wireApi, "responses")
        XCTAssertEqual(provider.apiKey, "sk-x")
        XCTAssertEqual(provider.model, "deepseek-chat")
        XCTAssertTrue(provider.active)
    }

    func testCodexRejectsReservedAndInvalidKeys() throws {
        let path = file("codex/config.toml")
        for reserved in ["openai", "ollama", "lmstudio"] {
            XCTAssertThrowsError(try CodexProviderConfigStore.save(
                CodexProviderEntry(id: reserved, name: "n", baseURL: "https://a.com"),
                at: path), "保留 id \(reserved) 必须拒绝")
        }
        for invalid in ["My-Key", "my_key", "-lead", "trail-", "double--dash", ""] {
            XCTAssertThrowsError(try CodexProviderConfigStore.save(
                CodexProviderEntry(id: invalid, name: "n", baseURL: "https://a.com"), at: path))
        }
        // 大小写不同 = 合法自定义 id
        XCTAssertNoThrow(try CodexProviderConfigStore.save(
            CodexProviderEntry(id: "openai-go", name: "n", baseURL: "https://a.com"), at: path))
    }

    func testCodexRequiresName() throws {
        let path = file("codex/config.toml")
        XCTAssertThrowsError(try CodexProviderConfigStore.save(
            CodexProviderEntry(id: "a", name: "  ", baseURL: "https://a.com"), at: path))
    }

    func testCodexDeleteClearsActivePointersAndEmptyParent() throws {
        let path = file("codex/config.toml")
        _ = try CodexProviderConfigStore.save(CodexProviderEntry(
            id: "a", name: "A", baseURL: "https://a.com", model: "m1"), at: path)
        let info = try CodexProviderConfigStore.delete(id: "a", at: path)

        XCTAssertEqual(info.activeId, "")
        XCTAssertTrue(info.providers.isEmpty)
        let text = try readText(path)
        XCTAssertFalse(text.contains("model_provider"), "删当前项要清掉调度指针")
        XCTAssertFalse(text.contains("[model_providers"), "空壳父表头应一并摘掉")
        XCTAssertFalse(text.contains("model = "), "删当前项要清掉顶层 model")
    }

    func testCodexActivateAndIdempotentDelete() throws {
        let path = file("codex/config.toml")
        _ = try CodexProviderConfigStore.save(CodexProviderEntry(
            id: "a", name: "A", baseURL: "https://a.com"), at: path)
        _ = try CodexProviderConfigStore.save(CodexProviderEntry(
            id: "b", name: "B", baseURL: "https://b.com"), at: path)
        XCTAssertEqual(CodexProviderConfigStore.list(at: path).activeId, "b")

        let info = try CodexProviderConfigStore.activate(id: "a", at: path)
        XCTAssertEqual(info.activeId, "a")

        // 激活不存在的 provider → 报错
        XCTAssertThrowsError(try CodexProviderConfigStore.activate(id: "zzz", at: path))
        // 幂等删除：不存在也视为成功
        XCTAssertNoThrow(try CodexProviderConfigStore.delete(id: "zzz", at: path))
    }

    // ═════════════════════════════════════════════════════════════════════════
    // MARK: - pi（增量模式 + 默认项成对）
    // ═════════════════════════════════════════════════════════════════════════

    func testPiSaveKeepsOtherRootKeysAndIsIncremental() throws {
        let modelsPath = file("pi/agent/models.json")
        let settingsPath = file("pi/agent/settings.json")
        try write("""
        { "$schema": "https://pi.dev/schema/models.json", "theme": "dark",
          "providers": { "kimi": { "baseUrl": "https://kimi.example", "api": "anthropic-messages",
                                   "models": [ { "id": "k2", "name": "K2" } ] } } }
        """, to: modelsPath)

        _ = try PiProviderConfigStore.save(PiProviderEntry(
            id: "my-ds", name: "My DS", baseURL: "https://ds.example",
            apiKey: "sk-1", api: "openai-completions",
            models: [PiModelEntry(id: "m1", name: "")]),
            modelsPath: modelsPath, settingsPath: settingsPath)

        let root = try readJSON(modelsPath)
        XCTAssertEqual(root["theme"] as? String, "dark", "根上其它键必须保留")
        XCTAssertEqual(root["$schema"] as? String, "https://pi.dev/schema/models.json")
        let providers = root["providers"] as? [String: Any] ?? [:]
        XCTAssertNotNil(providers["kimi"], "既有厂商必须保留")
        let mine = providers["my-ds"] as? [String: Any] ?? [:]
        XCTAssertEqual(mine["baseUrl"] as? String, "https://ds.example")
        XCTAssertEqual(mine["apiKey"] as? String, "sk-1")
        XCTAssertEqual(mine["api"] as? String, "openai-completions")
        // name 为空时回落 id
        let model = (mine["models"] as? [[String: Any]])?.first
        XCTAssertEqual(model?["name"] as? String, "m1")
    }

    func testPiRejectsNonObjectProviders() throws {
        let modelsPath = file("pi/agent/models.json")
        let settingsPath = file("pi/agent/settings.json")
        try write("{ \"providers\": [1,2] }", to: modelsPath)
        XCTAssertThrowsError(try PiProviderConfigStore.save(
            PiProviderEntry(id: "a", baseURL: "https://a.com", models: [PiModelEntry(id: "m")]),
            modelsPath: modelsPath, settingsPath: settingsPath),
            "providers 非对象必须报错（不静默重置）")
    }

    func testPiRequiresAtLeastOneModelAndValidApi() throws {
        let modelsPath = file("pi/agent/models.json")
        let settingsPath = file("pi/agent/settings.json")
        XCTAssertThrowsError(try PiProviderConfigStore.save(
            PiProviderEntry(id: "a", baseURL: "https://a.com", models: []),
            modelsPath: modelsPath, settingsPath: settingsPath))
        XCTAssertThrowsError(try PiProviderConfigStore.save(
            PiProviderEntry(id: "a", baseURL: "https://a.com", api: "bogus",
                            models: [PiModelEntry(id: "m")]),
            modelsPath: modelsPath, settingsPath: settingsPath))
    }

    func testPiActivateWritesDefaultPairAndDeleteClearsThem() throws {
        let modelsPath = file("pi/agent/models.json")
        let settingsPath = file("pi/agent/settings.json")
        try write("{ \"theme\": \"dark\" }", to: settingsPath)

        _ = try PiProviderConfigStore.save(PiProviderEntry(
            id: "a", baseURL: "https://a.com",
            models: [PiModelEntry(id: "m1"), PiModelEntry(id: "m2")]),
            modelsPath: modelsPath, settingsPath: settingsPath)

        let activated = try PiProviderConfigStore.activate(
            id: "a", model: nil, modelsPath: modelsPath, settingsPath: settingsPath)
        XCTAssertEqual(activated.defaultProvider, "a")
        XCTAssertEqual(activated.defaultModel, "m1", "未指定模型时取该家第一个")
        XCTAssertTrue(activated.providers.first?.isDefault ?? false)
        // settings 里用户的其它键不能丢
        let settings = try readJSON(settingsPath)
        XCTAssertEqual(settings["theme"] as? String, "dark")

        let deleted = try PiProviderConfigStore.delete(
            id: "a", modelsPath: modelsPath, settingsPath: settingsPath)
        XCTAssertEqual(deleted.defaultProvider, "")
        XCTAssertEqual(deleted.defaultModel, "", "删默认项时两个键必须一起清")
        let after = try readJSON(settingsPath)
        XCTAssertNil(after["defaultProvider"])
        XCTAssertNil(after["defaultModel"])
        XCTAssertEqual(after["theme"] as? String, "dark")
    }

    func testPiSaveRealignsDefaultModelWhenItDisappears() throws {
        let modelsPath = file("pi/agent/models.json")
        let settingsPath = file("pi/agent/settings.json")
        _ = try PiProviderConfigStore.save(PiProviderEntry(
            id: "a", baseURL: "https://a.com",
            models: [PiModelEntry(id: "m1"), PiModelEntry(id: "m2")]),
            modelsPath: modelsPath, settingsPath: settingsPath)
        _ = try PiProviderConfigStore.activate(
            id: "a", model: "m2", modelsPath: modelsPath, settingsPath: settingsPath)
        XCTAssertEqual(PiProviderConfigStore.list(
            modelsPath: modelsPath, settingsPath: settingsPath).defaultModel, "m2")

        // 把 m2 从模型清单里去掉 → defaultModel 必须自动对齐到仍存在的模型
        let info = try PiProviderConfigStore.save(PiProviderEntry(
            id: "a", baseURL: "https://a.com", models: [PiModelEntry(id: "m1")]),
            modelsPath: modelsPath, settingsPath: settingsPath)
        XCTAssertEqual(info.defaultModel, "m1", "默认模型消失时要自动对齐，不留悬空")
    }

    // ═════════════════════════════════════════════════════════════════════════
    // MARK: - OpenCode（深合并）
    // ═════════════════════════════════════════════════════════════════════════

    func testOpenCodeSaveDeepMergesAndKeepsRoot() throws {
        let path = file("opencode/opencode.json")
        try write("""
        { "$schema": "https://opencode.ai/config.json",
          "theme": "light",
          "mcp": { "pencil": { "enabled": true } },
          "provider": { "mimo": { "name": "MiMo", "npm": "@ai-sdk/openai-compatible",
                                  "options": { "baseURL": "https://x/v1",
                                               "headers": { "X-Trace": "on" } },
                                  "models": { "m1": { "name": "M1" } } } } }
        """, to: path)

        let info = try OpenCodeProviderConfigStore.save(OpenCodeProviderEntry(
            id: "mimo", name: "MiMo 2", baseURL: "https://x/v1/",
            apiKey: "sk-1", models: [OpenCodeModelEntry(id: "m1", name: "M1"),
                                     OpenCodeModelEntry(id: "m2", name: "")]), at: path)

        let root = try readJSON(path)
        XCTAssertEqual(root["theme"] as? String, "light", "根上其它键必须保留")
        XCTAssertNotNil(root["mcp"], "mcp 段必须保留")
        XCTAssertEqual(root["$schema"] as? String, "https://opencode.ai/config.json")

        let provider = try XCTUnwrap(info.providers.first { $0.id == "mimo" })
        XCTAssertEqual(provider.baseURL, "https://x/v1", "保存时要去掉尾部 /")
        XCTAssertEqual(provider.apiKey, "sk-1")
        XCTAssertEqual(provider.models.map(\.id), ["m1", "m2"])
        XCTAssertEqual(provider.models.first(where: { $0.id == "m2" })?.name, "m2",
                       "模型 name 为空回落 id")

        // options.headers 是前端不编辑的字段 —— 不能被静默删掉
        let options = ((root["provider"] as? [String: Any])?["mimo"] as? [String: Any])?["options"] as? [String: Any]
        XCTAssertEqual((options?["headers"] as? [String: Any])?["X-Trace"] as? String, "on")
    }

    func testOpenCodeRejectsInvalidKeyAndMissingFields() throws {
        let path = file("opencode/opencode.json")
        XCTAssertThrowsError(try OpenCodeProviderConfigStore.save(
            OpenCodeProviderEntry(id: "Bad Key", name: "n", baseURL: "https://a.com",
                                  models: [OpenCodeModelEntry(id: "m")]), at: path))
        XCTAssertThrowsError(try OpenCodeProviderConfigStore.save(
            OpenCodeProviderEntry(id: "a", name: "", baseURL: "https://a.com",
                                  models: [OpenCodeModelEntry(id: "m")]), at: path))
        XCTAssertThrowsError(try OpenCodeProviderConfigStore.save(
            OpenCodeProviderEntry(id: "a", name: "n", baseURL: "",
                                  models: [OpenCodeModelEntry(id: "m")]), at: path))
        XCTAssertThrowsError(try OpenCodeProviderConfigStore.save(
            OpenCodeProviderEntry(id: "a", name: "n", baseURL: "https://a.com", models: []),
            at: path))
    }

    func testOpenCodeMissingFileGetsSkeletonAndDeleteIsIdempotent() throws {
        let path = file("opencode/opencode.json")
        // 文件不存在时读取 → 空清单，不报错
        let info = OpenCodeProviderConfigStore.list(at: path)
        XCTAssertTrue(info.providers.isEmpty)
        XCTAssertFalse(info.exists)
        // 幂等删除
        XCTAssertNoThrow(try OpenCodeProviderConfigStore.delete(id: "nope", at: path))
        // 根非对象 → 写路径报错
        try write("\"just a string\"", to: path)
        XCTAssertThrowsError(try OpenCodeProviderConfigStore.save(
            OpenCodeProviderEntry(id: "a", name: "n", baseURL: "https://a.com",
                                  models: [OpenCodeModelEntry(id: "m")]), at: path))
    }

    // ═════════════════════════════════════════════════════════════════════════
    // MARK: - MiniTOML（保注释/格式的编辑器）
    // ═════════════════════════════════════════════════════════════════════════

    func testMiniTOMLKeepsUnrelatedLinesAndComments() {
        let source = """
        # head comment
        model = "m1"

        [model_providers.a]
        name = "A"   # trailing comment
        base_url = "https://a.com"
        """
        var doc = MiniTOML(text: source)
        doc.setTopString("model_provider", "a")
        doc.setTableString("model_providers.a", "name", "A2")

        let out = doc.text
        XCTAssertTrue(out.contains("# head comment"))
        XCTAssertTrue(out.contains("[model_providers.a]"))
        XCTAssertTrue(out.contains("base_url = \"https://a.com\""))
        XCTAssertTrue(out.contains("model = \"m1\""))
        XCTAssertTrue(out.contains("model_provider = \"a\""))
        XCTAssertTrue(out.contains("name = \"A2\""))
        XCTAssertFalse(out.contains("# trailing comment"), "被改写的那一行允许丢行尾注释")
    }

    func testMiniTOMLValueParsing() {
        XCTAssertEqual(MiniTOML.parseValue("\"https://a.com/v1\""), "https://a.com/v1")
        XCTAssertEqual(MiniTOML.parseValue("'literal'"), "literal")
        XCTAssertEqual(MiniTOML.parseValue("chat"), "chat")
        XCTAssertEqual(MiniTOML.parseValue("chat # c"), "chat")
        XCTAssertEqual(MiniTOML.parseValue("\"a\\\"b\""), "a\"b")
        XCTAssertEqual(MiniTOML.quote("a\"b\\c"), "\"a\\\"b\\\\c\"")
    }
}
