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
    /// 配置指纹（所读配置文件的 `mtime_nanos:size`，多个文件用 `|` 连接）。
    ///
    /// 用途：调用方（桌面端 `App.tsx` / iOS `ModelStore`）把本值并进自己的
    /// "要不要重新拉"判定键里 —— 否则「用户在设置里加了厂商 → 关掉设置 →
    /// 新建对话」这条路径上，界面会一直用旧列表（因为 agent 没变，
    /// 依赖数组不触发），表现为**新加的模型在列表里消失**。
    ///
    /// 空串 = 没有任何配置文件（此时列表本身也是空的）。
    pub config_version: String,
}

impl AgentProviders {
    fn empty(agent_id: &str) -> Self {
        Self {
            agent_id: agent_id.to_string(),
            providers: Vec::new(),
            active_model_id: None,
            config_version: String::new(),
        }
    }
}

/// 已知 Agent 的 id 列表（与 `agent_discovery::CATALOG` 保持一致）。
pub const SUPPORTED_AGENTS: &[&str] = &["opencode", "claude-code", "codex", "pi"];

/// 某个 agent id 是否在目录里（与 macOS `AgentDiscovery.catalog` 的用途一致）。
pub fn is_known_agent(agent_id: &str) -> bool {
    SUPPORTED_AGENTS.contains(&agent_id)
}

/// 读取指定 Agent 的真实配置，发现 Provider / Model。
///
/// 配置不存在 / 解不开时返回**空列表而不是错误** —— 与 macOS 行为一致：
/// "这台机器上没有配这个 Agent" 是正常状态，"没得选"由移动端按空列表隐藏入口处理。
pub fn discover(agent_id: &str) -> AgentProviders {
    let mut result = match agent_id {
        "opencode" => read_opencode(),
        "claude-code" => read_claude_code(),
        "codex" => read_codex(),
        "pi" => read_pi(),
        _ => AgentProviders::empty(agent_id),
    };
    // 指纹统一在出口算，各 parse_* 不必各自关心。
    result.config_version = config_version_for(agent_id);
    result
}

/// 该 Agent 所读**全部**配置文件的指纹（`mtime_nanos:size`，多文件 `|` 连接）。
///
/// 为什么纳入"全部候选路径"而不是只有实际读到的那一个：用户在
/// `~/.config/opencode/` 与 `%APPDATA%\opencode\` 之间搬动文件时，
/// 指纹必须跟着变，否则前端会继续用旧列表。
/// 不存在的文件记 `-`，保证"文件被删除"也能让指纹变化。
fn config_version_for(agent_id: &str) -> String {
    let paths = match agent_id {
        "opencode" => opencode_paths(),
        "claude-code" => claude_paths(),
        "codex" => codex_paths(),
        // pi 是「settings + models」两份，任一变化都要重拉。
        "pi" => {
            let mut v = pi_settings_paths();
            v.extend(pi_models_paths());
            v
        }
        _ => Vec::new(),
    };

    paths
        .iter()
        .map(|p| match std::fs::metadata(p) {
            Ok(md) => {
                let mtime = md
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_nanos())
                    .unwrap_or(0);
                format!("{}:{}", mtime, md.len())
            }
            Err(_) => "-".to_string(),
        })
        .collect::<Vec<_>>()
        .join("|")
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
        config_version: String::new(),
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
        config_version: String::new(),
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
        config_version: String::new(),
    }
}

// ─── pi ──────────────────────────────────────────────────────────────────────
// 配置：~/.pi/agent/settings.json（defaultProvider / defaultModel，成对生效）
//      + ~/.pi/agent/models.json（providers.<id>.baseUrl / .models[].id|name）
// 代理接管时 settings.defaultProvider = "brewping"（cli_takeover 写入），
// 这里只读不改，把真实默认如实暴露给移动端。

fn read_pi() -> AgentProviders {
    let Some(settings_content) = read_first(&pi_settings_paths()) else {
        return AgentProviders::empty("pi");
    };
    let models_content = read_first(&pi_models_paths());
    parse_pi(&settings_content, models_content.as_deref())
}

fn pi_settings_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Some(home) = dirs::home_dir() {
        paths.push(home.join(".pi").join("agent").join("settings.json"));
    }
    paths
}

fn pi_models_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Some(home) = dirs::home_dir() {
        paths.push(home.join(".pi").join("agent").join("models.json"));
    }
    paths
}

fn parse_pi(settings_content: &str, models_content: Option<&str>) -> AgentProviders {
    let Ok(settings) = serde_json::from_str::<serde_json::Value>(settings_content) else {
        return AgentProviders::empty("pi");
    };
    let default_provider = settings
        .get("defaultProvider")
        .and_then(|v| v.as_str())
        .map(str::to_string);
    let active_model_id = settings
        .get("defaultModel")
        .and_then(|v| v.as_str())
        .map(str::to_string);
    let Some(models_content) = models_content else {
        return AgentProviders::empty("pi");
    };
    let Ok(root) = serde_json::from_str::<serde_json::Value>(models_content) else {
        return AgentProviders::empty("pi");
    };
    let Some(providers_obj) = root.get("providers").and_then(|v| v.as_object()) else {
        return AgentProviders::empty("pi");
    };

    let mut providers: Vec<Provider> = Vec::new();
    for (provider_id, provider_value) in providers_obj {
        let base_url = provider_value
            .get("baseUrl")
            .and_then(|v| v.as_str())
            .map(str::to_string);
        let mut models: Vec<ProviderModel> = Vec::new();
        if let Some(models_arr) = provider_value.get("models").and_then(|v| v.as_array()) {
            for model_value in models_arr {
                let Some(model_id) = model_value.get("id").and_then(|v| v.as_str()) else {
                    continue;
                };
                let model_name = model_value
                    .get("name")
                    .and_then(|v| v.as_str())
                    .unwrap_or(model_id)
                    .to_string();
                models.push(ProviderModel {
                    id: model_id.to_string(),
                    name: model_name,
                    available: true,
                    is_active: active_model_id.as_deref() == Some(model_id),
                });
            }
        }
        models.sort_by(|a, b| a.id.cmp(&b.id));
        providers.push(Provider {
            id: provider_id.clone(),
            name: provider_id.clone(),
            base_url,
            models,
        });
    }
    providers.sort_by(|a, b| a.id.cmp(&b.id));

    AgentProviders {
        agent_id: "pi".to_string(),
        providers,
        // 当前正在用的模型 = settings.defaultModel（未设置则回落 None）
        active_model_id,
        config_version: String::new(),
    }
}

// ─── 公共工具 ────────────────────────────────────────────────────────────────

/// 按顺序读第一个存在的文件。
fn read_first(paths: &[PathBuf]) -> Option<String> {
    paths.iter().find_map(|p| read_text(p))
}

/// 读一个配置文件并**剥掉 UTF-8 BOM**。
///
/// 为什么必须在这里剥：Windows 上大量编辑器（记事本、Windows PowerShell 5.1 的
/// `Set-Content -Encoding utf8`、部分 VS Code 配置）保存 JSON 时会带 BOM
/// （首 3 字节 `EF BB BF`）。`serde_json` 遇到 BOM 直接解析失败，而各 `parse_*`
/// 在解析失败时都是**静默返回空 providers**（与 macOS 行为一致：解不开 = 没得选）。
/// 结果就是用户手改了一次配置，App 里所有模型突然全没了，且没有任何报错 ——
/// 实测踩过（2026-09-14 做指纹验证时用 `Set-Content` 写回，直接把用户配置读空了）。
///
/// 这里统一剥 BOM 而不是各 `parse_*` 各自处理：`read_text` 是全部四个 Agent
/// 读配置的唯一入口，改一处即可全覆盖。
fn read_text(path: &Path) -> Option<String> {
    if !path.is_file() {
        return None;
    }
    let raw = std::fs::read_to_string(path).ok()?;
    Some(strip_bom(&raw).to_string())
}

/// 去掉行首的 UTF-8 BOM（`U+FEFF`）。
///
/// 只剥**开头那一个** —— BOM 按规范只允许出现在文件最前面，中间的 `U+FEFF`
/// 可能是用户内容里的零宽不换行空格，不该动。`trim_start_matches` 会连着剥多个，
/// 语义上略有偏差，所以这里显式判断一次。
fn strip_bom(content: &str) -> &str {
    content.strip_prefix('\u{feff}').unwrap_or(content)
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

    // TC-AC-05  pi：settings 默认 + models.json providers 全解析，isActive 标默认
    #[test]
    fn pi_parses_settings_and_models() {
        let settings = r#"{"defaultProvider":"brewping","defaultModel":"brewping-default"}"#;
        let models = r#"{
            "providers": {
                "brewping": {
                    "baseUrl": "http://127.0.0.1:15721/pi",
                    "apiKey": "brewping-proxy",
                    "api": "anthropic-messages",
                    "models": [ { "id": "brewping-default", "name": "BrewPing (proxied)" } ]
                },
                "ollama": { "baseUrl": "http://localhost:11434/v1", "models": [ { "id": "q" } ] }
            }
        }"#;
        let result = parse_pi(settings, Some(models));
        assert_eq!(result.agent_id, "pi");
        assert_eq!(result.providers.len(), 2, "providers 按 id 排序");
        assert_eq!(result.providers[0].id, "brewping");
        assert_eq!(
            result.providers[0].base_url.as_deref(),
            Some("http://127.0.0.1:15721/pi")
        );
        assert_eq!(result.providers[0].models[0].id, "brewping-default");
        assert!(result.providers[0].models[0].is_active, "默认模型必须标 isActive");
        assert!(!result.providers[1].models[0].is_active);
        assert_eq!(result.active_model_id.as_deref(), Some("brewping-default"));

        // 边界：settings 非法 / models 缺失 → 空
        assert!(parse_pi("not json", Some(models)).providers.is_empty());
        assert!(parse_pi(settings, None).providers.is_empty());
    }

    // TC-AC-06  未知 agent 返回空，不 panic（移动端据此隐藏入口）
    #[test]
    fn unknown_agent_is_empty() {
        let result = discover("no-such-agent");
        assert!(result.providers.is_empty());
        assert!(result.active_model_id.is_none());
        assert!(result.config_version.is_empty(), "未知 agent 无配置文件 → 空指纹");
        assert!(!is_known_agent("no-such-agent"));
        assert!(is_known_agent("opencode"));
    }

    // TC-AC-08  配置指纹：文件内容变化 → 指纹变化；不存在 → 记录为 "-"
    //
    // 这是「加完厂商新模型不出现」那个 bug 的回归防线：前端靠指纹变化触发重拉。
    #[test]
    fn config_version_changes_when_file_changes() {
        let dir = std::env::temp_dir().join(format!(
            "brewping-acv-{}",
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("opencode.json");

        // 不存在 → "-"（且必须与"存在但空"区分得开）
        let missing = {
            let paths = vec![file.clone()];
            paths
                .iter()
                .map(|p| match std::fs::metadata(p) {
                    Ok(md) => format!("{}:{}", 0, md.len()),
                    Err(_) => "-".to_string(),
                })
                .collect::<Vec<_>>()
                .join("|")
        };
        assert_eq!(missing, "-");

        // 写入 → 有指纹
        std::fs::write(&file, r#"{"provider":{}}"#).unwrap();
        let (first, len1) = {
            let md = std::fs::metadata(&file).unwrap();
            (
                format!("{}:{}", md.modified().unwrap().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos(), md.len()),
                md.len(),
            )
        };
        assert_ne!(first, "-");
        // size 必须被纳入（尾部就是文件真实字节数），不硬编码长度以免文案一动就红
        assert!(
            first.ends_with(&format!(":{len1}")),
            "size 应被纳入指纹: {first}"
        );

        // 改内容（长度也变）→ 指纹必须变
        std::fs::write(&file, r#"{"provider":{"xiaomi":{}}}"#).unwrap();
        let second = {
            let md = std::fs::metadata(&file).unwrap();
            format!("{}:{}", md.modified().unwrap().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos(), md.len())
        };
        assert_ne!(first, second, "文件变化后指纹必须变化");

        std::fs::remove_dir_all(&dir).ok();
    }

    // TC-AC-09  指纹包含 size：内容变化但 mtime 精度不足时仍能区分
    #[test]
    fn config_version_includes_size() {
        let dir = std::env::temp_dir().join(format!(
            "brewping-acv2-{}",
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("a.json");
        std::fs::write(&file, "1").unwrap();
        let md1 = std::fs::metadata(&file).unwrap();
        std::fs::write(&file, "123456").unwrap();
        let md2 = std::fs::metadata(&file).unwrap();
        assert_ne!(md1.len(), md2.len());
        // 只要 size 进了指纹，二者就必然不同（不依赖 mtime 精度）
        let f1 = format!("{}:{}", 0u128, md1.len());
        let f2 = format!("{}:{}", 0u128, md2.len());
        assert_ne!(f1, f2);
        std::fs::remove_dir_all(&dir).ok();
    }

    // TC-AC-10  带 UTF-8 BOM 的配置文件必须能正常解析
    //
    // 回归背景（2026-09-14 实测踩到）：Windows PowerShell 5.1 的
    // `Set-Content -Encoding utf8` 会给文件加上 BOM；带 BOM 的 JSON 让
    // `serde_json` 解析失败，而 `parse_opencode` 静默返回空 providers ——
    // 表现为"用户手改一次配置，App 里模型全消失且无任何提示"。
    #[test]
    fn parse_opencode_tolerates_utf8_bom() {
        let json = r#"{"provider":{"xiaomi":{"name":"xiaomi",
            "options":{"baseURL":"https://api.xiaomimimo.com/v1"},
            "models":{"mimo-v2.5-pro":{"name":"mimo-v2.5-pro"}}}}}"#;

        // 先确认无 BOM 时是好用的（避免测试本身写错格式而误判）
        let plain = parse_opencode(json);
        assert_eq!(plain.providers.len(), 1, "无 BOM 应解析出 1 个 provider");
        assert_eq!(plain.providers[0].id, "xiaomi");
        assert_eq!(plain.providers[0].models[0].id, "mimo-v2.5-pro");

        // 带 BOM：修复前这里会解析成空列表
        let with_bom = format!("\u{feff}{json}");
        let parsed = parse_opencode(strip_bom(&with_bom));
        assert_eq!(
            parsed.providers.len(),
            1,
            "带 BOM 的配置也必须能解析出 provider（不能被 BOM 静默吞掉）"
        );
        assert_eq!(parsed.providers[0].id, "xiaomi");
        assert_eq!(parsed.providers[0].models[0].id, "mimo-v2.5-pro");
    }

    // TC-AC-11  strip_bom 只剥开头那一个 BOM
    #[test]
    fn strip_bom_only_removes_leading_marker() {
        assert_eq!(strip_bom("abc"), "abc");
        assert_eq!(strip_bom("\u{feff}abc"), "abc");
        // 只剥开头一个：中间的零宽不换行空格可能是用户内容，不该动
        assert_eq!(strip_bom("\u{feff}\u{feff}abc"), "\u{feff}abc");
        assert_eq!(strip_bom("a\u{feff}b"), "a\u{feff}b");
        // 空串 / 纯 BOM 不能 panic
        assert_eq!(strip_bom(""), "");
        assert_eq!(strip_bom("\u{feff}"), "");
    }

    // TC-AC-12  read_text 是读盘唯一入口 —— 带 BOM 的文件也要读对
    #[test]
    fn read_text_strips_bom_from_disk() {
        let dir = std::env::temp_dir().join(format!(
            "brewping-bom-{}",
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("opencode.json");
        // 用 write（不是 write_all）模拟编辑器带 BOM 保存
        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend_from_slice(r#"{"provider":{}}"#.as_bytes());
        std::fs::write(&file, &bytes).unwrap();

        let content = read_text(&file).expect("文件存在应读得到");
        assert!(
            !content.starts_with('\u{feff}'),
            "read_text 必须剥掉 BOM，否则下游 JSON 解析会失败"
        );
        assert_eq!(content, r#"{"provider":{}}"#);

        std::fs::remove_dir_all(&dir).ok();
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
