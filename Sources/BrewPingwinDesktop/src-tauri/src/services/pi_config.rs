//! pi 配置文件的**写入**能力（添加 / 编辑 / 删除厂商 = provider）。
//!
//! 对标 cc-switch 的 `pi_config/mod.rs` + `services/provider/pi.rs`：
//! cc-switch 让用户在界面里添加自定义厂商，保存后写进 `~/.pi/agent/models.json`
//! 的 `providers.<key>`，用户无需手改文件。本模块提供同一件事。
//!
//! ## 契约（自 cc-switch 实证，逐条对齐）
//!
//! - **路径**：`~/.pi/agent/models.json`（provider 定义）+ `~/.pi/agent/settings.json`
//!   （默认项 `defaultProvider` / `defaultModel`，**成对生效**）。
//!   cc-switch 支持 `PI_CODING_AGENT_DIR` 环境变量重定向 agent 目录；我们沿用
//!   `agent_config::pi_models_paths()` 的单一顺序，保证"读到什么就写回什么"。
//! - **增量模式**：只动 `providers.<key>` 这一个节点，**绝不重建根节点** ——
//!   用户 `models.json` 里的其他键原样保留。（与 Claude 的整体覆盖形成对照，
//!   这是 cc-switch 两种模式的真实差异。）
//! - **`providers` 段**：缺失 → 视为空对象（合法，首次添加即此场景）；
//!   存在但**非对象 → 报错**（cc-switch 同款：不静默重置，拒绝优于猜）。
//!   根非对象 → 报错。
//! - **字段语义**（pi provider 三件套）：
//!   - `baseUrl`   ← 用户填的 API 地址
//!   - `apiKey`    ← 用户填的 API Key
//!   - `api`       ← 协议（`anthropic-messages` / `openai-completions` …）
//!   - `models[]`  ← `{ id, name }` 清单（数组，与 opencode 的对象不同）
//! - **🔴 不碰 `~/.pi/agent/auth.json`** —— pi 自己的 `/login` 凭据存在那里，
//!   由 pi 管理，cc-switch 明确"绝不读写"。
//! - **provider key 不可改名**（cc-switch 实证：`Pi provider keys cannot be renamed`），
//!   改 key = 新建 + 删旧，前端编辑时禁用 key 输入。
//! - **读**：文件缺失 / 空 → 空清单（不报错）；解析失败 → 空清单。
//! - **串行**：进程内 Mutex 保护；写时**原子替换**（先写临时文件再 rename），
//!   避免写一半崩溃留下半截 JSON（cc-switch 的 `atomic_write_private` 同款思路）。
//!
//! 模块**不依赖 tauri 类型**（services 层同款约束，cargo test 可裸跑）。
//! 网络调用（拉模型列表）不在这里——那属 command 层。

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::OnceLock;

/// pi provider 的 `api` 取值（一组 (值, 标签)，前端下拉直接消费）。
///
/// 顺序：Anthropic Messages 优先（BrewPing 转发链路零协议转换的那一支）。
pub const PI_APIS: &[(&str, &str)] = &[
    ("anthropic-messages", "Anthropic Messages"),
    ("openai-completions", "OpenAI Completions"),
    ("openai-responses", "OpenAI Responses"),
];

/// 默认 `api`。
pub const DEFAULT_API: &str = "anthropic-messages";

// ─── DTO ─────────────────────────────────────────────────────────────────────

/// 一个模型条目（pi `providers.<key>.models[]` 的元素）。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PiModelEntry {
    /// 模型 id（pi `models[].id`）。
    pub id: String,
    /// 展示名（pi `models[].name`，可空 = 回落 id）。
    #[serde(default)]
    pub name: String,
}

/// 一个 pi 厂商配置（前端表单 ↔ models.json 的 `providers.<key>`）。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PiProviderEntry {
    /// provider key（`providers` 对象的 key）。形如 `my-deepseek`。
    /// **不可改名**（cc-switch 实证）。
    #[serde(default)]
    pub id: String,
    /// 展示名（pi `providers.<key>.name`，可空）。
    #[serde(default)]
    pub name: String,
    /// API 基址（pi 配置文件里是 `baseUrl`）。注意磁盘键与 DTO 键不同名。
    ///
    /// 🚨 必须显式 `rename = "baseURL"`（DTO 侧）：
    /// - `rename_all = "camelCase"` 会派生 `baseUrl`，而前端 DTO 用 `baseURL`；
    /// - 缺这一行会让前端读到 undefined → 点「配置厂商」进表单时
    ///   `value.baseURL.trim()` 抛 TypeError → 白屏（Claude 模块同款问题）。
    /// 磁盘上的 `baseUrl` 由 `apply_entry` 单独负责映射，与此无关。
    #[serde(rename = "baseURL", default)]
    pub base_url: String,
    /// API Key（pi `apiKey`）。
    /// 读出时**不脱敏**——这是用户自己的配置文件，界面按需自行掩码显示。
    #[serde(default)]
    pub api_key: String,
    /// 协议（pi `api`）。空则回落 `anthropic-messages`。
    #[serde(default)]
    pub api: String,
    /// 模型清单。
    #[serde(default)]
    pub models: Vec<PiModelEntry>,
    /// 是否为当前默认 provider（`settings.defaultProvider == id`）。
    #[serde(default)]
    pub is_default: bool,
}

/// 列出 pi 厂商的结果（供前端渲染卡片列表）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PiProvidersInfo {
    /// models.json 绝对路径（展示用）。
    pub config_file: String,
    /// models.json 当前是否存在。
    pub exists: bool,
    /// settings.json 绝对路径（展示用；默认项写这里）。
    pub settings_file: String,
    /// 当前默认 provider（`settings.defaultProvider`）。
    pub default_provider: String,
    /// 当前默认模型（`settings.defaultModel`）。
    pub default_model: String,
    /// 已配置的厂商（按 key 排序）。
    pub providers: Vec<PiProviderEntry>,
    /// 可选 `api` 清单（值 + 标签）。
    pub apis: Vec<PiApiOption>,
}

/// `api` 选项。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PiApiOption {
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

/// models.json 候选路径（顺序即优先级，与 `agent_config::pi_models_paths` 一致）。
pub fn pi_models_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Some(home) = dirs::home_dir() {
        paths.push(home.join(".pi").join("agent").join("models.json"));
    }
    paths
}

/// settings.json 候选路径（存储 defaultProvider / defaultModel）。
pub fn pi_settings_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Some(home) = dirs::home_dir() {
        paths.push(home.join(".pi").join("agent").join("settings.json"));
    }
    paths
}

/// 实际用于读写的 models.json 路径。
pub fn resolve_models_path() -> PathBuf {
    let paths = pi_models_paths();
    paths
        .iter()
        .find(|p| p.is_file())
        .cloned()
        .or_else(|| paths.into_iter().next())
        .unwrap_or_else(|| PathBuf::from(".pi/agent/models.json"))
}

/// 实际用于读写的 settings.json 路径（与 models.json **同目录**派生）。
///
/// 刻意从 models.json 的解析结果推同目录，而不是各查各的 —— 否则用户在
/// 非常规位置放了 models.json 时，默认项会写到另一处的 settings.json 去。
pub fn resolve_settings_path(models_path: &Path) -> PathBuf {
    models_path
        .parent()
        .map(|p| p.join("settings.json"))
        .unwrap_or_else(|| PathBuf::from(".pi/agent/settings.json"))
}

// ─── 读写核心 ────────────────────────────────────────────────────────────────

fn config_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
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

/// 读整份 models.json。文件缺失 / 空 → 空对象；根非对象 → 报错。
fn read_models_at(path: &Path) -> Result<Value, String> {
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

/// 读 settings.json（宽容：读不到就用空对象 —— 默认项是可选增强）。
fn read_settings_at(path: &Path) -> Value {
    let Ok(text) = std::fs::read_to_string(path) else {
        return json!({});
    };
    if text.trim().is_empty() {
        return json!({});
    }
    let Ok(value) = serde_json::from_str::<Value>(&text) else {
        return json!({});
    };
    if value.is_object() { value } else { json!({}) }
}

/// 原子写：先写同目录临时文件，再 rename 覆盖（避免写一半留下半截 JSON）。
fn write_atomic(path: &Path, value: &Value) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("create {} failed: {e}", parent.display()))?;
    }
    let data = serde_json::to_string_pretty(value).map_err(|e| e.to_string())?;
    let tmp = path.with_extension("json.brewping-tmp");
    std::fs::write(&tmp, format!("{data}\n"))
        .map_err(|e| format!("write {} failed: {e}", tmp.display()))?;
    std::fs::rename(&tmp, path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        format!("replace {} failed: {e}", path.display())
    })
}

/// 取 `providers` 对象的可变引用；缺失则创建，非对象则报错（cc-switch 同款）。
fn providers_mut<'a>(root: &'a mut Value, path: &Path) -> Result<&'a mut Map<String, Value>, String> {
    let obj = root
        .as_object_mut()
        .expect("read_models_at 已保证根是对象");
    let entry = obj.entry("providers").or_insert_with(|| json!({}));
    if !entry.is_object() {
        // 先算出描述再借用（否则 format! 里的不可变借用与返回的可变借用冲突）
        let found = type_name(entry);
        return Err(format!(
            "{} 'providers' must be an object (found {found})",
            path.display()
        ));
    }
    Ok(entry
        .as_object_mut()
        .expect("上一步已保证 providers 是对象"))
}

/// 把前端 DTO 转成 pi 磁盘格式的 provider 节点。
fn entry_to_value(entry: &PiProviderEntry) -> Value {
    let mut provider = Map::new();

    let name = entry.name.trim();
    if !name.is_empty() {
        provider.insert("name".into(), json!(name));
    }
    provider.insert("baseUrl".into(), json!(entry.base_url.trim()));
    if !entry.api_key.trim().is_empty() {
        provider.insert("apiKey".into(), json!(entry.api_key.trim()));
    }
    let api = if entry.api.trim().is_empty() { DEFAULT_API } else { entry.api.trim() };
    provider.insert("api".into(), json!(api));

    let models: Vec<Value> = entry
        .models
        .iter()
        .filter(|m| !m.id.trim().is_empty())
        .map(|m| {
            let id = m.id.trim();
            let name = if m.name.trim().is_empty() { id } else { m.name.trim() };
            json!({ "id": id, "name": name })
        })
        .collect();
    provider.insert("models".into(), Value::Array(models));

    Value::Object(provider)
}

/// 把磁盘上的 provider 节点还原成 DTO。
fn value_to_entry(key: &str, value: &Value) -> PiProviderEntry {
    let name = value
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let base_url = value
        .get("baseUrl")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let api_key = value
        .get("apiKey")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let api = value
        .get("api")
        .and_then(Value::as_str)
        .unwrap_or(DEFAULT_API)
        .to_string();

    let mut models: Vec<PiModelEntry> = Vec::new();
    if let Some(arr) = value.get("models").and_then(Value::as_array) {
        for m in arr {
            let Some(id) = m.get("id").and_then(Value::as_str) else {
                continue;
            };
            models.push(PiModelEntry {
                id: id.to_string(),
                name: m
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or(id)
                    .to_string(),
            });
        }
    }
    models.sort_by(|a, b| a.id.cmp(&b.id));

    PiProviderEntry {
        id: key.to_string(),
        name,
        base_url,
        api_key,
        api,
        models,
        is_default: false, // 由调用方按 settings 填
    }
}

fn api_options() -> Vec<PiApiOption> {
    PI_APIS
        .iter()
        .map(|(value, label)| PiApiOption {
            value: (*value).to_string(),
            label: (*label).to_string(),
        })
        .collect()
}

// ─── 对外 API（command 层消费） ──────────────────────────────────────────────
//
// 生产入口用本机真实路径；`*_at(models_path)` 显式指定路径（测试用）。

/// 列出本机 pi 已配置的全部 provider。
pub fn list_providers() -> PiProvidersInfo {
    let models_path = resolve_models_path();
    list_providers_at(&models_path, &resolve_settings_path(&models_path))
}

/// `list_providers` 的显式路径版本。
pub fn list_providers_at(models_path: &Path, settings_path: &Path) -> PiProvidersInfo {
    let exists = models_path.is_file();
    let settings = read_settings_at(settings_path);
    let default_provider = settings
        .get("defaultProvider")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let default_model = settings
        .get("defaultModel")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();

    let mut providers: Vec<PiProviderEntry> = match read_models_at(models_path) {
        Ok(root) => root
            .get("providers")
            .and_then(Value::as_object)
            .map(|obj| {
                obj.iter()
                    .map(|(k, v)| value_to_entry(k, v))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default(),
        Err(_) => Vec::new(),
    };
    for p in &mut providers {
        p.is_default = !default_provider.is_empty() && p.id == default_provider;
    }
    providers.sort_by(|a, b| a.id.cmp(&b.id));

    PiProvidersInfo {
        config_file: models_path.display().to_string(),
        exists,
        settings_file: settings_path.display().to_string(),
        default_provider,
        default_model,
        providers,
        apis: api_options(),
    }
}

/// 写入 / 更新一个 provider（幂等：同 id 重复保存 = 覆盖）。
///
/// 若 `entry.id` 等于当前默认 provider，则同时对齐 `settings.defaultModel`
/// （保证默认项成对，不出现"默认 provider 指向了一个不存在的模型"）。
pub fn save_provider(entry: &PiProviderEntry) -> Result<PiProvidersInfo, String> {
    let models_path = resolve_models_path();
    save_provider_at(&models_path, &resolve_settings_path(&models_path), entry)
}

/// `save_provider` 的显式路径版本（测试用，不碰用户真实配置）。
pub fn save_provider_at(
    models_path: &Path,
    settings_path: &Path,
    entry: &PiProviderEntry,
) -> Result<PiProvidersInfo, String> {
    let id = entry.id.trim().to_string();
    if !is_valid_provider_key(&id) {
        return Err(format!(
            "invalid provider key '{id}': use lowercase letters, digits and single dashes (e.g. my-deepseek)"
        ));
    }
    let base = entry.base_url.trim();
    if base.is_empty() {
        return Err("baseUrl must not be empty".into());
    }
    if !(base.starts_with("http://") || base.starts_with("https://")) {
        return Err("baseUrl must start with http:// or https://".into());
    }
    let api = if entry.api.trim().is_empty() { DEFAULT_API } else { entry.api.trim() };
    if !PI_APIS.iter().any(|(v, _)| *v == api) {
        return Err(format!(
            "invalid api '{api}': expected one of {}",
            PI_APIS.iter().map(|(v, _)| *v).collect::<Vec<_>>().join(", ")
        ));
    }
    if entry.models.iter().all(|m| m.id.trim().is_empty()) {
        return Err("at least one model is required".into());
    }

    let _guard = config_lock()
        .lock()
        .map_err(|_| "config lock poisoned".to_string())?;

    // 读全文 → 只动 providers.<id> → 写回（其余键原样保留）
    let mut root = read_models_at(models_path)?;
    {
        let providers = providers_mut(&mut root, models_path)?;
        providers.insert(id.clone(), entry_to_value(entry));
    }
    write_atomic(models_path, &root)?;

    // 默认项：只有当这家已是/将要是默认 provider 时才动 settings
    let settings = read_settings_at(settings_path);
    let current_default = settings
        .get("defaultProvider")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if current_default == id {
        // 默认 provider 的模型列表变了 → 保证 defaultModel 仍指向一个存在的模型
        let first_model = entry
            .models
            .iter()
            .find(|m| !m.id.trim().is_empty())
            .map(|m| m.id.trim().to_string());
        if let Some(first_model) = first_model {
            let mut next = settings.clone();
            let current_model = settings
                .get("defaultModel")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            let still_exists = entry
                .models
                .iter()
                .any(|m| m.id.trim() == current_model);
            if !still_exists {
                if let Some(obj) = next.as_object_mut() {
                    obj.insert("defaultModel".into(), json!(first_model));
                    write_atomic(settings_path, &next)?;
                }
            }
        }
    }

    Ok(list_providers_at(models_path, settings_path))
}

/// 删除一个 provider（按 id；不存在则视为成功 = 幂等）。
///
/// 若删的是当前默认 provider，则同步清掉 `settings` 的默认项（成对，不留悬空引用）。
pub fn delete_provider(id: &str) -> Result<PiProvidersInfo, String> {
    let models_path = resolve_models_path();
    delete_provider_at(&models_path, &resolve_settings_path(&models_path), id)
}

/// `delete_provider` 的显式路径版本（测试用）。
pub fn delete_provider_at(
    models_path: &Path,
    settings_path: &Path,
    id: &str,
) -> Result<PiProvidersInfo, String> {
    let id = id.trim();
    if id.is_empty() {
        return Err("provider id must not be empty".into());
    }
    let _guard = config_lock()
        .lock()
        .map_err(|_| "config lock poisoned".to_string())?;

    if models_path.is_file() {
        let mut root = read_models_at(models_path)?;
        let removed = root
            .get_mut("providers")
            .and_then(Value::as_object_mut)
            .map(|providers| providers.remove(id).is_some())
            .unwrap_or(false);
        if removed {
            write_atomic(models_path, &root)?;
        }
    }

    // 默认项清理：只在默认 provider 正是被删的这家时动手（按值判定，不误删）
    let settings = read_settings_at(settings_path);
    let is_default = settings.get("defaultProvider").and_then(Value::as_str) == Some(id);
    if is_default {
        let mut next = settings.clone();
        if let Some(obj) = next.as_object_mut() {
            obj.remove("defaultProvider");
            obj.remove("defaultModel");
            write_atomic(settings_path, &next)?;
        }
    }

    Ok(list_providers_at(models_path, settings_path))
}

/// 把某家设为默认（写 `defaultProvider` + `defaultModel`，**成对**）。
///
/// pi 无环境变量入口 —— 默认项是它唯一的"当前用哪家"开关，
/// 所以切换语义必须写 settings（与 cc-switch 的"不碰默认"是有意差异：
/// cc-switch 只做 provider 管理，BrewPing 还要服务转发链路）。
pub fn activate_provider(id: &str, model: Option<&str>) -> Result<PiProvidersInfo, String> {
    let models_path = resolve_models_path();
    let settings_path = resolve_settings_path(&models_path);
    activate_provider_at(&models_path, &settings_path, id, model)
}

/// `activate_provider` 的显式路径版本（测试用）。
pub fn activate_provider_at(
    models_path: &Path,
    settings_path: &Path,
    id: &str,
    model: Option<&str>,
) -> Result<PiProvidersInfo, String> {
    let id = id.trim();
    if id.is_empty() {
        return Err("provider id must not be empty".into());
    }
    let _guard = config_lock()
        .lock()
        .map_err(|_| "config lock poisoned".to_string())?;

    let root = read_models_at(models_path)?;
    let provider = root
        .get("providers")
        .and_then(Value::as_object)
        .and_then(|p| p.get(id))
        .ok_or_else(|| format!("provider '{id}' not found in models.json"))?;

    // 模型：显式传入优先；否则取该 provider 的第一个模型（成对，不留悬空）
    let model_id = match model {
        Some(m) if !m.trim().is_empty() => m.trim().to_string(),
        _ => provider
            .get("models")
            .and_then(Value::as_array)
            .and_then(|arr| arr.iter().find_map(|m| m.get("id").and_then(Value::as_str)))
            .ok_or_else(|| format!("provider '{id}' has no models to select"))?
            .to_string(),
    };

    let mut settings = read_settings_at(settings_path);
    if !settings.is_object() {
        settings = json!({});
    }
    if let Some(obj) = settings.as_object_mut() {
        obj.insert("defaultProvider".into(), json!(id));
        obj.insert("defaultModel".into(), json!(model_id));
    }
    write_atomic(settings_path, &settings)?;

    Ok(list_providers_at(models_path, settings_path))
}

/// 读一份指定路径的 models.json（测试用）。
pub fn read_config(path: &Path) -> Result<Value, String> {
    read_models_at(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "brewping-pi-{}-{}",
            tag,
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn paths(dir: &Path) -> (PathBuf, PathBuf) {
        (dir.join("models.json"), dir.join("settings.json"))
    }

    fn sample_entry(id: &str, name: &str) -> PiProviderEntry {
        PiProviderEntry {
            id: id.into(),
            name: name.into(),
            base_url: "https://api.deepseek.com/anthropic".into(),
            api_key: "sk-test".into(),
            api: "anthropic-messages".into(),
            models: vec![
                PiModelEntry { id: "deepseek-v4-pro".into(), name: "DeepSeek V4 Pro".into() },
                PiModelEntry { id: "deepseek-chat".into(), name: String::new() },
            ],
            is_default: false,
        }
    }

    // TC-PI-01  全新文件：保存即创建，三件套 + models 写入
    #[test]
    fn save_creates_provider_node() {
        let dir = temp_dir("create");
        let (mp, sp) = paths(&dir);
        let info = save_provider_at(&mp, &sp, &sample_entry("my-deepseek", "DeepSeek")).unwrap();

        assert!(info.exists);
        assert_eq!(info.providers.len(), 1);
        let p = &info.providers[0];
        assert_eq!(p.base_url, "https://api.deepseek.com/anthropic");
        assert_eq!(p.api_key, "sk-test");
        assert_eq!(p.api, "anthropic-messages");
        assert_eq!(p.models.len(), 2);

        let raw: Value = serde_json::from_str(&std::fs::read_to_string(&mp).unwrap()).unwrap();
        assert_eq!(
            raw.pointer("/providers/my-deepseek/baseUrl").and_then(Value::as_str),
            Some("https://api.deepseek.com/anthropic")
        );
        // models 是数组（与 opencode 的对象不同！）
        assert!(raw.pointer("/providers/my-deepseek/models").unwrap().is_array());
    }

    // TC-PI-02  增量模式：用户 models.json 里的其他键原样保留
    #[test]
    fn save_preserves_unrelated_keys() {
        let dir = temp_dir("preserve");
        let (mp, sp) = paths(&dir);
        std::fs::write(
            &mp,
            r#"{"version":3,"theme":"dark","providers":{"existing":{"baseUrl":"https://e.x"}}}"#,
        )
        .unwrap();

        save_provider_at(&mp, &sp, &sample_entry("my-deepseek", "DeepSeek")).unwrap();

        let raw: Value = serde_json::from_str(&std::fs::read_to_string(&mp).unwrap()).unwrap();
        assert_eq!(raw.get("version").and_then(Value::as_u64), Some(3), "version 必须保留");
        assert_eq!(raw.get("theme").and_then(Value::as_str), Some("dark"));
        assert!(
            raw.pointer("/providers/existing").is_some(),
            "既有 provider 必须保留"
        );
        assert_eq!(info_provider_count(&mp), 2);
    }

    fn info_provider_count(models: &Path) -> usize {
        let raw: Value = serde_json::from_str(&std::fs::read_to_string(models).unwrap()).unwrap();
        raw.pointer("/providers").unwrap().as_object().unwrap().len()
    }

    // TC-PI-03  🔴 绝不创建 / 触碰 auth.json（pi 的 /login 凭据归 pi 管）
    #[test]
    fn save_never_touches_auth_json() {
        let dir = temp_dir("no-auth");
        let (mp, sp) = paths(&dir);
        let auth = dir.join("auth.json");
        std::fs::write(&auth, r#"{"openai":{"access_token":"x"}}"#).unwrap();
        let before = std::fs::read_to_string(&auth).unwrap();

        save_provider_at(&mp, &sp, &sample_entry("my-x", "X")).unwrap();

        assert_eq!(std::fs::read_to_string(&auth).unwrap(), before, "auth.json 必须不变");
    }

    // TC-PI-04  providers 段缺失 → 视为空对象（合法）；存在但非对象 → 报错
    #[test]
    fn providers_section_missing_ok_non_object_errors() {
        let dir = temp_dir("providers-shape");
        let (mp, sp) = paths(&dir);

        // 缺失 = 空对象，保存成功
        std::fs::write(&mp, r#"{"version":1}"#).unwrap();
        assert!(save_provider_at(&mp, &sp, &sample_entry("my-x", "X")).is_ok());

        // 非对象 = 报错（不静默重置）
        std::fs::write(&mp, r#"{"providers":"oops"}"#).unwrap();
        let err = save_provider_at(&mp, &sp, &sample_entry("my-x", "X")).unwrap_err();
        assert!(err.contains("providers"), "{err}");
    }

    // TC-PI-05  根非对象 / 非法 JSON 必须报错
    #[test]
    fn read_rejects_bad_root() {
        let dir = temp_dir("bad-root");
        let p = dir.join("models.json");
        std::fs::write(&p, "[1,2]").unwrap();
        assert!(read_models_at(&p).is_err());
        std::fs::write(&p, "{bad").unwrap();
        assert!(read_models_at(&p).is_err());
    }

    // TC-PI-06  校验：空 baseUrl / 非 http / 非法 api / 无模型
    #[test]
    fn save_validates_inputs() {
        let dir = temp_dir("validate");
        let (mp, sp) = paths(&dir);

        let mut e = sample_entry("my-x", "X");
        e.base_url = "  ".into();
        assert!(save_provider_at(&mp, &sp, &e).is_err());

        let mut e = sample_entry("my-x", "X");
        e.base_url = "ftp://x".into();
        assert!(save_provider_at(&mp, &sp, &e).is_err());

        let mut e = sample_entry("my-x", "X");
        e.api = "grpc".into();
        assert!(save_provider_at(&mp, &sp, &e).is_err());

        let mut e = sample_entry("my-x", "X");
        e.models = vec![PiModelEntry { id: "  ".into(), name: String::new() }];
        assert!(save_provider_at(&mp, &sp, &e).is_err());

        let mut e = sample_entry("Bad-Key", "X");
        e.id = "Bad-Key".into();
        assert!(save_provider_at(&mp, &sp, &e).is_err());
    }

    // TC-PI-07  api 空值回落 anthropic-messages
    #[test]
    fn empty_api_falls_back_to_default() {
        let dir = temp_dir("api-default");
        let (mp, sp) = paths(&dir);
        let mut e = sample_entry("my-x", "X");
        e.api = String::new();
        let info = save_provider_at(&mp, &sp, &e).unwrap();
        assert_eq!(info.providers[0].api, "anthropic-messages");
    }

    // TC-PI-08  设为默认：defaultProvider + defaultModel 成对写入
    #[test]
    fn activate_writes_default_pair() {
        let dir = temp_dir("activate");
        let (mp, sp) = paths(&dir);
        save_provider_at(&mp, &sp, &sample_entry("my-x", "X")).unwrap();

        let info = activate_provider_at(&mp, &sp, "my-x", None).unwrap();
        assert_eq!(info.default_provider, "my-x");
        // 取用户填写的**第一个**模型（数组原序 = 用户排的优先级，不重排）
        assert_eq!(info.default_model, "deepseek-v4-pro", "应取数组首个模型");
        assert!(info.providers[0].is_default);

        let raw: Value = serde_json::from_str(&std::fs::read_to_string(&sp).unwrap()).unwrap();
        assert_eq!(raw.get("defaultProvider").and_then(Value::as_str), Some("my-x"));
        assert!(raw.get("defaultModel").is_some());
    }

    // TC-PI-09  设为默认时指定模型生效
    #[test]
    fn activate_with_explicit_model() {
        let dir = temp_dir("activate-model");
        let (mp, sp) = paths(&dir);
        save_provider_at(&mp, &sp, &sample_entry("my-x", "X")).unwrap();
        let info = activate_provider_at(&mp, &sp, "my-x", Some("deepseek-v4-pro")).unwrap();
        assert_eq!(info.default_model, "deepseek-v4-pro");
    }

    // TC-PI-10  删除：节点移除；删的若是默认 provider 则默认项一并清（不留悬空）
    #[test]
    fn delete_clears_default_when_needed() {
        let dir = temp_dir("delete");
        let (mp, sp) = paths(&dir);
        save_provider_at(&mp, &sp, &sample_entry("my-x", "X")).unwrap();
        activate_provider_at(&mp, &sp, "my-x", None).unwrap();

        let info = delete_provider_at(&mp, &sp, "my-x").unwrap();
        assert!(info.providers.is_empty());
        assert!(info.default_provider.is_empty(), "默认项必须一起清");
        assert!(info.default_model.is_empty());
    }

    // TC-PI-11  删除非默认 provider：默认项不动
    #[test]
    fn delete_inactive_keeps_default() {
        let dir = temp_dir("delete-inactive");
        let (mp, sp) = paths(&dir);
        save_provider_at(&mp, &sp, &sample_entry("keep-me", "K")).unwrap();
        save_provider_at(&mp, &sp, &sample_entry("drop-me", "D")).unwrap();
        activate_provider_at(&mp, &sp, "keep-me", None).unwrap();

        let info = delete_provider_at(&mp, &sp, "drop-me").unwrap();
        assert_eq!(info.default_provider, "keep-me");
        assert_eq!(info.providers.len(), 1);
    }

    // TC-PI-12  幂等：同 id 重复保存不重复；同内容重复保存结果一致
    #[test]
    fn save_is_idempotent() {
        let dir = temp_dir("idempotent");
        let (mp, sp) = paths(&dir);
        save_provider_at(&mp, &sp, &sample_entry("my-x", "X")).unwrap();
        let first = std::fs::read_to_string(&mp).unwrap();
        save_provider_at(&mp, &sp, &sample_entry("my-x", "X")).unwrap();
        let second = std::fs::read_to_string(&mp).unwrap();
        assert_eq!(first, second);
        assert_eq!(info_provider_count(&mp), 1);
    }

    // TC-PI-13  更新既有 provider：同 id 覆盖
    #[test]
    fn save_same_id_overwrites() {
        let dir = temp_dir("overwrite");
        let (mp, sp) = paths(&dir);
        save_provider_at(&mp, &sp, &sample_entry("my-x", "Old")).unwrap();
        let mut e = sample_entry("my-x", "New");
        e.base_url = "https://new.example".into();
        let info = save_provider_at(&mp, &sp, &e).unwrap();
        assert_eq!(info.providers.len(), 1);
        assert_eq!(info.providers[0].name, "New");
        assert_eq!(info.providers[0].base_url, "https://new.example");
    }

    // TC-PI-14  默认 provider 的模型被改掉后，defaultModel 自动对齐到存在的模型
    #[test]
    fn save_realigns_default_model() {
        let dir = temp_dir("realign");
        let (mp, sp) = paths(&dir);
        save_provider_at(&mp, &sp, &sample_entry("my-x", "X")).unwrap();
        activate_provider_at(&mp, &sp, "my-x", Some("deepseek-v4-pro")).unwrap();

        // 把 deepseek-v4-pro 从模型列表里去掉
        let mut e = sample_entry("my-x", "X");
        e.models = vec![PiModelEntry { id: "only-model".into(), name: String::new() }];
        let info = save_provider_at(&mp, &sp, &e).unwrap();

        assert_eq!(info.default_model, "only-model", "悬空的 defaultModel 应被修正");
    }

    // TC-PI-15  设为不存在 / 无模型的 provider 必须报错
    #[test]
    fn activate_errors_on_missing_or_modelless() {
        let dir = temp_dir("activate-err");
        let (mp, sp) = paths(&dir);
        save_provider_at(&mp, &sp, &sample_entry("my-x", "X")).unwrap();

        assert!(activate_provider_at(&mp, &sp, "ghost", None).is_err());

        // 无模型（直接手写文件构造）
        let raw = json!({"providers":{"bare":{"baseUrl":"https://x","models":[]}}});
        write_atomic(&mp, &raw).unwrap();
        assert!(activate_provider_at(&mp, &sp, "bare", None).is_err());
    }

    // TC-PI-16  文件不存在时列出 = 空清单（不报错）
    #[test]
    fn list_on_missing_file_is_empty() {
        let dir = temp_dir("missing");
        let (mp, sp) = paths(&dir);
        let info = list_providers_at(&mp, &sp);
        assert!(!info.exists);
        assert!(info.providers.is_empty());
        assert_eq!(info.apis.len(), 3);
    }

    // TC-PI-17  key 校验与派生
    #[test]
    fn key_validation_and_slugify() {
        assert!(is_valid_provider_key("my-deepseek"));
        assert!(!is_valid_provider_key("My-DeepSeek"));
        assert!(!is_valid_provider_key("-lead"));
        assert!(!is_valid_provider_key("double--dash"));
        assert!(!is_valid_provider_key(""));
        assert_eq!(slugify_provider_key("My DeepSeek"), "my-deepseek");
        assert_eq!(slugify_provider_key("Kimi (月之暗面)"), "kimi");
        assert_eq!(slugify_provider_key("!!!"), "provider");
    }

    // TC-PI-18  原子写：不留临时文件残留
    #[test]
    fn atomic_write_leaves_no_temp_file() {
        let dir = temp_dir("atomic");
        let (mp, sp) = paths(&dir);
        save_provider_at(&mp, &sp, &sample_entry("my-x", "X")).unwrap();
        let leftovers: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains("brewping-tmp"))
            .collect();
        assert!(leftovers.is_empty(), "不应留下临时文件");
    }

    // TC-PI-19  settings.json 与 models.json 同目录（非常规位置的正确性）
    #[test]
    fn settings_path_derives_from_models_dir() {
        let dir = temp_dir("same-dir");
        let (mp, _) = paths(&dir);
        let derived = resolve_settings_path(&mp);
        assert_eq!(derived, dir.join("settings.json"));
    }
}
