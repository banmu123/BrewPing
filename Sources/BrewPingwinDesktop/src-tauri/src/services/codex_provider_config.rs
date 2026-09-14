//! Codex 配置文件的**写入**能力（添加 / 编辑 / 删除厂商 = provider）。
//!
//! 对标 cc-switch 的 Codex 分支（`codex_config.rs` 的
//! `write_codex_provider_live_with_catalog` / `prepare_codex_provider_live_config`
//! / `set_codex_experimental_bearer_token` / `update_codex_toml_field`）：
//! cc-switch 让用户在界面里添加自定义厂商，保存后写进 `~/.codex/config.toml`，
//! 用户无需手改文件。本模块提供同一件事，但**刻意砍掉 OAuth 那一整套**。
//!
//! ## 契约（自 cc-switch 实证，逐条对齐）
//!
//! - **路径**：`~/.codex/config.toml`（`get_codex_config_dir()` = `$HOME/.codex`）。
//! - **写**：用 `toml_edit` 保注释与格式，只动这几个位置：
//!   1. 顶层 `model_provider = "<key>"` —— 切到我们这家厂商；
//!   2. `[model_providers.<key>]` 表：`name`（**必须非空**，Codex 0.149 会对
//!      无 name 的自定义表整份拒载）、`base_url`、`wire_api`（`chat` / `responses`）；
//!   3. `experimental_bearer_token` —— **优先写在 `[model_providers.<key>]` 内**
//!      （provider 作用域，不污染顶层）；无法定位到表时回落顶层。
//!   4. 可选顶层 `model` —— 用户指定的默认模型。
//!
//! - **🔴 不碰 `~/.codex/auth.json`** —— 这是 cc-switch 的关键设计：
//!   `auth.json` 是用户 ChatGPT 登录缓存（`auth_mode: "chatgpt"` + `tokens.*`），
//!   第三方厂商的 Key 走 `experimental_bearer_token` 即可，**不需要**覆盖 auth.json。
//!   cc-switch 在切到第三方时甚至会主动删 auth.json 以免 OAuth 回退，
//!   我们更保守：**完全不读不写**。
//!
//! - **保留保留 id**：`openai` / `ollama` / `lmstudio` 是 Codex 内置 provider id，
//!   覆盖它们的表会让 Codex 0.148+ 拒绝加载整份配置。本模块对这三个 id 直接报错
//!   （cc-switch 同款护栏，见 `update_codex_toml_field`）。
//! - **读**：文件缺失 / 空 → 空清单（不报错）；解析失败 → 报错。
//! - **串行**：进程内 Mutex 保护。
//!
//! 模块**不依赖 tauri 类型**（services 层同款约束，cargo test 可裸跑）。
//! 网络调用（拉模型列表）不在这里——那属 command 层。

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::OnceLock;

/// Codex 内置（保留）provider id —— 覆盖其表会导致 Codex 拒载整份配置。
///
/// 判定是**大小写精确**的（cc-switch 实证）：`OpenAI` 等变体是合法自定义 id。
const RESERVED_PROVIDER_IDS: &[&str] = &["openai", "ollama", "lmstudio"];

/// `wire_api` 取值（Codex 只认这两个）。
pub const WIRE_APIS: &[(&str, &str)] = &[("chat", "Chat Completions"), ("responses", "Responses")];

/// 默认 `wire_api`：国内厂商的 Anthropic/OpenAI 兼容端点绝大多数走 chat。
pub const DEFAULT_WIRE_API: &str = "chat";

// ─── DTO ─────────────────────────────────────────────────────────────────────

/// 一个 Codex 厂商配置（前端表单 ↔ config.toml 的 `[model_providers.<key>]`）。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexProviderEntry {
    /// provider key（`[model_providers.<key>]` 的表名）。形如 `my-deepseek`。
    #[serde(default)]
    pub id: String,
    /// 展示名（Codex `[model_providers.<key>].name`，**必填非空**）。
    #[serde(default)]
    pub name: String,
    /// API 基址（Codex `base_url`）。
    ///
    /// 🚨 必须显式 `rename = "baseURL"`：`rename_all = "camelCase"` 会派生
    /// `baseUrl`，而前端 DTO（api/types.ts）与其它模块统一用 `baseURL`。
    /// 缺这一行会让前端读到 undefined → 点「配置厂商」进表单时
    /// `value.baseURL.trim()` 抛 TypeError → 白屏（Claude 模块同款问题）。
    #[serde(rename = "baseURL", default)]
    pub base_url: String,
    /// 协议（Codex `wire_api`）：`chat` / `responses`。空则回落 `chat`。
    #[serde(default)]
    pub wire_api: String,
    /// API Key（写 `experimental_bearer_token`）。
    /// 读出时**不脱敏**——这是用户自己的配置文件，界面按需自行掩码显示。
    #[serde(default)]
    pub api_key: String,
    /// 默认模型（顶层 `model`）。空则不写。
    #[serde(default)]
    pub model: String,
    /// 是否为当前生效的 provider（`model_provider == id`）。
    #[serde(default)]
    pub active: bool,
}

/// 列出 Codex 厂商的结果（供前端渲染卡片列表）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexProvidersInfo {
    /// 配置文件绝对路径（展示用，让用户知道东西写到哪了）。
    pub config_file: String,
    /// 配置文件当前是否存在。
    pub exists: bool,
    /// 当前生效的 provider key（顶层 `model_provider`）。
    pub active_id: String,
    /// 已配置的厂商（按 key 排序）。
    pub providers: Vec<CodexProviderEntry>,
    /// 可选 `wire_api` 清单（值 + 标签），前端下拉直接吃。
    pub wire_apis: Vec<WireApiOption>,
}

/// `wire_api` 选项。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WireApiOption {
    pub value: String,
    pub label: String,
}

// ─── provider key 校验 / 派生 ────────────────────────────────────────────────

/// 校验 provider key：只允许小写字母数字，可用连字符分组（`my-deepseek`）。
pub fn is_valid_provider_key(key: &str) -> bool {
    if key.is_empty() {
        return false;
    }
    let bytes = key.as_bytes();
    if bytes[0] == b'-' || bytes[bytes.len() - 1] == b'-' {
        return false;
    }
    let mut prev_dash = false;
    for &b in bytes {
        let ok = b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-';
        if !ok {
            return false;
        }
        if b == b'-' && prev_dash {
            return false;
        }
        prev_dash = b == b'-';
    }
    true
}

/// 是否为 Codex 保留 id（不可覆盖）。
pub fn is_reserved_provider_key(key: &str) -> bool {
    RESERVED_PROVIDER_IDS.contains(&key)
}

/// 由展示名派生一个合法的 provider key：`My DeepSeek` → `my-deepseek`。
pub fn slugify_provider_key(name: &str) -> String {
    let mut out = String::new();
    let mut prev_dash = false;
    for ch in name.chars() {
        let c = ch.to_ascii_lowercase();
        if c.is_ascii_lowercase() || c.is_ascii_digit() {
            out.push(c);
            prev_dash = false;
        } else if !prev_dash && !out.is_empty() {
            out.push('-');
            prev_dash = true;
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    if out.is_empty() {
        "provider".to_string()
    } else {
        out
    }
}

// ─── 路径 ────────────────────────────────────────────────────────────────────

/// 配置文件候选路径（顺序即优先级，与 `agent_config::codex_paths` 一致）。
pub fn codex_config_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Some(home) = dirs::home_dir() {
        paths.push(home.join(".codex").join("config.toml"));
    }
    paths
}

/// 实际用于读写的路径：已存在的第一个；都不存在则用第一个（新建落这里）。
pub fn resolve_config_path() -> PathBuf {
    let paths = codex_config_paths();
    paths
        .iter()
        .find(|p| p.is_file())
        .cloned()
        .or_else(|| paths.into_iter().next())
        .unwrap_or_else(|| PathBuf::from(".codex/config.toml"))
}

fn read_text_at(path: &Path) -> Result<String, String> {
    if !path.is_file() {
        return Ok(String::new());
    }
    std::fs::read_to_string(path).map_err(|e| format!("read {} failed: {e}", path.display()))
}

fn write_text_at(path: &Path, text: &str) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("create {} failed: {e}", parent.display()))?;
    }
    std::fs::write(path, text).map_err(|e| format!("write {} failed: {e}", path.display()))
}

fn parse_doc(text: &str, path: &Path) -> Result<toml_edit::DocumentMut, String> {
    if text.trim().is_empty() {
        return Ok(toml_edit::DocumentMut::new());
    }
    text.parse::<toml_edit::DocumentMut>()
        .map_err(|e| format!("{} is not valid TOML: {e}", path.display()))
}

fn config_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

// ─── 读写核心 ────────────────────────────────────────────────────────────────

/// 定位 `[model_providers.<key>]` 表上的字符串字段（优先 provider 作用域）。
fn provider_str<'a>(doc: &'a toml_edit::DocumentMut, key: &str, field: &str) -> Option<&'a str> {
    doc.get("model_providers")
        .and_then(|i| i.as_table_like())
        .and_then(|t| t.get(key))
        .and_then(|i| i.as_table_like())
        .and_then(|t| t.get(field))
        .and_then(|i| i.as_str())
}

/// 读取 provider 的 token：优先表内 `experimental_bearer_token`，回落顶层。
fn provider_token(doc: &toml_edit::DocumentMut, key: &str) -> String {
    provider_str(doc, key, "experimental_bearer_token")
        .or_else(|| doc.get("experimental_bearer_token").and_then(|i| i.as_str()))
        .unwrap_or_default()
        .to_string()
}

/// 把所有 provider 还原成 DTO 列表。
fn collect_providers(doc: &toml_edit::DocumentMut) -> Vec<CodexProviderEntry> {
    let active_id = doc
        .get("model_provider")
        .and_then(|i| i.as_str())
        .unwrap_or_default()
        .to_string();
    let top_model = doc
        .get("model")
        .and_then(|i| i.as_str())
        .unwrap_or_default()
        .to_string();

    let mut out: Vec<CodexProviderEntry> = doc
        .get("model_providers")
        .and_then(|i| i.as_table_like())
        .map(|t| {
            t.iter()
                .filter(|(_, item)| item.is_table_like())
                .map(|(key, _)| {
                    let name = provider_str(doc, key, "name").unwrap_or(key).to_string();
                    let base_url = provider_str(doc, key, "base_url")
                        .unwrap_or_default()
                        .to_string();
                    let wire_api = provider_str(doc, key, "wire_api")
                        .unwrap_or(DEFAULT_WIRE_API)
                        .to_string();
                    CodexProviderEntry {
                        id: key.to_string(),
                        name,
                        base_url,
                        wire_api,
                        api_key: provider_token(doc, key),
                        // 顶层 model 只属于当前生效的那家
                        model: if key == active_id { top_model.clone() } else { String::new() },
                        active: key == active_id,
                    }
                })
                .collect()
        })
        .unwrap_or_default();
    out.sort_by(|a, b| a.id.cmp(&b.id));
    out
}

fn wire_api_options() -> Vec<WireApiOption> {
    WIRE_APIS
        .iter()
        .map(|(value, label)| WireApiOption {
            value: (*value).to_string(),
            label: (*label).to_string(),
        })
        .collect()
}

// ─── 对外 API（command 层消费） ──────────────────────────────────────────────

/// 列出本机 Codex 已配置的全部 provider。
pub fn list_providers() -> CodexProvidersInfo {
    list_providers_at(&resolve_config_path())
}

/// `list_providers` 的显式路径版本。
pub fn list_providers_at(path: &Path) -> CodexProvidersInfo {
    let exists = path.is_file();
    let empty = |path: &Path| CodexProvidersInfo {
        config_file: path.display().to_string(),
        exists,
        active_id: String::new(),
        providers: Vec::new(),
        wire_apis: wire_api_options(),
    };

    let text = match read_text_at(path) {
        Ok(t) => t,
        Err(_) => return empty(path),
    };
    let doc = match parse_doc(&text, path) {
        Ok(d) => d,
        Err(_) => return empty(path),
    };

    CodexProvidersInfo {
        config_file: path.display().to_string(),
        exists,
        active_id: doc
            .get("model_provider")
            .and_then(|i| i.as_str())
            .unwrap_or_default()
            .to_string(),
        providers: collect_providers(&doc),
        wire_apis: wire_api_options(),
    }
}

/// 写入 / 更新一个 provider（幂等：同 id 重复保存 = 覆盖）。
///
/// 这是整个功能的核心 —— 用户点「保存」后走这一条。
pub fn save_provider(entry: &CodexProviderEntry) -> Result<CodexProvidersInfo, String> {
    save_provider_at(&resolve_config_path(), entry)
}

/// `save_provider` 的显式路径版本（测试用，不碰用户真实配置）。
pub fn save_provider_at(
    path: &Path,
    entry: &CodexProviderEntry,
) -> Result<CodexProvidersInfo, String> {
    let id = entry.id.trim().to_string();
    if !is_valid_provider_key(&id) {
        return Err(format!(
            "invalid provider key '{id}': use lowercase letters, digits and single dashes (e.g. my-deepseek)"
        ));
    }
    if is_reserved_provider_key(&id) {
        return Err(format!(
            "cannot override Codex built-in provider `{id}` (Codex 0.148+ rejects the whole config); pick a custom id"
        ));
    }
    if entry.name.trim().is_empty() {
        return Err("provider name must not be empty (Codex rejects unnamed provider tables)".into());
    }
    let base = entry.base_url.trim();
    if base.is_empty() {
        return Err("base_url must not be empty".into());
    }
    if !(base.starts_with("http://") || base.starts_with("https://")) {
        return Err("base_url must start with http:// or https://".into());
    }
    let wire_api = if entry.wire_api.trim().is_empty() {
        DEFAULT_WIRE_API
    } else {
        entry.wire_api.trim()
    };
    if !WIRE_APIS.iter().any(|(v, _)| *v == wire_api) {
        return Err(format!(
            "invalid wire_api '{wire_api}': expected one of {}",
            WIRE_APIS.iter().map(|(v, _)| *v).collect::<Vec<_>>().join(", ")
        ));
    }

    let _guard = config_lock()
        .lock()
        .map_err(|_| "config lock poisoned".to_string())?;

    let text = read_text_at(path)?;
    let mut doc = parse_doc(&text, path)?;

    // ① 顶层 model_provider 指向这家
    doc["model_provider"] = toml_edit::value(id.as_str());

    // ② 确保 [model_providers] 是表（保留既有兄弟条目；非表则留痕重建）
    if doc
        .get("model_providers")
        .is_none_or(|i| i.as_table_like().is_none())
    {
        if doc.get("model_providers").is_some_and(|i| !i.is_none()) {
            log::warn!("config.toml 的 model_providers 不是表，已重置为空表");
        }
        doc["model_providers"] = toml_edit::table();
    }

    // ③ 写入 [model_providers.<id>]（保留该表上用户手加的其他字段）
    let providers = doc
        .get_mut("model_providers")
        .and_then(|i| i.as_table_like_mut())
        .expect("上一步已保证 model_providers 是表");
    if !providers.contains_key(&id) {
        providers.insert(&id, toml_edit::table());
    }
    let section = providers
        .get_mut(&id)
        .and_then(|i| i.as_table_like_mut())
        .ok_or_else(|| format!("[model_providers.{id}] is not a table"))?;
    // name 必填非空 —— Codex 0.149 会对无 name 的自定义表整份拒载
    section.insert("name", toml_edit::value(entry.name.trim()));
    section.insert("base_url", toml_edit::value(base));
    section.insert("wire_api", toml_edit::value(wire_api));
    if entry.api_key.trim().is_empty() {
        section.remove("experimental_bearer_token");
    } else {
        section.insert(
            "experimental_bearer_token",
            toml_edit::value(entry.api_key.trim()),
        );
    }

    // ④ 顶层 model（可选）—— 写我们的就写；留空则不动用户原有的
    if !entry.model.trim().is_empty() {
        doc["model"] = toml_edit::value(entry.model.trim());
    }

    write_text_at(path, &doc.to_string())?;
    Ok(list_providers_at(path))
}

/// 删除一个 provider（按 id；不存在则视为成功 = 幂等）。
///
/// 同时清理：该表的 token（若在顶层则一并清）、顶层 `model`（若这曾是当前 provider）。
pub fn delete_provider(id: &str) -> Result<CodexProvidersInfo, String> {
    delete_provider_at(&resolve_config_path(), id)
}

/// `delete_provider` 的显式路径版本（测试用）。
pub fn delete_provider_at(path: &Path, id: &str) -> Result<CodexProvidersInfo, String> {
    let id = id.trim();
    if id.is_empty() {
        return Err("provider id must not be empty".into());
    }
    let _guard = config_lock()
        .lock()
        .map_err(|_| "config lock poisoned".to_string())?;
    if !path.is_file() {
        return Ok(list_providers_at(path));
    }

    let text = read_text_at(path)?;
    let mut doc = parse_doc(&text, path)?;

    let was_active = doc.get("model_provider").and_then(|i| i.as_str()) == Some(id);
    let removed = doc
        .get_mut("model_providers")
        .and_then(|i| i.as_table_like_mut())
        .map(|t| t.remove(id).is_some())
        .unwrap_or(false);

    if was_active {
        doc.as_table_mut().remove("model_provider");
        doc.as_table_mut().remove("model");
    }
    // 顶层 token 是我们写的回落位置，随删除一起清（表内的已随表删除）
    if doc.get("experimental_bearer_token").is_some() {
        doc.as_table_mut().remove("experimental_bearer_token");
    }
    // model_providers 空了就摘掉，别留空表噪音
    let empty_providers = doc
        .get("model_providers")
        .and_then(|i| i.as_table_like())
        .map(|t| t.is_empty())
        .unwrap_or(false);
    if empty_providers {
        doc.as_table_mut().remove("model_providers");
    }

    if removed || was_active {
        write_text_at(path, &doc.to_string())?;
    }
    Ok(list_providers_at(path))
}

/// 切换当前生效的 provider（只改顶层 `model_provider`，不动表内容）。
pub fn activate_provider(id: &str) -> Result<CodexProvidersInfo, String> {
    activate_provider_at(&resolve_config_path(), id)
}

/// `activate_provider` 的显式路径版本（测试用）。
pub fn activate_provider_at(path: &Path, id: &str) -> Result<CodexProvidersInfo, String> {
    let id = id.trim();
    if id.is_empty() {
        return Err("provider id must not be empty".into());
    }
    let _guard = config_lock()
        .lock()
        .map_err(|_| "config lock poisoned".to_string())?;
    let text = read_text_at(path)?;
    let mut doc = parse_doc(&text, path)?;
    if !doc
        .get("model_providers")
        .and_then(|i| i.as_table_like())
        .is_some_and(|t| t.contains_key(id))
    {
        return Err(format!("provider '{id}' not found in config.toml"));
    }
    doc["model_provider"] = toml_edit::value(id);
    write_text_at(path, &doc.to_string())?;
    Ok(list_providers_at(path))
}

/// 读一份指定路径的配置文本（测试用）。
pub fn read_config(path: &Path) -> Result<String, String> {
    read_text_at(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "brewping-codex-{}-{}",
            tag,
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn sample_entry(id: &str) -> CodexProviderEntry {
        CodexProviderEntry {
            id: id.into(),
            name: "DeepSeek".into(),
            base_url: "https://api.deepseek.com/v1".into(),
            wire_api: "chat".into(),
            api_key: "sk-test".into(),
            model: "deepseek-chat".into(),
            active: false,
        }
    }

    // TC-CX-01  全新文件：保存即建表 + 顶层指向 + bearer token 落在表内
    #[test]
    fn save_creates_table_and_token() {
        let dir = temp_dir("create");
        let path = dir.join("config.toml");
        let info = save_provider_at(&path, &sample_entry("my-deepseek")).unwrap();

        assert_eq!(info.active_id, "my-deepseek");
        assert_eq!(info.providers.len(), 1);
        let p = &info.providers[0];
        assert_eq!(p.name, "DeepSeek");
        assert_eq!(p.wire_api, "chat");
        assert_eq!(p.api_key, "sk-test");

        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("model_provider = \"my-deepseek\""), "{text}");
        // token 必须在表内（provider 作用域），不在顶层
        let doc = text.parse::<toml_edit::DocumentMut>().unwrap();
        assert_eq!(
            provider_str(&doc, "my-deepseek", "experimental_bearer_token"),
            Some("sk-test")
        );
        assert!(doc.get("experimental_bearer_token").is_none(), "不应有顶层 token");
    }

    // TC-CX-02  保留用户既有配置与注释（toml_edit 的核心价值）
    #[test]
    fn save_preserves_comments_and_other_tables() {
        let dir = temp_dir("preserve");
        let path = dir.join("config.toml");
        std::fs::write(
            &path,
            "# 我的注释\nmodel = \"gpt-5\"\n\n[model_providers.other]\nname = \"Other\"\nbase_url = \"https://other.example\"\n",
        )
        .unwrap();

        save_provider_at(&path, &sample_entry("my-deepseek")).unwrap();

        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("# 我的注释"), "注释必须保留:\n{text}");
        let info = list_providers_at(&path);
        assert_eq!(info.providers.len(), 2, "既有 other 表必须保留");
        assert!(info.providers.iter().any(|p| p.id == "other"));
    }

    // TC-CX-03  🔴 绝不创建 / 触碰 auth.json（cc-switch 的关键设计）
    #[test]
    fn save_never_touches_auth_json() {
        let dir = temp_dir("no-auth");
        let path = dir.join("config.toml");
        let auth = dir.join("auth.json");
        // 用户的 ChatGPT 登录缓存
        std::fs::write(
            &auth,
            r#"{"auth_mode":"chatgpt","tokens":{"access_token":"x"}}"#,
        )
        .unwrap();
        let before = std::fs::read_to_string(&auth).unwrap();

        save_provider_at(&path, &sample_entry("my-deepseek")).unwrap();

        let after = std::fs::read_to_string(&auth).unwrap();
        assert_eq!(before, after, "auth.json 必须逐字节不变");
    }

    // TC-CX-04  🔴 保留 id 必须被拒（否则 Codex 0.148+ 拒载整份配置）
    #[test]
    fn save_rejects_reserved_provider_ids() {
        let dir = temp_dir("reserved");
        let path = dir.join("config.toml");
        for id in ["openai", "ollama", "lmstudio"] {
            let err = save_provider_at(&path, &sample_entry(id)).unwrap_err();
            assert!(err.contains("built-in"), "{id} 应被拒: {err}");
            assert!(is_reserved_provider_key(id));
        }
        // 与保留 id 判定是**大小写精确**的（cc-switch 实证：`OpenAI` 是合法自定义
        // id，因为 Codex 的保留判定区分大小写）。BrewPing 侧另有更严的 key 规则
        // （只允许小写），所以 `OpenAI` 会被 key 校验拦下 —— 两层各自的护栏。
        assert!(!is_reserved_provider_key("OpenAI"), "保留判定必须大小写精确");
        let err = save_provider_at(&path, &sample_entry("OpenAI")).unwrap_err();
        assert!(err.contains("invalid provider key"), "大写被 BrewPing key 规则拦下: {err}");
    }

    // TC-CX-05  name 为空必须被拒（Codex 0.149 会整份拒载）
    #[test]
    fn save_rejects_empty_name() {
        let dir = temp_dir("empty-name");
        let path = dir.join("config.toml");
        let mut e = sample_entry("my-x");
        e.name = "  ".into();
        let err = save_provider_at(&path, &e).unwrap_err();
        assert!(err.contains("name"), "{err}");
    }

    // TC-CX-06  wire_api 校验：非法值被拒，空值回落 chat
    #[test]
    fn wire_api_validation_and_default() {
        let dir = temp_dir("wire-api");
        let path = dir.join("config.toml");

        let mut bad = sample_entry("my-x");
        bad.wire_api = "grpc".into();
        assert!(save_provider_at(&path, &bad).is_err());

        let mut blank = sample_entry("my-x");
        blank.wire_api = String::new();
        let info = save_provider_at(&path, &blank).unwrap();
        assert_eq!(info.providers[0].wire_api, "chat");
    }

    // TC-CX-07  多个 provider：互不干扰，只有当前生效的带 model
    #[test]
    fn multiple_providers_coexist() {
        let dir = temp_dir("multi");
        let path = dir.join("config.toml");
        save_provider_at(&path, &sample_entry("a-one")).unwrap();
        save_provider_at(&path, &sample_entry("b-two")).unwrap();

        let info = list_providers_at(&path);
        assert_eq!(info.providers.len(), 2);
        assert_eq!(info.active_id, "b-two");
        let a = info.providers.iter().find(|p| p.id == "a-one").unwrap();
        let b = info.providers.iter().find(|p| p.id == "b-two").unwrap();
        assert!(!a.active);
        assert!(b.active);
        assert!(a.model.is_empty(), "非当前 provider 不应带顶层 model");
        assert_eq!(b.model, "deepseek-chat");
    }

    // TC-CX-08  provider key 校验与派生
    #[test]
    fn key_validation_and_slugify() {
        assert!(is_valid_provider_key("my-deepseek"));
        assert!(!is_valid_provider_key("My-DeepSeek"));
        assert!(!is_valid_provider_key("-lead"));
        assert!(!is_valid_provider_key("trail-"));
        assert!(!is_valid_provider_key("double--dash"));
        assert!(!is_valid_provider_key(""));
        assert_eq!(slugify_provider_key("My DeepSeek"), "my-deepseek");
        assert_eq!(slugify_provider_key("  "), "provider");
        assert_eq!(slugify_provider_key("Kimi (月之暗面)"), "kimi");
    }

    // TC-CX-09  删除：表 + 生效指向一起清；model_providers 空表摘掉
    #[test]
    fn delete_removes_table_and_pointer() {
        let dir = temp_dir("delete");
        let path = dir.join("config.toml");
        save_provider_at(&path, &sample_entry("my-x")).unwrap();
        save_provider_at(&path, &sample_entry("my-y")).unwrap();

        let info = delete_provider_at(&path, "my-y").unwrap();
        assert_eq!(info.providers.len(), 1);
        assert!(info.active_id.is_empty(), "删掉当前生效的应清掉 model_provider");

        let text = std::fs::read_to_string(&path).unwrap();
        assert!(!text.contains("my-y"), "{text}");
    }

    // TC-CX-10  删除非当前 provider：不动 model_provider
    #[test]
    fn delete_inactive_keeps_pointer() {
        let dir = temp_dir("delete-inactive");
        let path = dir.join("config.toml");
        save_provider_at(&path, &sample_entry("keep-me")).unwrap();
        save_provider_at(&path, &sample_entry("drop-me")).unwrap();
        // 让 keep-me 生效
        activate_provider_at(&path, "keep-me").unwrap();

        let info = delete_provider_at(&path, "drop-me").unwrap();
        assert_eq!(info.active_id, "keep-me");
        assert_eq!(info.providers.len(), 1);
    }

    // TC-CX-11  删除 id 不存在 = 幂等成功，且不误删顶层 token
    #[test]
    fn delete_missing_is_idempotent() {
        let dir = temp_dir("delete-missing");
        let path = dir.join("config.toml");
        std::fs::write(&path, "experimental_bearer_token = \"manual\"\nmodel = \"gpt-5\"\n").unwrap();

        let info = delete_provider_at(&path, "nope").unwrap();
        assert!(info.providers.is_empty());
        let text = std::fs::read_to_string(&path).unwrap();
        // 我们没有删过它 —— 文件不应被改写
        assert!(text.contains("manual"), "{text}");
    }

    // TC-CX-12  切换生效 provider
    #[test]
    fn activate_switches_pointer() {
        let dir = temp_dir("activate");
        let path = dir.join("config.toml");
        save_provider_at(&path, &sample_entry("a-one")).unwrap();
        save_provider_at(&path, &sample_entry("b-two")).unwrap();

        let info = activate_provider_at(&path, "a-one").unwrap();
        assert_eq!(info.active_id, "a-one");
        assert!(info.providers.iter().find(|p| p.id == "a-one").unwrap().active);
    }

    // TC-CX-13  切换不存在的 provider 必须报错
    #[test]
    fn activate_unknown_provider_errors() {
        let dir = temp_dir("activate-unknown");
        let path = dir.join("config.toml");
        save_provider_at(&path, &sample_entry("a-one")).unwrap();
        assert!(activate_provider_at(&path, "ghost").is_err());
    }

    // TC-CX-14  非法 TOML 必须报错（不许静默清空用户配置）
    #[test]
    fn invalid_toml_is_rejected() {
        let dir = temp_dir("bad-toml");
        let path = dir.join("config.toml");
        std::fs::write(&path, "this is not [ valid toml").unwrap();
        assert!(save_provider_at(&path, &sample_entry("my-x")).is_err());
    }

    // TC-CX-15  文件不存在时列出 = 空清单（不报错）
    #[test]
    fn list_on_missing_file_is_empty() {
        let dir = temp_dir("missing");
        let path = dir.join("nope.toml");
        let info = list_providers_at(&path);
        assert!(!info.exists);
        assert!(info.providers.is_empty());
        assert_eq!(info.wire_apis.len(), 2);
    }

    // TC-CX-16  更新既有 provider：同 id 覆盖，不产生重复
    #[test]
    fn save_same_id_overwrites() {
        let dir = temp_dir("overwrite");
        let path = dir.join("config.toml");
        save_provider_at(&path, &sample_entry("my-x")).unwrap();
        let mut updated = sample_entry("my-x");
        updated.base_url = "https://new.example".into();
        updated.api_key = "sk-new".into();
        let info = save_provider_at(&path, &updated).unwrap();

        assert_eq!(info.providers.len(), 1);
        assert_eq!(info.providers[0].base_url, "https://new.example");
        assert_eq!(info.providers[0].api_key, "sk-new");
    }

    // TC-CX-17  model 留空时不覆盖用户已有的顶层 model
    #[test]
    fn empty_model_keeps_existing_top_level() {
        let dir = temp_dir("keep-model");
        let path = dir.join("config.toml");
        std::fs::write(&path, "model = \"gpt-5\"\n").unwrap();
        let mut e = sample_entry("my-x");
        e.model = String::new();
        save_provider_at(&path, &e).unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("gpt-5"), "用户原有 model 应保留:\n{text}");
    }
}
