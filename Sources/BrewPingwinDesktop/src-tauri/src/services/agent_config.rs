//! 读取本机各 Agent 的**真实配置文件**，发现 Provider / Model。
//!
//! 这是 macOS `Sources/Agents/AgentConfigDiscovery.swift` 的 Windows 移植：
//! 同一批配置文件、同一套解析规则、同样的"只读、不修改、不伪造"原则。
//! 各 Agent 的配置格式与所在平台无关（都是 `~/.claude/settings.json` 这类路径），
//! 所以两侧能共用同一份判定逻辑。
//!
//! 为什么必须有它：iPhone / Watch 的"选择模型"入口数据**只**来自这里，
//! 没有这个接口时移动端只能拿到 `Set-Agent` 之类的间接信息，无法列出可选模型。

use serde::Serialize;
use std::path::{Path, PathBuf};

/// 一个可选模型（对应 macOS `BrewPingProtocol.Model`）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ProviderModel {
    pub id: String,
    pub name: String,
    pub available: bool,
    #[serde(rename = "isActive")]
    pub is_active: bool,
}

/// 一个 Provider 及其模型（对应 macOS `BrewPingProtocol.Provider`）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Provider {
    pub id: String,
    pub name: String,
    #[serde(rename = "baseURL", skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
    pub models: Vec<ProviderModel>,
}

/// `discover()` 的结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentProviders {
    pub agent_id: String,
    pub providers: Vec<Provider>,
    /// 配置文件里"正在用"的模型（不是用户偏好，偏好存在 `model_prefs`）。
    pub active_model_id: Option<String>,
}

impl AgentProviders {
    fn empty(agent_id: &str) -> Self {
        Self {
            agent_id: agent_id.to_string(),
            providers: Vec::new(),
            active_model_id: None,
        }
    }
}

/// 已知 Agent 的 id 列表（与 `agent_discovery::CATALOG` 保持一致）。
pub const SUPPORTED_AGENTS: &[&str] = &["opencode", "claude-code", "codex", "aider"];

/// 某个 agent id 是否在目录里（与 macOS `AgentDiscovery.catalog` 的用途一致）。
pub fn is_known_agent(agent_id: &str) -> bool {
    SUPPORTED_AGENTS.contains(&agent_id)
}

/// 读取指定 Agent 的真实配置，发现 Provider / Model。
///
/// 配置不存在 / 解不开时返回**空列表而不是错误** —— 与 macOS 行为一致：
/// "这台机器上没有配这个 Agent" 是正常状态，"没得选"由移动端按空列表隐藏入口处理。
pub fn discover(agent_id: &str) -> AgentProviders {
    match agent_id {
        "opencode" => read_opencode(),
        "claude-code" => read_claude_code(),
        "codex" => read_codex(),
        "aider" => read_aider(),
        _ => AgentProviders::empty(agent_id),
    }
}

// ─── OpenCode ────────────────────────────────────────────────────────────────
// 配置：~/.config/opencode/opencode.json
// 格式：{ "provider": { "<id>": { "name": "...", "models": { "<id>": { "name": "..." } },
//                              "options": { "baseURL": "..." } } } }

fn read_opencode() -> AgentProviders {
    let Some(content) = read_first(&opencode_paths()) else {
        return AgentProviders::empty("opencode");
    };
    parse_opencode(&content)
}

fn opencode_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Some(home) = dirs::home_dir() {
        paths.push(home.join(".config").join("opencode").join("opencode.json"));
    }
    // Windows 上也有人把配置放在 %APPDATA%\opencode\ 下，顺带认一下。
    if let Ok(app_data) = std::env::var("APPDATA") {
        paths.push(PathBuf::from(app_data).join("opencode").join("opencode.json"));
    }
    paths
}

fn parse_opencode(content: &str) -> AgentProviders {
    let Ok(root) = serde_json::from_str::<serde_json::Value>(content) else {
        return AgentProviders::empty("opencode");
    };
    let Some(providers_obj) = root.get("provider").and_then(|v| v.as_object()) else {
        return AgentProviders::empty("opencode");
    };

    let mut providers: Vec<Provider> = Vec::new();
    for (provider_id, provider_value) in providers_obj {
        let provider_name = provider_value
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or(provider_id)
            .to_string();
        let base_url = provider_value
            .get("options")
            .and_then(|v| v.get("baseURL"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());

        let mut models: Vec<ProviderModel> = Vec::new();
        if let Some(models_obj) = provider_value.get("models").and_then(|v| v.as_object()) {
            for (model_id, model_value) in models_obj {
                let model_name = model_value
                    .get("name")
                    .and_then(|v| v.as_str())
                    .unwrap_or(model_id)
                    .to_string();
                models.push(ProviderModel {
                    id: model_id.clone(),
                    name: model_name,
                    available: true,
                    is_active: false,
                });
            }
        }
        models.sort_by(|a, b| a.id.cmp(&b.id));

        providers.push(Provider {
            id: provider_id.clone(),
            name: provider_name,
            base_url,
            models,
        });
    }
    providers.sort_by(|a, b| a.id.cmp(&b.id));

    // 与 macOS 一致：首个 provider 的首个模型视作"当前正在用的"。
    let active_model_id = providers.first().and_then(|p| p.models.first()).map(|m| m.id.clone());

    AgentProviders {
        agent_id: "opencode".to_string(),
        providers,
        active_model_id,
    }
}

// ─── Claude Code ─────────────────────────────────────────────────────────────
// 配置：~/.claude/settings.json
//   env: { ANTHROPIC_BASE_URL, ANTHROPIC_DEFAULT_SONNET_MODEL, ... }
//   model: "sonnet" | "opus" | "haiku"（档位名）

fn read_claude_code() -> AgentProviders {
    let Some(content) = read_first(&claude_paths()) else {
        return AgentProviders::empty("claude-code");
    };
    parse_claude_code(&content)
}

fn claude_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Some(home) = dirs::home_dir() {
        paths.push(home.join(".claude").join("settings.json"));
    }
    paths
}

fn parse_claude_code(content: &str) -> AgentProviders {
    let Ok(root) = serde_json::from_str::<serde_json::Value>(content) else {
        return AgentProviders::empty("claude-code");
    };
    let Some(env) = root.get("env").and_then(|v| v.as_object()) else {
        return AgentProviders::empty("claude-code");
    };

    let env_str = |key: &str| env.get(key).and_then(|v| v.as_str()).map(|s| s.to_string());
    let base_url = env_str("ANTHROPIC_BASE_URL");
    let active_tier = root
        .get("model")
        .and_then(|v| v.as_str())
        .unwrap_or("sonnet")
        .to_string();

    // Claude Code 用环境变量把档位映射到真实模型：
    // ANTHROPIC_DEFAULT_SONNET_MODEL = claude-sonnet-4-6
    // ANTHROPIC_DEFAULT_SONNET_MODEL_NAME = glm-5.3-flash（实际展示名）
    let tiers: [(&str, &str, &str); 4] = [
        ("ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME", "sonnet"),
        ("ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME", "opus"),
        ("ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME", "haiku"),
        ("ANTHROPIC_DEFAULT_FABLE_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME", "fable"),
    ];

    let mut models: Vec<ProviderModel> = Vec::new();
    for (env_id, env_name, tier_name) in tiers {
        let Some(model_id) = env_str(env_id) else { continue };
        let display_name = env_str(env_name).unwrap_or_else(|| model_id.clone());
        models.push(ProviderModel {
            id: model_id,
            name: display_name,
            available: true,
            is_active: active_tier == tier_name,
        });
    }

    let provider_name = match &base_url {
        Some(base) => format!("Claude Proxy ({})", base),
        None => "Anthropic".to_string(),
    };
    let active_model_id = models
        .iter()
        .find(|m| m.is_active)
        .map(|m| m.id.clone())
        .or_else(|| models.first().map(|m| m.id.clone()));

    AgentProviders {
        agent_id: "claude-code".to_string(),
        providers: vec![Provider {
            id: "claude-proxy".to_string(),
            name: provider_name,
            base_url,
            models,
        }],
        active_model_id,
    }
}

// ─── Codex CLI ───────────────────────────────────────────────────────────────
// 配置：~/.codex/config.toml
//   model_provider = "custom"
//   model = "glm-5.2"
//   [model_providers.custom]
//   base_url = "http://..."
//   name = "..."

fn read_codex() -> AgentProviders {
    let Some(content) = read_first(&codex_paths()) else {
        return AgentProviders::empty("codex");
    };
    parse_codex_toml(&content)
}

fn codex_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Some(home) = dirs::home_dir() {
        paths.push(home.join(".codex").join("config.toml"));
    }
    paths
}

/// 极简 TOML 读取：只认 `key = value` 与 `[section]` 两类行。
/// 与 macOS 端同款做法 —— 够用即可，不引入 TOML 依赖。
fn parse_codex_toml(content: &str) -> AgentProviders {
    let mut current_section = String::new();
    let mut top_level: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    let mut sections: std::collections::HashMap<String, std::collections::HashMap<String, String>> =
        std::collections::HashMap::new();

    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix('[') {
            if let Some(end) = rest.find(']') {
                current_section = rest[..end].to_string();
            }
            continue;
        }
        let Some((key, value)) = trimmed.split_once('=') else { continue };
        let key = key.trim().to_string();
        let value = value.trim().trim_matches('"').trim().to_string();
        if current_section.is_empty() {
            top_level.insert(key, value);
        } else {
            sections
                .entry(current_section.clone())
                .or_default()
                .insert(key, value);
        }
    }

    let provider_id = top_level
        .get("model_provider")
        .cloned()
        .unwrap_or_else(|| "custom".to_string());
    let active_model_id = top_level.get("model").cloned();
    let provider_section = sections.get(&format!("model_providers.{}", provider_id));
    let base_url = provider_section.and_then(|s| s.get("base_url")).cloned();
    let provider_name = provider_section
        .and_then(|s| s.get("name"))
        .cloned()
        .unwrap_or_else(|| provider_id.clone());

    let mut models: Vec<ProviderModel> = Vec::new();
    if let Some(model_id) = &active_model_id {
        models.push(ProviderModel {
            id: model_id.clone(),
            name: model_id.clone(),
            available: true,
            is_active: true,
        });
    }

    AgentProviders {
        agent_id: "codex".to_string(),
        providers: vec![Provider {
            id: provider_id,
            name: provider_name,
            base_url,
            models,
        }],
        active_model_id,
    }
}

// ─── Aider ───────────────────────────────────────────────────────────────────
// 配置：~/.aider.conf.yml 或 ~/.config/aider/config.yml（yaml 里的 `model:` 一行）

fn read_aider() -> AgentProviders {
    let Some(content) = read_first(&aider_paths()) else {
        return AgentProviders::empty("aider");
    };
    parse_aider_yaml(&content)
}

fn aider_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Some(home) = dirs::home_dir() {
        paths.push(home.join(".aider.conf.yml"));
        paths.push(home.join(".config").join("aider").join("config.yml"));
    }
    paths
}

fn parse_aider_yaml(content: &str) -> AgentProviders {
    for line in content.lines() {
        let trimmed = line.trim();
        let Some(rest) = trimmed.strip_prefix("model:") else { continue };
        let model_id = rest.trim().trim_matches('"').trim_matches('\'').trim();
        if model_id.is_empty() {
            continue;
        }
        return AgentProviders {
            agent_id: "aider".to_string(),
            providers: vec![Provider {
                id: "aider-default".to_string(),
                name: "Aider Default".to_string(),
                base_url: None,
                models: vec![ProviderModel {
                    id: model_id.to_string(),
                    name: model_id.to_string(),
                    available: true,
                    is_active: true,
                }],
            }],
            active_model_id: Some(model_id.to_string()),
        };
    }
    AgentProviders::empty("aider")
}

// ─── 公共工具 ────────────────────────────────────────────────────────────────

/// 按顺序读第一个存在的文件。
fn read_first(paths: &[PathBuf]) -> Option<String> {
    paths.iter().find_map(|p| read_text(p))
}

fn read_text(path: &Path) -> Option<String> {
    if !path.is_file() {
        return None;
    }
    std::fs::read_to_string(path).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    // TC-AC-01  opencode：provider / models / baseURL 全部解析出来，且按 id 排序
    #[test]
    fn opencode_parses_providers_and_models() {
        let json = r#"{
            "provider": {
                "zhipu": {
                    "name": "Zhipu",
                    "options": { "baseURL": "https://open.bigmodel.cn/api/paas/v4" },
                    "models": { "glm-5.2": { "name": "GLM 5.2" }, "glm-5.3": { "name": "GLM 5.3" } }
                },
                "anthropic": { "name": "Anthropic", "models": { "claude-sonnet-4-6": { "name": "Sonnet" } } }
            }
        }"#;
        let result = parse_opencode(json);
        assert_eq!(result.agent_id, "opencode");
        assert_eq!(result.providers.len(), 2);
        assert_eq!(result.providers[0].id, "anthropic", "provider 必须按 id 排序");
        assert_eq!(result.providers[1].id, "zhipu");
        assert_eq!(
            result.providers[1].base_url.as_deref(),
            Some("https://open.bigmodel.cn/api/paas/v4")
        );
        let zhipu_models: Vec<&str> =
            result.providers[1].models.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(zhipu_models, vec!["glm-5.2", "glm-5.3"]);
        // 首个 provider 的首个模型 = active
        assert_eq!(result.active_model_id.as_deref(), Some("claude-sonnet-4-6"));
    }

    // TC-AC-02  opencode 边界：非法 JSON / 缺 provider 键 → 空列表且不 panic
    #[test]
    fn opencode_invalid_input_yields_empty() {
        assert!(parse_opencode("not json").providers.is_empty());
        assert!(parse_opencode("{}").providers.is_empty());
    }

    // TC-AC-03  claude-code：档位映射 + 当前档位标 isActive
    #[test]
    fn claude_code_maps_tiers() {
        let json = r#"{
            "model": "opus",
            "env": {
                "ANTHROPIC_BASE_URL": "http://127.0.0.1:3000",
                "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-6",
                "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME": "Sonnet Proxy",
                "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-7"
            }
        }"#;
        let result = parse_claude_code(json);
        assert_eq!(result.providers.len(), 1);
        let provider = &result.providers[0];
        assert_eq!(provider.id, "claude-proxy");
        assert_eq!(provider.name, "Claude Proxy (http://127.0.0.1:3000)");
        assert_eq!(provider.models.len(), 2);
        assert_eq!(provider.models[0].name, "Sonnet Proxy", "有 *_NAME 时用展示名");
        assert!(provider.models[1].is_active, "model=opus → opus 档位为 active");
        assert_eq!(result.active_model_id.as_deref(), Some("claude-opus-4-7"));
    }

    // TC-AC-04  codex：section 内取值，且当前 model 进列表
    #[test]
    fn codex_reads_section_and_top_level() {
        let toml = r#"
# 注释应被忽略
model_provider = "custom"
model = "glm-5.2"

[model_providers.custom]
name = "Zhipu"
base_url = "https://open.bigmodel.cn/api/paas/v4"
"#;
        let result = parse_codex_toml(toml);
        assert_eq!(result.providers[0].id, "custom");
        assert_eq!(result.providers[0].name, "Zhipu");
        assert_eq!(
            result.providers[0].base_url.as_deref(),
            Some("https://open.bigmodel.cn/api/paas/v4")
        );
        assert_eq!(result.providers[0].models.len(), 1);
        assert_eq!(result.providers[0].models[0].id, "glm-5.2");
        assert_eq!(result.active_model_id.as_deref(), Some("glm-5.2"));
    }

    // TC-AC-05  aider：只认 `model:` 一行，引号要剥掉
    #[test]
    fn aider_extracts_model_line() {
        let yaml = "# comment\nmodel: \"gpt-4o\"\nother: x\n";
        let result = parse_aider_yaml(yaml);
        assert_eq!(result.active_model_id.as_deref(), Some("gpt-4o"));
        assert_eq!(result.providers[0].models[0].name, "gpt-4o");

        assert!(parse_aider_yaml("other: x\n").providers.is_empty());
    }

    // TC-AC-06  未知 agent 返回空，不 panic（移动端据此隐藏入口）
    #[test]
    fn unknown_agent_is_empty() {
        let result = discover("no-such-agent");
        assert!(result.providers.is_empty());
        assert!(result.active_model_id.is_none());
        assert!(!is_known_agent("no-such-agent"));
        assert!(is_known_agent("opencode"));
    }

    // TC-AC-07  序列化契约：字段名必须是 baseURL / isActive（iOS ModelsResponse 依赖）
    #[test]
    fn provider_serializes_with_expected_keys() {
        let provider = Provider {
            id: "zhipu".into(),
            name: "Zhipu".into(),
            base_url: Some("http://x".into()),
            models: vec![ProviderModel {
                id: "glm-5.2".into(),
                name: "GLM 5.2".into(),
                available: true,
                is_active: false,
            }],
        };
        let v = serde_json::to_value(&provider).unwrap();
        assert!(v.get("baseURL").is_some(), "baseURL 必须是驼峰");
        assert!(v["models"][0].get("isActive").is_some(), "isActive 必须是驼峰");
        assert!(v["models"][0].get("available").is_some());
    }
}
