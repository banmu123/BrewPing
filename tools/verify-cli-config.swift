import Foundation

// 「厂商原生配置」四模块的不变量验证器。
//
// 为什么不是 XCTest：本机只有 Command Line Tools（无 Xcode），
// `import XCTest` / `import Testing` 都不可用。这里用普通 Swift 程序跑同一批断言，
// 由 `tools/verify-cli-config.sh` 把这 6 个模块源文件与本文件一起编译执行。
// 有 Xcode 的机器仍可跑 `swift test`（见 Tests/BrewPingCoreTests）。

var failures = 0
var checks = 0

func check(_ ok: Bool, _ label: String) {
    checks += 1
    if ok {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)")
    }
}

func expectThrows(_ label: String, _ body: () throws -> Void) {
    checks += 1
    do { try body(); failures += 1; print("  FAIL \(label)（本该抛错却成功）") }
    catch { print("  ok   \(label)") }
}

// 顶层语句只能出现在 `main.swift`；这里用 `@main` 包一层，文件名便不受限制。
@main
struct VerifyCLIConfig {
    static func main() throws {

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("brewping-verify-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

func path(_ name: String) -> URL { root.appendingPathComponent(name) }
func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}
func readJSON(_ url: URL) throws -> [String: Any] {
    (try JSONSerialization.jsonObject(with: try Data(contentsOf: url))) as? [String: Any] ?? [:]
}
func readText(_ url: URL) throws -> String {
    String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
}

// ═══ 1. Claude ═══════════════════════════════════════════════════════════════
print("[Claude] env 就地合并 / sanitize / 清空即删除")
do {
    let p = path("claude/settings.json")
    try write("""
    {
      "env": { "DISABLE_TELEMETRY": "1", "MCP_TIMEOUT": "30000", "api_format": "openai_chat" },
      "apiFormat": "x",
      "permissions": { "allow": ["mcp__pencil"] },
      "theme": "light"
    }
    """, to: p)

    _ = try ClaudeConfigStore.save(ClaudeProviderEntry(
        baseURL: "https://api.example.com/anthropic", apiKey: "sk-test",
        tiers: [ClaudeTierEntry(tier: "sonnet", model: "m-1", name: "M1")]), at: p)

    let r = try readJSON(p)
    let env = r["env"] as? [String: Any] ?? [:]
    check(env["DISABLE_TELEMETRY"] as? String == "1", "env 里用户原有键存活（就地合并）")
    check(env["MCP_TIMEOUT"] as? String == "30000", "env 里第二个用户键也存活")
    check(env["ANTHROPIC_BASE_URL"] as? String == "https://api.example.com/anthropic", "写入 BASE_URL")
    check(env["ANTHROPIC_AUTH_TOKEN"] as? String == "sk-test", "写入 AUTH_TOKEN")
    check(env["ANTHROPIC_DEFAULT_SONNET_MODEL"] as? String == "m-1", "写入档位 model")
    check(env["ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"] as? String == "M1", "写入档位 name")
    check(r["permissions"] != nil && r["theme"] as? String == "light", "顶层其它键存活")
    check(r["api_format"] == nil, "顶层 cc-switch 元字段被剥离")
    check(env["api_format"] == nil, "env 内元字段被剥离")

    let info = ClaudeConfigStore.get(at: p)
    check(info.configured && info.provider.tiers.count == 1, "读回：configured + 1 档")
    check(info.provider.otherKeys.contains("permissions"), "读回 otherKeys 列出被保留的顶层键")

    // 语义：**前端总是提交三档**，未用的档位传空串 → 空串 = 删除该键。
    //（契约是"只处理 entry 里出现的档位"，所以 UI 必须把三档都带上。）
    _ = try ClaudeConfigStore.save(ClaudeProviderEntry(
        baseURL: "https://api.example.com/anthropic", apiKey: "sk-test",
        tiers: [ClaudeTierEntry(tier: "sonnet", model: "m-1", name: "M1"),
                ClaudeTierEntry(tier: "opus", model: "m-2", name: "M2"),
                ClaudeTierEntry(tier: "haiku", model: "", name: "")]), at: p)
    _ = try ClaudeConfigStore.save(ClaudeProviderEntry(
        baseURL: "https://api.example.com/anthropic", apiKey: "sk-test",
        tiers: [ClaudeTierEntry(tier: "sonnet", model: "m-1", name: "M1"),
                ClaudeTierEntry(tier: "opus", model: "", name: ""),
                ClaudeTierEntry(tier: "haiku", model: "", name: "")]), at: p)
    let env2 = (try readJSON(p))["env"] as? [String: Any] ?? [:]
    check(env2["ANTHROPIC_DEFAULT_SONNET_MODEL"] as? String == "m-1", "档位 model 保留")
    check(env2["ANTHROPIC_DEFAULT_OPUS_MODEL"] == nil, "某档传空串 = 删除该键（不留旧值）")
    check(env2["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"] == nil, "该档的 _NAME 也删掉")

    expectThrows("空 baseURL 必须报错") {
        _ = try ClaudeConfigStore.save(ClaudeProviderEntry(baseURL: "", apiKey: "k"), at: p)
    }
    expectThrows("非 http(s) 必须报错") {
        _ = try ClaudeConfigStore.save(ClaudeProviderEntry(baseURL: "ftp://a.com"), at: p)
    }
}

do {
    let p = path("claude2/settings.json")
    try write("""
    { "env": { "ANTHROPIC_BASE_URL": "https://a.com", "ANTHROPIC_AUTH_TOKEN": "k",
               "ANTHROPIC_DEFAULT_SONNET_MODEL": "m", "DISABLE_TELEMETRY": "1" },
      "theme": "light" }
    """, to: p)
    let info = try ClaudeConfigStore.delete(at: p)
    let r = try readJSON(p)
    let env = r["env"] as? [String: Any] ?? [:]
    check(!info.configured, "删除后 configured=false")
    check(r["theme"] as? String == "light", "删除不带走用户设置")
    check(env["ANTHROPIC_BASE_URL"] == nil && env["ANTHROPIC_AUTH_TOKEN"] == nil, "厂商键被摘掉")
    check(env["DISABLE_TELEMETRY"] as? String == "1", "env 内其余键保留")

    let p2 = path("claude3/settings.json")
    try write("{ \"env\": { \"ANTHROPIC_BASE_URL\": \"https://a.com\" } }", to: p2)
    _ = try ClaudeConfigStore.delete(at: p2)
    check((try readJSON(p2))["env"] == nil, "env 摘空后整个键移除")

    let p3 = path("claude4/settings.json")
    try write("[1,2,3]", to: p3)
    check(!ClaudeConfigStore.get(at: p3).configured, "根非对象时读取降级不抛错")
    expectThrows("根非对象时写入必须报错") {
        _ = try ClaudeConfigStore.save(ClaudeProviderEntry(baseURL: "https://a.com"), at: p3)
    }
}

// ═══ 2. Codex ════════════════════════════════════════════════════════════════
print("[Codex] TOML 保注释 / 保留 id / 删除清指针")
do {
    let p = path("codex/config.toml")
    try write("""
    # 我的 Codex 配置
    model = "old-model"

    [mcp_servers.node_repl]
    command = "/usr/bin/node"
    startup_timeout_sec = 120

    [mcp_servers.node_repl.env]
    NODE_PATH = "/opt/node"
    """, to: p)

    _ = try CodexProviderConfigStore.save(CodexProviderEntry(
        id: "my-deepseek", name: "My Deep Seek", baseURL: "https://api.deepseek.com/v1",
        wireApi: "responses", apiKey: "sk-x", model: "deepseek-chat"), at: p)

    let text = try readText(p)
    check(text.contains("# 我的 Codex 配置"), "注释保留")
    check(text.contains("[mcp_servers.node_repl]"), "其它表保留")
    check(text.contains("NODE_PATH = \"/opt/node\""), "嵌套表保留")
    check(text.contains("command = \"/usr/bin/node\""), "其它表字段保留")
    check(text.contains("model_provider = \"my-deepseek\""), "写入顶层 model_provider")
    check(text.contains("[model_providers.my-deepseek]"), "写新区块")
    check(text.contains("name = \"My Deep Seek\""), "写入 name")

    let info = CodexProviderConfigStore.list(at: p)
    check(info.activeId == "my-deepseek", "activeId 正确")
    let provider = info.providers.first
    check(info.providers.count == 1, "provider 数 = 1")
    check(provider?.name == "My Deep Seek", "name 读回（含空格）")
    check(provider?.baseURL == "https://api.deepseek.com/v1", "base_url 读回")
    check(provider?.wireApi == "responses", "wire_api 读回")
    check(provider?.apiKey == "sk-x", "token 读回")
    check(provider?.model == "deepseek-chat", "顶层 model 归属当前生效项")
    check(provider?.active == true, "active 标记正确")

    for reserved in ["openai", "ollama", "lmstudio"] {
        expectThrows("保留 id \(reserved) 被拒绝") {
            _ = try CodexProviderConfigStore.save(CodexProviderEntry(
                id: reserved, name: "n", baseURL: "https://a.com"), at: p)
        }
    }
    for invalid in ["My-Key", "my_key", "-lead", "trail-", "double--dash", ""] {
        expectThrows("非法 key '\(invalid)' 被拒绝") {
            _ = try CodexProviderConfigStore.save(CodexProviderEntry(
                id: invalid, name: "n", baseURL: "https://a.com"), at: p)
        }
    }
    expectThrows("name 为空被拒绝") {
        _ = try CodexProviderConfigStore.save(CodexProviderEntry(
            id: "ok-id", name: "  ", baseURL: "https://a.com"), at: p)
    }
}

do {
    let p = path("codex2/config.toml")
    _ = try CodexProviderConfigStore.save(CodexProviderEntry(
        id: "a", name: "A", baseURL: "https://a.com", model: "m1"), at: p)
    _ = try CodexProviderConfigStore.save(CodexProviderEntry(
        id: "b", name: "B", baseURL: "https://b.com"), at: p)
    check(CodexProviderConfigStore.list(at: p).activeId == "b", "后保存的成为当前")
    check(try CodexProviderConfigStore.activate(id: "a", at: p).activeId == "a", "activate 切当前")
    expectThrows("activate 不存在的项报错") {
        _ = try CodexProviderConfigStore.activate(id: "zzz", at: p)
    }
    let after = try CodexProviderConfigStore.delete(id: "a", at: p)
    check(after.activeId == "", "删除当前项后 activeId 清空")
    check(after.providers.count == 1, "只删掉目标项")
    let text = try readText(p)
    check(!text.contains("model = "), "删除当前项时顶层 model 一并清")
    // 幂等
    _ = try CodexProviderConfigStore.delete(id: "zzz", at: p)
    check(true, "删除不存在的项幂等不报错")
}

do {
    let p = path("codex3/config.toml")
    _ = try CodexProviderConfigStore.save(CodexProviderEntry(
        id: "only", name: "Only", baseURL: "https://a.com"), at: p)
    _ = try CodexProviderConfigStore.delete(id: "only", at: p)
    let text = try readText(p)
    check(!text.contains("[model_providers"), "最后一个 provider 删掉后空壳表头也摘掉")
    check(!text.contains("model_provider"), "调度指针清空")
}

// ═══ 3. pi ═══════════════════════════════════════════════════════════════════
print("[pi] 增量模式 / 默认项成对")
do {
    let models = path("pi/agent/models.json")
    let settings = path("pi/agent/settings.json")
    try write("""
    { "$schema": "https://pi.dev/schema/models.json", "theme": "dark",
      "providers": { "kimi": { "baseUrl": "https://kimi.example", "api": "anthropic-messages",
                               "models": [ { "id": "k2", "name": "K2" } ] } } }
    """, to: models)

    _ = try PiProviderConfigStore.save(PiProviderEntry(
        id: "my-ds", name: "My DS", baseURL: "https://ds.example", apiKey: "sk-1",
        api: "openai-completions", models: [PiModelEntry(id: "m1", name: "")]),
        modelsPath: models, settingsPath: settings)

    let r = try readJSON(models)
    check(r["theme"] as? String == "dark", "根上其它键保留（增量模式）")
    check(r["$schema"] as? String == "https://pi.dev/schema/models.json", "$schema 保留")
    let providers = r["providers"] as? [String: Any] ?? [:]
    check(providers["kimi"] != nil, "既有厂商保留")
    let mine = providers["my-ds"] as? [String: Any] ?? [:]
    check(mine["baseUrl"] as? String == "https://ds.example", "字段名是 baseUrl（小写 u）")
    check(mine["apiKey"] as? String == "sk-1", "apiKey 写入")
    check(mine["api"] as? String == "openai-completions", "api 写入")
    check((mine["models"] as? [[String: Any]])?.first?["name"] as? String == "m1",
          "model name 为空回落 id")

    expectThrows("providers 非对象必须报错") {
        let bad = path("pi2/agent/models.json")
        try write("{ \"providers\": [1,2] }", to: bad)
        _ = try PiProviderConfigStore.save(PiProviderEntry(
            id: "a", baseURL: "https://a.com", models: [PiModelEntry(id: "m")]),
            modelsPath: bad, settingsPath: path("pi2/agent/settings.json"))
    }
    expectThrows("无模型必须报错") {
        _ = try PiProviderConfigStore.save(PiProviderEntry(
            id: "a", baseURL: "https://a.com", models: []),
            modelsPath: models, settingsPath: settings)
    }
    expectThrows("非法 api 必须报错") {
        _ = try PiProviderConfigStore.save(PiProviderEntry(
            id: "a", baseURL: "https://a.com", api: "bogus", models: [PiModelEntry(id: "m")]),
            modelsPath: models, settingsPath: settings)
    }
}

do {
    let models = path("pi3/agent/models.json")
    let settings = path("pi3/agent/settings.json")
    try write("{ \"theme\": \"dark\" }", to: settings)
    _ = try PiProviderConfigStore.save(PiProviderEntry(
        id: "a", baseURL: "https://a.com",
        models: [PiModelEntry(id: "m1"), PiModelEntry(id: "m2")]),
        modelsPath: models, settingsPath: settings)

    let act = try PiProviderConfigStore.activate(
        id: "a", model: nil, modelsPath: models, settingsPath: settings)
    check(act.defaultProvider == "a" && act.defaultModel == "m1", "未指定模型时取第一个（成对）")
    check(act.providers.first?.isDefault == true, "isDefault 标记")
    check((try readJSON(settings))["theme"] as? String == "dark", "settings 其它键保留")

    let aligned = try PiProviderConfigStore.save(PiProviderEntry(
        id: "a", baseURL: "https://a.com", models: [PiModelEntry(id: "m1")]),
        modelsPath: models, settingsPath: settings)
    let _ = aligned  // m1 仍存在，defaultModel 不动
    _ = try PiProviderConfigStore.activate(
        id: "a", model: "m1", modelsPath: models, settingsPath: settings)

    let del = try PiProviderConfigStore.delete(
        id: "a", modelsPath: models, settingsPath: settings)
    check(del.defaultProvider == "" && del.defaultModel == "", "删默认项时两键一起清")
    let after = try readJSON(settings)
    check(after["defaultProvider"] == nil && after["defaultModel"] == nil, "不留悬空默认项")
    check(after["theme"] as? String == "dark", "清理默认项不动其它键")
}

// ═══ 4. OpenCode ═════════════════════════════════════════════════════════════
print("[OpenCode] 深合并 / 尾部斜杠 / headers 保留")
do {
    let p = path("opencode/opencode.json")
    try write("""
    { "$schema": "https://opencode.ai/config.json",
      "theme": "light",
      "mcp": { "pencil": { "enabled": true } },
      "provider": { "mimo": { "name": "MiMo", "npm": "@ai-sdk/openai-compatible",
                              "options": { "baseURL": "https://x/v1",
                                           "headers": { "X-Trace": "on" } },
                              "models": { "m1": { "name": "M1" } } } } }
    """, to: p)

    let info = try OpenCodeProviderConfigStore.save(OpenCodeProviderEntry(
        id: "mimo", name: "MiMo 2", baseURL: "https://x/v1/", apiKey: "sk-1",
        models: [OpenCodeModelEntry(id: "m1", name: "M1"),
                 OpenCodeModelEntry(id: "m2", name: "")]), at: p)

    let r = try readJSON(p)
    check(r["theme"] as? String == "light", "根上其它键保留（深合并铁律）")
    check(r["mcp"] != nil, "mcp 段保留")
    check(r["$schema"] as? String == "https://opencode.ai/config.json", "$schema 保留")
    let mimo = info.providers.first { $0.id == "mimo" }
    check(mimo?.baseURL == "https://x/v1", "保存时去掉尾部 /")
    check(mimo?.apiKey == "sk-1", "apiKey 写入")
    check(mimo?.models.map(\.id) == ["m1", "m2"], "模型按 id 排序")
    check(mimo?.models.first { $0.id == "m2" }?.name == "m2", "模型 name 为空回落 id")
    let options = ((r["provider"] as? [String: Any])?["mimo"] as? [String: Any])?["options"] as? [String: Any]
    check((options?["headers"] as? [String: Any])?["X-Trace"] as? String == "on",
          "前端不编辑的 options.headers 未被静默删除")

    expectThrows("非法 key 被拒绝") {
        _ = try OpenCodeProviderConfigStore.save(OpenCodeProviderEntry(
            id: "Bad Key", name: "n", baseURL: "https://a.com",
            models: [OpenCodeModelEntry(id: "m")]), at: p)
    }
    expectThrows("name 为空被拒绝") {
        _ = try OpenCodeProviderConfigStore.save(OpenCodeProviderEntry(
            id: "ok", name: "", baseURL: "https://a.com",
            models: [OpenCodeModelEntry(id: "m")]), at: p)
    }
    expectThrows("无模型被拒绝") {
        _ = try OpenCodeProviderConfigStore.save(OpenCodeProviderEntry(
            id: "ok", name: "n", baseURL: "https://a.com", models: []), at: p)
    }

    let missing = path("opencode-missing/opencode.json")
    check(OpenCodeProviderConfigStore.list(at: missing).providers.isEmpty, "文件缺失时读取不报错")
    _ = try OpenCodeProviderConfigStore.delete(id: "nope", at: missing)
    check(true, "删除不存在的项幂等")

    let notObject = path("opencode-bad/opencode.json")
    try write("\"just a string\"", to: notObject)
    expectThrows("根非对象时写入报错") {
        _ = try OpenCodeProviderConfigStore.save(OpenCodeProviderEntry(
            id: "a", name: "n", baseURL: "https://a.com",
            models: [OpenCodeModelEntry(id: "m")]), at: notObject)
    }
}

// ═══ 5. MiniTOML ═════════════════════════════════════════════════════════════
print("[MiniTOML] 保注释 / 值解析")
do {
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
    check(out.contains("# head comment"), "文件头注释保留")
    check(out.contains("[model_providers.a]"), "表头保留")
    check(out.contains("base_url = \"https://a.com\""), "未触碰的字段原样保留")
    check(out.contains("model = \"m1\""), "顶层键保留")
    check(out.contains("model_provider = \"a\""), "新增顶层键")
    check(out.contains("name = \"A2\""), "字段被改写")

    check(MiniTOML.parseValue("\"https://a.com/v1\"") == "https://a.com/v1", "解析双引号值")
    check(MiniTOML.parseValue("'literal'") == "literal", "解析字面量值")
    check(MiniTOML.parseValue("chat # c") == "chat", "裸值截掉行内注释")
    check(MiniTOML.parseValue("\"a\\\"b\"") == "a\"b", "解析转义")
    check(MiniTOML.quote("a\"b\\c") == "\"a\\\"b\\\\c\"", "序列化转义")
    check(MiniTOML.parseValue("\"https://a.com/#frag\"") == "https://a.com/#frag",
          "引号值里的 # 是内容，不是注释")
}

print("")
print(failures == 0
      ? "✅ 全部通过：\(checks) 项断言"
      : "❌ 失败 \(failures) / \(checks) 项断言")
exit(failures == 0 ? 0 : 1)

    }
}
