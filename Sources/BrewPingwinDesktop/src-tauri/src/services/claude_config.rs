//! Claude Code 配置文件的**写入**能力（添加 / 编辑 / 删除厂商 = provider）。
//!
//! 对标 cc-switch 的 Claude 分支（`services/provider/live.rs::write_live_snapshot`
//! 的 `AppType::Claude` 臂 + `config.rs::get_claude_settings_path`）：
//! cc-switch 让用户在界面里添加自定义厂商，保存后**整体覆盖**写进
//! `~/.claude/settings.json`，用户无需手改文件。本模块提供同一件事。
//!
//! ## 契约（自 cc-switch 实证，逐条对齐）
//!
//! - **路径**：`~/.claude/settings.json`（`get_claude_config_dir()` = `$HOME/.claude`）。
//!   cc-switch 还有 legacy `~/.claude/claude.json` 回落；我们沿用
//!   `agent_config::claude_paths()` 的单一顺序，保证"读到什么就写回什么"。
//! - **写**：**整体覆盖**（与 opencode/pi 的增量模式不同 —— 这是 cc-switch 的
//!   Claude 分支原样，用户认可后照抄）。写前执行 `sanitize`：剥离
//!   `api_format` / `apiFormat` / `openrouter_compat_mode` / `openrouterCompatMode`
//!   这些 **cc-switch 内部元字段**，它们不属于 Claude Code 的 settings 语义。
//! - **字段语义**：厂商信息落在 `env` 段：
//!   - `env.ANTHROPIC_BASE_URL`   ← 用户填的 API 地址
//!   - `env.ANTHROPIC_AUTH_TOKEN` ← 用户填的 API Key
//!   - 可选档位模型：`env.ANTHROPIC_DEFAULT_SONNET_MODEL` /
//!     `ANTHROPIC_DEFAULT_OPUS_MODEL` / `ANTHROPIC_DEFAULT_HAIKU_MODEL`（+ `_NAME` 展示名）。
//!     Claude Code 用这三档把「sonnet/opus/haiku」映射到厂商真实型号。
//! - **读**：文件缺失 / 空 → 空配置（不报错）；**根不是对象 → 报错**，
//!   因为整体覆盖前提是"我们知道根长什么样"，静默重建会清空用户配置。
//! - **串行**：进程内 Mutex 保护，避免两个界面同时写导致丢更新。
//!
//! 模块**不依赖 tauri 类型**（services 层同款约束，cargo test 可裸跑）。
//! 网络调用（拉模型列表）不在这里——那属 command 层。

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::OnceLock;

/// cc-switch 内部元字段 —— 写 Claude Code settings.json 前必须剥离。
///
/// 这些是 cc-switch 自己用来记录"这家厂商走哪种协议"的标记，
/// Claude Code 不认识它们；留在文件里是脏数据。
const INTERNAL_FIELDS: &[&str] = &[
    "api_format",
    "apiFormat",
    "openrouter_compat_mode",
    "openrouterCompatMode",
];

/// Claude Code 的三档模型映射键（env 名）。
pub const TIER_ENV_KEYS: &[(&str, &str)] = &[
    ("sonnet", "ANTHROPIC_DEFAULT_SONNET_MODEL"),
    ("opus", "ANTHROPIC_DEFAULT_OPUS_MODEL"),
    ("haiku", "ANTHROPIC_DEFAULT_HAIKU_MODEL"),
];

// ─── DTO ─────────────────────────────────────────────────────────────────────

/// 一个模型档位（Claude Code 的 sonnet / opus / haiku 三档映射）。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeTierEntry {
    /// 档位名（`sonnet` / `opus` / `haiku`）。
    pub tier: String,
    /// 映射到的真实模型 id（写 `ANTHROPIC_DEFAULT_<TIER>_MODEL`）。
    #[serde(default)]
    pub model: String,
    /// 展示名（写 `ANTHROPIC_DEFAULT_<TIER>_MODEL_NAME`，可空跳过）。
    #[serde(default)]
    pub name: String,
}

/// Claude Code 的一份厂商配置（前端表单 ↔ settings.json 的 env 段）。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeProviderEntry {
    /// 展示名（仅 UI 用；Claude Code settings.json 里没有厂商名字段）。
    #[serde(default)]
    pub name: String,
    /// API 基址（`env.ANTHROPIC_BASE_URL`）。
    ///
    /// 🚨 必须显式 `rename = "baseURL"`：`rename_all = "camelCase"` 会把
    /// `base_url` 序列化成 `baseUrl`（小写 url），而前端 DTO（api/types.ts）
    /// 与其它三个模块（opencode / agent_config）统一用 `baseURL`。
    /// 缺这一行曾导致：前端读到 `undefined` → 点「配置厂商」进表单时
    /// `value.baseURL.trim()` 抛 TypeError → 整棵树卸载 = 白屏。
    #[serde(rename = "baseURL", default)]
    pub base_url: String,
    /// API Key（`env.ANTHROPIC_AUTH_TOKEN`）。
    /// 读出时**不脱敏**——这是用户自己的配置文件，界面按需自行掩码显示。
    #[serde(default)]
    pub api_key: String,
    /// 三档模型映射（可空 = 不写这三组键，Claude Code 用官方默认）。
    #[serde(default)]
    pub tiers: Vec<ClaudeTierEntry>,
    /// 除 env 之外的用户设置是否被保留（读时统计，写时不使用）。
    #[serde(default)]
    pub other_keys: Vec<String>,
}

/// 列出 Claude Code 厂商配置的结果（供前端渲染卡片）。
///
/// Claude Code 的 settings.json **只有一份**（不像 opencode 能装多个 provider），
/// 所以这里返回的是"当前这一份"，`configured` 标记是否已配好。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeProvidersInfo {
    /// 配置文件绝对路径（展示用，让用户知道东西写到哪了）。
    pub config_file: String,
    /// 配置文件当前是否存在。
    pub exists: bool,
    /// 是否已配置厂商（base_url 非空）。
    pub configured: bool,
    /// 当前配置（未配置时为空 entry）。
    pub provider: ClaudeProviderEntry,
}

// ─── 路径 ────────────────────────────────────────────────────────────────────

/// 配置文件候选路径（顺序即优先级，与 `agent_config::claude_paths` 一致）。
pub fn claude_config_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Some(home) = dirs::home_dir() {
        paths.push(home.join(".claude").join("settings.json"));
    }
    paths
}

/// 实际用于读写的路径：已存在的第一个；都不存在则用第一个（新建落这里）。
pub fn resolve_config_path() -> PathBuf {
    let paths = claude_config_paths();
    paths
        .iter()
        .find(|p| p.is_file())
        .cloned()
        .or_else(|| paths.into_iter().next())
        .unwrap_or_else(|| PathBuf::from(".claude/settings.json"))
}

// ─── 读写核心 ────────────────────────────────────────────────────────────────

/// 进程内写锁（避免两个窗口同时写导致丢更新；cc-switch 同款做法）。
fn config_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

/// 读整份配置。文件缺失 / 空 → 空对象；解析失败 → 报错；根非对象 → 报错。
fn read_config_at(path: &Path) -> Result<Value, String> {
    if !path.is_file() {
        return Ok(json!({}));
    }
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("read {} failed: {e}", path.display()))?;
    if text.trim().is_empty() {
        return Ok(json!({}));
    }
    let value: Value = serde_json::from_str(&text)
        .map_err(|e| format!("{} is not valid JSON: {e}", path.display()))?;
    if !value.is_object() {
        return Err(format!(
            "{} root must be a JSON object (found {})",
            path.display(),
            type_name(&value)
        ));
    }
    Ok(value)
}

fn type_name(v: &Value) -> &'static str {
    match v {
        Value::Null => "null",
        Value::Bool(_) => "bool",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

fn write_config_at(path: &Path, value: &Value) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("create {} failed: {e}", parent.display()))?;
    }
    let data = serde_json::to_string_pretty(value).map_err(|e| e.to_string())?;
    std::fs::write(path, format!("{data}\n"))
        .map_err(|e| format!("write {} failed: {e}", path.display()))
}

/// 剥离 cc-switch 内部元字段（顶层与 `env` 内都清）。
fn sanitize(root: &mut Value) {
    if let Some(obj) = root.as_object_mut() {
        for field in INTERNAL_FIELDS {
            obj.remove(*field);
        }
        if let Some(env) = obj.get_mut("env").and_then(Value::as_object_mut) {
            for field in INTERNAL_FIELDS {
                env.remove(*field);
            }
        }
    }
}

/// 把前端 DTO 写进 settings.json：**整体覆盖** —— 只覆盖我们管辖的键，
/// 其余用户键（顶层 `model` / `permissions` / `hooks`…，以及 `env` 段里的
/// `DISABLE_TELEMETRY` / `MCP_TIMEOUT` / `ANTHROPIC_API_KEY`…）**原样保留**。
///
/// 语义约定（与"清空 = 删除"一致，避免留下陈旧值）：
/// - `base_url` / `api_key` 为空 → 删除对应键，而不是跳过写入；
/// - 某个档位的 `model` 为空 → 删除该档位的 `*_MODEL` / `*_MODEL_NAME`；
/// - 某个档位的 `name` 为空 → 删除该档位的 `*_MODEL_NAME`。
fn apply_entry(root: &mut Value, entry: &ClaudeProviderEntry) {
    let obj = root
        .as_object_mut()
        .expect("read_config_at 已保证根是对象");

    // 🚨 关键：**在现有 env 段基础上改**，不能用 `Map::new()` 重建 ——
    // 重建会静默清空用户 env 段内的其它键（实测影响 DISABLE_TELEMETRY /
    // CLAUDE_CODE_MAX_OUTPUT_TOKENS / MCP_TIMEOUT / ANTHROPIC_API_KEY）。
    if obj.get("env").map(|v| !v.is_object()).unwrap_or(false) {
        // 用户把 env 写成了非对象（罕见）：无法安全合并，直接替换为对象。
        obj.insert("env".into(), Value::Object(Map::new()));
    }
    if !obj.contains_key("env") {
        obj.insert("env".into(), Value::Object(Map::new()));
    }
    let env = obj
        .get_mut("env")
        .and_then(Value::as_object_mut)
        .expect("上面已保证 env 是对象");

    set_or_remove(env, "ANTHROPIC_BASE_URL", entry.base_url.trim());
    set_or_remove(env, "ANTHROPIC_AUTH_TOKEN", entry.api_key.trim());

    // 三档模型映射：非空则写入，为空则删掉（避免"清空某档"无效）
    for tier in &entry.tiers {
        let tier_key = tier.tier.trim().to_ascii_lowercase();
        let Some(env_key) = TIER_ENV_KEYS
            .iter()
            .find(|(t, _)| *t == tier_key)
            .map(|(_, k)| *k)
        else {
            continue;
        };
        set_or_remove(env, env_key, tier.model.trim());
        set_or_remove(env, &format!("{env_key}_NAME"), tier.name.trim());
    }
}

/// `value` 非空则写入，为空则删除该键（"清空"语义 = 移除，而非留旧值）。
fn set_or_remove(env: &mut Map<String, Value>, key: &str, value: &str) {
    if value.is_empty() {
        env.remove(key);
    } else {
        env.insert(key.to_string(), json!(value));
    }
}

/// 把 settings.json 的 env 段还原成 DTO。
fn value_to_entry(root: &Value) -> ClaudeProviderEntry {
    let env = root.get("env").and_then(Value::as_object);
    let env_str = |key: &str| {
        env.and_then(|e| e.get(key))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string()
    };

    let mut tiers = Vec::new();
    for (tier, env_key) in TIER_ENV_KEYS {
        let model = env_str(env_key);
        if model.is_empty() {
            continue;
        }
        tiers.push(ClaudeTierEntry {
            tier: (*tier).to_string(),
            model,
            name: env_str(&format!("{env_key}_NAME")),
        });
    }

    // 顶层除 env 之外的键（让用户知道"整体覆盖时哪些东西被带上了"）
    let mut other_keys: Vec<String> = root
        .as_object()
        .map(|o| o.keys().filter(|k| k.as_str() != "env").cloned().collect())
        .unwrap_or_default();
    other_keys.sort();

    ClaudeProviderEntry {
        name: String::new(),
        base_url: env_str("ANTHROPIC_BASE_URL"),
        api_key: env_str("ANTHROPIC_AUTH_TOKEN"),
        tiers,
        other_keys,
    }
}

// ─── 对外 API（command 层消费） ──────────────────────────────────────────────
//
// 每个能力都有两个入口：`*()` 用本机真实路径（command 层用），
// `*_at(path)` 显式指定路径（测试用 —— 不碰用户真实配置）。

/// 读取本机 Claude Code 的厂商配置。
pub fn get_provider() -> ClaudeProvidersInfo {
    get_provider_at(&resolve_config_path())
}

/// `get_provider` 的显式路径版本。
pub fn get_provider_at(path: &Path) -> ClaudeProvidersInfo {
    let exists = path.is_file();
    match read_config_at(path) {
        Ok(root) => {
            let provider = value_to_entry(&root);
            ClaudeProvidersInfo {
                config_file: path.display().to_string(),
                exists,
                configured: !provider.base_url.is_empty(),
                provider,
            }
        }
        Err(_) => ClaudeProvidersInfo {
            config_file: path.display().to_string(),
            exists,
            configured: false,
            provider: ClaudeProviderEntry::default(),
        },
    }
}

/// 写入厂商配置（**整体覆盖** settings.json，用户其他键原样保留）。
///
/// 这是整个功能的核心 —— 用户点「保存」后走这一条。
pub fn save_provider(entry: &ClaudeProviderEntry) -> Result<ClaudeProvidersInfo, String> {
    save_provider_at(&resolve_config_path(), entry)
}

/// `save_provider` 的显式路径版本（测试用，不碰用户真实配置）。
pub fn save_provider_at(
    path: &Path,
    entry: &ClaudeProviderEntry,
) -> Result<ClaudeProvidersInfo, String> {
    if entry.base_url.trim().is_empty() {
        return Err("ANTHROPIC_BASE_URL must not be empty".into());
    }
    let base = entry.base_url.trim();
    if !(base.starts_with("http://") || base.starts_with("https://")) {
        return Err("base url must start with http:// or https://".into());
    }

    let _guard = config_lock()
        .lock()
        .map_err(|_| "config lock poisoned".to_string())?;

    let mut root = read_config_at(path)?;
    sanitize(&mut root);
    apply_entry(&mut root, entry);
    write_config_at(path, &root)?;

    Ok(get_provider_at(path))
}

/// 清除厂商配置（把 env 段里的 ANTHROPIC_* 摘掉；其他键保留）。
///
/// Claude Code 的 settings.json 是"同一份配置"，所以"删除厂商"的语义是
/// **清掉指向厂商的 env 键**，而不是删文件 —— 删文件会连用户的
/// `model` / `permissions` / `hooks` 一起带走。
pub fn delete_provider() -> Result<ClaudeProvidersInfo, String> {
    delete_provider_at(&resolve_config_path())
}

/// `delete_provider` 的显式路径版本（测试用）。
pub fn delete_provider_at(path: &Path) -> Result<ClaudeProvidersInfo, String> {
    let _guard = config_lock()
        .lock()
        .map_err(|_| "config lock poisoned".to_string())?;
    if !path.is_file() {
        return Ok(get_provider_at(path));
    }
    let mut root = read_config_at(path)?;
    sanitize(&mut root);
    if let Some(obj) = root.as_object_mut() {
        if let Some(env) = obj.get_mut("env").and_then(Value::as_object_mut) {
            env.remove("ANTHROPIC_BASE_URL");
            env.remove("ANTHROPIC_AUTH_TOKEN");
            for (_, env_key) in TIER_ENV_KEYS {
                env.remove(*env_key);
                env.remove(&format!("{env_key}_NAME"));
            }
            // env 空了就摘掉，别留 `"env": {}` 噪音
            if env.is_empty() {
                obj.remove("env");
            }
        }
    }
    write_config_at(path, &root)?;
    Ok(get_provider_at(path))
}

/// 读一份指定路径的配置（测试用）。
pub fn read_config(path: &Path) -> Result<Value, String> {
    read_config_at(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "brewping-claude-{}-{}",
            tag,
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn sample_entry() -> ClaudeProviderEntry {
        ClaudeProviderEntry {
            name: "DeepSeek".into(),
            base_url: "https://api.deepseek.com/anthropic".into(),
            api_key: "sk-test".into(),
            tiers: vec![ClaudeTierEntry {
                tier: "sonnet".into(),
                model: "deepseek-v4-pro[1m]".into(),
                name: "DeepSeek V4 Pro".into(),
            }],
            other_keys: vec![],
        }
    }

    // TC-CL-01  全新文件：保存即创建，env 两键写入
    #[test]
    fn save_creates_file_with_env_keys() {
        let dir = temp_dir("create");
        let path = dir.join("settings.json");
        let info = save_provider_at(&path, &sample_entry()).unwrap();
        assert!(info.exists);
        assert!(info.configured);

        let raw: Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(
            raw.pointer("/env/ANTHROPIC_BASE_URL").and_then(Value::as_str),
            Some("https://api.deepseek.com/anthropic")
        );
        assert_eq!(
            raw.pointer("/env/ANTHROPIC_AUTH_TOKEN").and_then(Value::as_str),
            Some("sk-test")
        );
        assert_eq!(
            raw.pointer("/env/ANTHROPIC_DEFAULT_SONNET_MODEL")
                .and_then(Value::as_str),
            Some("deepseek-v4-pro[1m]")
        );
    }

    // TC-CL-02  整体覆盖但保留用户其他键（顶层 + env 段里的其它键都不能被清）
    #[test]
    fn save_preserves_unrelated_keys() {
        let dir = temp_dir("preserve");
        let path = dir.join("settings.json");
        std::fs::write(
            &path,
            r#"{"model":"sonnet","permissions":{"allow":["Bash"]},"env":{"OTHER":"1"}}"#,
        )
        .unwrap();

        save_provider_at(&path, &sample_entry()).unwrap();

        let raw: Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(raw.get("model").and_then(Value::as_str), Some("sonnet"));
        assert!(raw.pointer("/permissions/allow").is_some(), "permissions 必须保留");
        // 🚨 env 段是**就地合并**：用户已有键必须原样保留（回归 TC-CL-12）
        assert_eq!(
            raw.pointer("/env/OTHER").and_then(Value::as_str),
            Some("1"),
            "env 段内的用户键绝不能被清空"
        );
        assert!(raw.pointer("/env/ANTHROPIC_BASE_URL").is_some());
    }

    // TC-CL-12  回归：env 段内的用户键（遥测/超时/官方 Key）绝不能被清空
    #[test]
    fn save_preserves_env_extras() {
        let dir = temp_dir("env-extras");
        let path = dir.join("settings.json");
        std::fs::write(
            &path,
            r#"{"env":{
                "DISABLE_TELEMETRY":"1",
                "CLAUDE_CODE_MAX_OUTPUT_TOKENS":"32000",
                "MCP_TIMEOUT":"30000",
                "ANTHROPIC_API_KEY":"sk-official-user",
                "ANTHROPIC_DEFAULT_OPUS_MODEL":"legacy-opus"
            }}"#,
        )
        .unwrap();

        save_provider_at(&path, &sample_entry()).unwrap();

        let raw: Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        for (key, want) in [
            ("DISABLE_TELEMETRY", "1"),
            ("CLAUDE_CODE_MAX_OUTPUT_TOKENS", "32000"),
            ("MCP_TIMEOUT", "30000"),
            ("ANTHROPIC_API_KEY", "sk-official-user"),
        ] {
            assert_eq!(
                raw.pointer(&format!("/env/{key}")).and_then(Value::as_str),
                Some(want),
                "env.{key} 必须被保留（曾经被 Map::new() 静默清空）"
            );
        }
        // 我们管辖的键被正常写入
        assert_eq!(
            raw.pointer("/env/ANTHROPIC_BASE_URL").and_then(Value::as_str),
            Some("https://api.deepseek.com/anthropic")
        );
        // 未在本次 DTO 里列出的档位：**动都不动**（只有显式提交的档位才会被处理，
        // 避免误删用户手写的档位值）
        assert_eq!(
            raw.pointer("/env/ANTHROPIC_DEFAULT_OPUS_MODEL").and_then(Value::as_str),
            Some("legacy-opus"),
            "未提交的档位应原样保留"
        );
    }

    // TC-CL-13  清空语义：api_key 置空 → 删除键而非留旧值；base_url 是必填（空则报错）
    #[test]
    fn save_removes_empty_key_and_rejects_empty_base_url() {
        let dir = temp_dir("clear-keys");
        let path = dir.join("settings.json");
        std::fs::write(
            &path,
            r#"{"env":{"ANTHROPIC_BASE_URL":"https://old.example.com","ANTHROPIC_AUTH_TOKEN":"sk-old","KEEP":"yes"}}"#,
        )
        .unwrap();

        // base_url 为空是**不允许**的（L334 前置校验）：保留旧值语义更安全
        let cleared = ClaudeProviderEntry {
            base_url: "   ".into(),
            api_key: "sk-new".into(),
            ..Default::default()
        };
        assert!(
            save_provider_at(&path, &cleared).is_err(),
            "base_url 为空必须被拒绝，而不是静默清空"
        );

        // api_key 置空 → 删除 ANTHROPIC_AUTH_TOKEN，其余 env 键保留
        let entry = ClaudeProviderEntry {
            base_url: "https://new.example.com".into(),
            api_key: String::new(),
            ..Default::default()
        };
        save_provider_at(&path, &entry).unwrap();

        let raw: Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(
            raw.pointer("/env/ANTHROPIC_BASE_URL").and_then(Value::as_str),
            Some("https://new.example.com"),
            "base_url 应被更新"
        );
        assert!(
            raw.pointer("/env/ANTHROPIC_AUTH_TOKEN").is_none(),
            "清空 api_key 必须删除键，不能留下旧值"
        );
        assert_eq!(raw.pointer("/env/KEEP").and_then(Value::as_str), Some("yes"));
    }

    // TC-CL-14  清空语义：档位 model / name 置空 → 删除对应键
    #[test]
    fn save_removes_cleared_tier_values() {
        let dir = temp_dir("clear-tiers");
        let path = dir.join("settings.json");
        std::fs::write(
            &path,
            r#"{"env":{
                "ANTHROPIC_DEFAULT_SONNET_MODEL":"old-sonnet",
                "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME":"Old Sonnet",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL":"old-haiku"
            }}"#,
        )
        .unwrap();

        let entry = ClaudeProviderEntry {
            base_url: "https://api.example.com".into(),
            api_key: "k".into(),
            tiers: vec![ClaudeTierEntry {
                tier: "sonnet".into(),
                model: "new-sonnet".into(),
                name: String::new(), // name 清空 → _NAME 应删除
            }],
            ..Default::default()
        };
        save_provider_at(&path, &entry).unwrap();

        let raw: Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(
            raw.pointer("/env/ANTHROPIC_DEFAULT_SONNET_MODEL").and_then(Value::as_str),
            Some("new-sonnet")
        );
        assert!(
            raw.pointer("/env/ANTHROPIC_DEFAULT_SONNET_MODEL_NAME").is_none(),
            "name 清空必须删除 _NAME"
        );
        assert_eq!(
            raw.pointer("/env/ANTHROPIC_DEFAULT_HAIKU_MODEL").and_then(Value::as_str),
            Some("old-haiku"),
            "未提交的档位应原样保留"
        );
    }

    // TC-CL-03  sanitize：cc-switch 内部字段必须被剥离（顶层 + env 内）
    #[test]
    fn save_strips_internal_fields() {
        let dir = temp_dir("sanitize");
        let path = dir.join("settings.json");
        std::fs::write(
            &path,
            r#"{"api_format":"anthropic","apiFormat":"x","env":{"openrouter_compat_mode":true}}"#,
        )
        .unwrap();

        save_provider_at(&path, &sample_entry()).unwrap();

        let raw: Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert!(raw.get("api_format").is_none(), "api_format 必须剥离");
        assert!(raw.get("apiFormat").is_none(), "apiFormat 必须剥离");
        assert!(
            raw.pointer("/env/openrouter_compat_mode").is_none(),
            "env 内的内部字段也必须剥离"
        );
    }

    // TC-CL-04  三档映射：只写非空档位，_NAME 仅在提供时写
    #[test]
    fn save_writes_only_populated_tiers() {
        let dir = temp_dir("tiers");
        let path = dir.join("settings.json");
        let entry = ClaudeProviderEntry {
            base_url: "https://api.example.com".into(),
            api_key: "k".into(),
            tiers: vec![
                ClaudeTierEntry { tier: "opus".into(), model: "opus-x".into(), name: String::new() },
                ClaudeTierEntry { tier: "haiku".into(), model: String::new(), name: "n".into() },
            ],
            ..Default::default()
        };
        save_provider_at(&path, &entry).unwrap();

        let raw: Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(
            raw.pointer("/env/ANTHROPIC_DEFAULT_OPUS_MODEL").and_then(Value::as_str),
            Some("opus-x")
        );
        assert!(
            raw.pointer("/env/ANTHROPIC_DEFAULT_OPUS_MODEL_NAME").is_none(),
            "name 为空时不应写 _NAME"
        );
        assert!(
            raw.pointer("/env/ANTHROPIC_DEFAULT_HAIKU_MODEL").is_none(),
            "model 为空的档位整组跳过"
        );
    }

    // TC-CL-05  读取还原：写进去什么，读出来什么
    #[test]
    fn roundtrip_get_after_save() {
        let dir = temp_dir("roundtrip");
        let path = dir.join("settings.json");
        save_provider_at(&path, &sample_entry()).unwrap();

        let info = get_provider_at(&path);
        assert!(info.configured);
        assert_eq!(info.provider.base_url, "https://api.deepseek.com/anthropic");
        assert_eq!(info.provider.api_key, "sk-test");
        assert_eq!(info.provider.tiers.len(), 1);
        assert_eq!(info.provider.tiers[0].tier, "sonnet");
        assert_eq!(info.provider.tiers[0].name, "DeepSeek V4 Pro");
    }

    // TC-CL-06  删除：env 里的 ANTHROPIC_* 全清，env 空了整段摘掉，其他键保留
    #[test]
    fn delete_removes_anthropic_keys_only() {
        let dir = temp_dir("delete");
        let path = dir.join("settings.json");
        save_provider_at(&path, &sample_entry()).unwrap();
        // 加一个用户自己的 env 变量，验证它不被误删
        let mut raw: Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        raw["env"]["MY_VAR"] = json!("keep");
        raw["model"] = json!("sonnet");
        std::fs::write(&path, serde_json::to_string_pretty(&raw).unwrap()).unwrap();

        let info = delete_provider_at(&path).unwrap();
        assert!(!info.configured, "删完不应还有 base_url");

        let raw: Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert!(raw.pointer("/env/ANTHROPIC_BASE_URL").is_none());
        assert!(raw.pointer("/env/ANTHROPIC_AUTH_TOKEN").is_none());
        assert_eq!(raw.pointer("/env/MY_VAR").and_then(Value::as_str), Some("keep"));
        assert_eq!(raw.get("model").and_then(Value::as_str), Some("sonnet"));
    }

    // TC-CL-07  删除后 env 为空时不留 `"env": {}` 噪音
    #[test]
    fn delete_drops_empty_env_section() {
        let dir = temp_dir("delete-empty-env");
        let path = dir.join("settings.json");
        save_provider_at(&path, &sample_entry()).unwrap();

        delete_provider_at(&path).unwrap();

        let raw: Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert!(raw.get("env").is_none(), "env 空时应整段摘掉");
    }

    // TC-CL-08  校验：空地址 / 非 http(s) 必须被拒
    #[test]
    fn save_rejects_invalid_base_url() {
        let dir = temp_dir("invalid");
        let path = dir.join("settings.json");

        let empty = ClaudeProviderEntry { base_url: "  ".into(), ..Default::default() };
        assert!(save_provider_at(&path, &empty).is_err());

        let bad = ClaudeProviderEntry { base_url: "ftp://x".into(), ..Default::default() };
        assert!(save_provider_at(&path, &bad).is_err());
    }

    // TC-CL-09  根非对象 / 非法 JSON 必须报错（不许静默清空用户配置）
    #[test]
    fn read_rejects_non_object_root() {
        let dir = temp_dir("bad-root");
        let path = dir.join("settings.json");
        std::fs::write(&path, "[1,2,3]").unwrap();
        assert!(read_config_at(&path).is_err());

        std::fs::write(&path, "{not json").unwrap();
        assert!(read_config_at(&path).is_err());
    }

    // TC-CL-10  文件不存在时读取 = 未配置（不报错）
    #[test]
    fn get_on_missing_file_is_not_configured() {
        let dir = temp_dir("missing");
        let path = dir.join("nope.json");
        let info = get_provider_at(&path);
        assert!(!info.exists);
        assert!(!info.configured);
        assert!(info.provider.base_url.is_empty());
    }

    // TC-CL-11  other_keys 如实列出"整体覆盖时会一起保留的顶层键"（不含 env）
    #[test]
    fn other_keys_lists_non_env_top_level_keys() {
        let dir = temp_dir("other-keys");
        let path = dir.join("settings.json");
        std::fs::write(&path, r#"{"model":"sonnet","zeta":1,"env":{"A":"1"}}"#).unwrap();
        let info = get_provider_at(&path);
        assert_eq!(info.provider.other_keys, vec!["model", "zeta"]);
    }

    // TC-CL-12  幂等：同内容重复保存结果一致
    #[test]
    fn save_is_idempotent() {
        let dir = temp_dir("idempotent");
        let path = dir.join("settings.json");
        save_provider_at(&path, &sample_entry()).unwrap();
        let first = std::fs::read_to_string(&path).unwrap();
        save_provider_at(&path, &sample_entry()).unwrap();
        let second = std::fs::read_to_string(&path).unwrap();
        assert_eq!(first, second);
    }

    // TC-CL-15  🚨 回归：DTO 的线上格式必须是 `baseURL`（不是 camelCase 派生的
    // `baseUrl`）。前端 api/types.ts 与其它三个 CLI 模块统一用 baseURL；
    // 一旦漂移，前端会读到 undefined，点「配置厂商」进表单直接白屏。
    #[test]
    fn wire_format_uses_base_url_key() {
        let info = ClaudeProvidersInfo {
            config_file: "/tmp/settings.json".into(),
            exists: true,
            configured: true,
            provider: sample_entry(),
        };
        let v = serde_json::to_value(&info).unwrap();
        let p = &v["provider"];

        assert!(
            p.get("baseURL").is_some(),
            "必须下发 baseURL（前端 DTO 约定），实际 provider={p}"
        );
        assert!(
            p.get("baseUrl").is_none(),
            "不得下发 camelCase 派生出的 baseUrl（会导致前端读不到 → 白屏）"
        );
        assert_eq!(
            p.get("baseURL").and_then(Value::as_str),
            Some("https://api.deepseek.com/anthropic")
        );
    }

    // TC-CL-16  🚨 回归：反序列化必须接受前端发来的 `baseURL`。
    // 曾因字段名不符，前端保存时 base_url 被解析成空串 → 后端报
    // "ANTHROPIC_BASE_URL must not be empty"，功能整体不可用。
    #[test]
    fn deserialize_accepts_base_url_key() {
        let raw = serde_json::json!({
            "name": "DeepSeek",
            "baseURL": "https://api.deepseek.com/anthropic",
            "apiKey": "sk-test",
            "tiers": [{ "tier": "sonnet", "model": "deepseek-v4-pro[1m]", "name": "" }],
            "otherKeys": []
        });
        let entry: ClaudeProviderEntry = serde_json::from_value(raw).unwrap();
        assert_eq!(entry.base_url, "https://api.deepseek.com/anthropic");
        assert_eq!(entry.api_key, "sk-test");
        assert_eq!(entry.tiers.len(), 1);
    }
}
