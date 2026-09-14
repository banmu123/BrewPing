//! OpenCode 配置文件的**写入**能力（添加 / 编辑 / 删除厂商 = provider）。
//!
//! 对标 cc-switch 的 `opencode_config.rs`：cc-switch 让用户在界面里添加自定义
//! 厂商，保存后直接把配置写进本机 opencode 的 `opencode.json`，用户无需手改文件。
//! 本模块提供同一件事，但**刻意只做 opencode 专属**——不并入通用 provider 存储，
//! 因为 opencode 的配置格式（npm 包 + options + models）与 BrewPing 自己的
//! 转发链路是两套东西。
//!
//! ## 契约（自 cc-switch 实证，逐条对齐）
//!
//! - **路径**：优先 `~/.config/opencode/opencode.json`（opencode 官方位置），
//!   不存在时回落 `%APPDATA%\opencode\opencode.json`——与
//!   `agent_config::opencode_paths()` **同一顺序**，保证"读到什么就写回什么"。
//! - **读**：文件缺失 → 返回 `{"$schema": "https://opencode.ai/config.json"}` 骨架，
//!   而不是报错（首次添加厂商是合法场景）。**根不是对象 → 报错**，
//!   因为下游 `config["provider"] = …` 对非对象会 panic（cc-switch 的教训）。
//! - **写**：读全文 → 把 `provider` 归一化成对象 → `provider[id] = cfg` → 写回。
//!   **绝不重建根节点**，用户配置里的 `model` / `theme` / `$schema` 等原样保留。
//! - **删**：按 id 删 `provider.<id>`，其余条目不动。
//! - **串行**：进程内 Mutex 保护，避免两个界面同时写导致丢更新。
//!
//! 模块**不依赖 tauri 类型**（services 层同款约束，cargo test 可裸跑）。
//! 网络调用（拉模型列表）不在这里——那属 command 层。

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::OnceLock;

/// opencode.json 的官方 schema 地址（新建骨架时写入）。
pub const OPENCODE_SCHEMA: &str = "https://opencode.ai/config.json";

/// 默认 npm 接口包 —— 兼容 OpenAI 协议的中转站 / 厂商最常见（cc-switch 同款默认）。
pub const DEFAULT_NPM: &str = "@ai-sdk/openai-compatible";

/// 可选的 npm 接口包（对应 opencode 的 `provider.<id>.npm`）。
/// 一组 (值, 中文标签)，前端下拉直接消费；顺序与 cc-switch 一致。
pub const NPM_PACKAGES: &[(&str, &str)] = &[
    ("@ai-sdk/openai-compatible", "OpenAI 兼容"),
    ("@ai-sdk/openai", "OpenAI Responses"),
    ("@ai-sdk/anthropic", "Anthropic"),
    ("@ai-sdk/google", "Google"),
    ("@ai-sdk/amazon-bedrock", "Amazon Bedrock"),
];

// ─── DTO ─────────────────────────────────────────────────────────────────────

/// 一个模型条目（opencode `provider.<id>.models.<modelId>`）。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeModelEntry {
    /// 模型 id（即 models 对象的 key；此字段仅用于传输，写入时作 key）。
    pub id: String,
    /// 展示名（可空 —— 空则 opencode 回落 id）。
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub name: String,
}

/// 一个 provider 的完整配置（前端表单 ↔ opencode.json 段落）。
///
/// 🔴 字段名是 **opencode 磁盘格式**，不是 BrewPing 内部命名：
/// `baseURL` 大写的 URL 是 opencode 的既有约定，不能"顺手改成 baseUrl"。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeProviderEntry {
    /// provider key（`provider` 对象的 key）。形如 `my-deepseek`。
    pub id: String,
    /// 展示名（opencode `provider.<id>.name`）。
    pub name: String,
    /// npm 接口包（opencode `provider.<id>.npm`）。空则回落 `DEFAULT_NPM`。
    #[serde(default)]
    pub npm: String,
    /// API 基址（opencode `provider.<id>.options.baseURL`）。
    #[serde(rename = "baseURL", default)]
    pub base_url: String,
    /// API Key（opencode `provider.<id>.options.apiKey`）。
    /// 读出时**不脱敏**——这是用户自己的配置文件，界面按需自行掩码显示。
    #[serde(rename = "apiKey", default)]
    pub api_key: String,
    /// 附加请求头（可空）。
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub headers: Map<String, Value>,
    /// 模型清单。
    #[serde(default)]
    pub models: Vec<OpenCodeModelEntry>,
}

/// 列出全部 provider 的结果（供前端渲染卡片列表）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeProvidersInfo {
    /// 配置文件绝对路径（展示用，让用户知道东西写到哪了）。
    pub config_file: String,
    /// 配置文件当前是否存在。
    pub exists: bool,
    /// 已配置的 provider（按 id 排序）。
    pub providers: Vec<OpenCodeProviderEntry>,
    /// 可选 npm 接口包清单（值 + 标签），前端下拉直接吃。
    pub npm_packages: Vec<NpmPackageOption>,
}

/// npm 接口包选项。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NpmPackageOption {
    pub value: String,
    pub label: String,
}

// ─── provider key 校验 / 派生 ────────────────────────────────────────────────

/// 校验 provider key：只允许小写字母数字，可用连字符分组（`my-deepseek`）。
///
/// 为什么这么严：这个 key 会成为 opencode.json 的对象键、也会出现在
/// `provider/<id>` 形式的内部标识里，大写 / 空格 / 中文都会在别处炸开。
pub fn is_valid_provider_key(key: &str) -> bool {
    if key.is_empty() {
        return false;
    }
    let bytes = key.as_bytes();
    // 首尾不能是连字符
    if bytes[0] == b'-' || bytes[bytes.len() - 1] == b'-' {
        return false;
    }
    // 不允许连续连字符，其余位置只允许 [a-z0-9-]
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
///
/// 规则对齐 cc-switch 的"自动派生 + 可编辑"：非 `[a-z0-9]` 一律折成连字符、
/// 折叠连续连字符、去首尾连字符；结果为空则回落到 `"provider"`。
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

/// 配置文件候选路径（顺序即优先级，与 `agent_config::opencode_paths` 一致）。
///
/// 优先官方位置；已存在 `%APPDATA%` 版本时优先它——否则会出现
/// "opencode 读 A 文件、BrewPing 写 B 文件"的分裂。
pub fn opencode_config_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Some(home) = dirs::home_dir() {
        paths.push(home.join(".config").join("opencode").join("opencode.json"));
    }
    if let Ok(app_data) = std::env::var("APPDATA") {
        paths.push(PathBuf::from(app_data).join("opencode").join("opencode.json"));
    }
    paths
}

/// 实际用于读写的路径：已存在的第一个；都不存在则用第一个（新建落这里）。
pub fn resolve_config_path() -> PathBuf {
    let paths = opencode_config_paths();
    paths
        .iter()
        .find(|p| p.is_file())
        .cloned()
        .or_else(|| paths.into_iter().next())
        .unwrap_or_else(|| PathBuf::from("opencode.json"))
}

// ─── 读写核心 ────────────────────────────────────────────────────────────────

/// 进程内写锁（避免两个窗口同时写导致丢更新；cc-switch 同款做法）。
fn config_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

/// 读整份配置。文件缺失 → 返回 `$schema` 骨架；解析失败 → 骨架。
///
/// 注意：**根不是对象时要报错**而不是静默重置——静默重置会无声清空
/// 用户整份配置（cc-switch 刻意只 warn 不重置，我们也选择拒绝）。
fn read_config_at(path: &Path) -> Result<Value, String> {
    let skeleton = json!({ "$schema": OPENCODE_SCHEMA });
    if !path.is_file() {
        return Ok(skeleton);
    }
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("read {} failed: {e}", path.display()))?;
    if text.trim().is_empty() {
        return Ok(skeleton);
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

/// 把 provider 段归一化成对象（非对象 → 重置为空对象）。
///
/// 只动 `provider` 这一个键，根上的其他键（`$schema` / `model` / `theme`…）
/// **一律原样保留** —— 这是"深合并"的关键：绝不 `Value::Object(Map::new())`
/// 重建根节点，否则用户的配置会被我们清空。
fn normalize_provider_section(root: &mut Value) -> &mut Map<String, Value> {
    let obj = root
        .as_object_mut()
        .expect("read_config_at 已保证根是对象");
    if !obj.get("provider").is_some_and(Value::is_object) {
        obj.insert("provider".into(), json!({}));
    }
    obj.get_mut("provider")
        .and_then(Value::as_object_mut)
        .expect("上一步已保证 provider 是对象")
}

/// 把前端 DTO 转成 opencode 磁盘格式的 provider 段落。
fn entry_to_value(entry: &OpenCodeProviderEntry) -> Value {
    let mut provider = Map::new();
    provider.insert("name".into(), json!(entry.name));

    let npm = if entry.npm.trim().is_empty() { DEFAULT_NPM } else { entry.npm.trim() };
    provider.insert("npm".into(), json!(npm));

    // options：只写非空字段，避免留下空串（opencode 对空 baseURL 会报错）
    let mut options = Map::new();
    if !entry.base_url.trim().is_empty() {
        options.insert("baseURL".into(), json!(entry.base_url.trim()));
    }
    if !entry.api_key.trim().is_empty() {
        options.insert("apiKey".into(), json!(entry.api_key.trim()));
    }
    if !entry.headers.is_empty() {
        options.insert("headers".into(), Value::Object(entry.headers.clone()));
    }
    if !options.is_empty() {
        provider.insert("options".into(), Value::Object(options));
    }

    let mut models = Map::new();
    for model in &entry.models {
        let id = model.id.trim();
        if id.is_empty() {
            continue;
        }
        let mut m = Map::new();
        m.insert("name".into(), json!(if model.name.trim().is_empty() { id } else { model.name.trim() }));
        models.insert(id.to_string(), Value::Object(m));
    }
    if !models.is_empty() {
        provider.insert("models".into(), Value::Object(models));
    }

    Value::Object(provider)
}

/// 把磁盘上的 provider 段落还原成 DTO。
fn value_to_entry(id: &str, value: &Value) -> OpenCodeProviderEntry {
    let name = value
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or(id)
        .to_string();
    let npm = value
        .get("npm")
        .and_then(Value::as_str)
        .unwrap_or(DEFAULT_NPM)
        .to_string();
    let options = value.get("options");
    let base_url = options
        .and_then(|o| o.get("baseURL"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let api_key = options
        .and_then(|o| o.get("apiKey"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let headers = options
        .and_then(|o| o.get("headers"))
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();

    let mut models: Vec<OpenCodeModelEntry> = Vec::new();
    if let Some(models_obj) = value.get("models").and_then(Value::as_object) {
        for (model_id, model_value) in models_obj {
            let model_name = model_value
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or(model_id)
                .to_string();
            models.push(OpenCodeModelEntry {
                id: model_id.clone(),
                name: model_name,
            });
        }
    }
    models.sort_by(|a, b| a.id.cmp(&b.id));

    OpenCodeProviderEntry {
        id: id.to_string(),
        name,
        npm,
        base_url,
        api_key,
        headers,
        models,
    }
}

// ─── 对外 API（command 层消费） ──────────────────────────────────────────────
//
// 每个能力都有两个入口：`*_providers()` 用本机真实路径（command 层用），
// `*_providers_at(path)` 显式指定路径（测试用 —— 不碰用户真实配置）。

/// 列出本机 opencode 已配置的全部 provider。
///
/// 解析失败（非法 JSON / 根非对象）时返回空清单 + `exists=true`，
/// 让界面提示"配置有问题"而不是整个功能挂掉。
pub fn list_providers() -> OpenCodeProvidersInfo {
    list_providers_at(&resolve_config_path())
}

/// `list_providers` 的显式路径版本。
pub fn list_providers_at(path: &Path) -> OpenCodeProvidersInfo {
    let exists = path.is_file();
    let npm_packages = NPM_PACKAGES
        .iter()
        .map(|(value, label)| NpmPackageOption {
            value: value.to_string(),
            label: label.to_string(),
        })
        .collect();

    let providers = match read_config_at(path) {
        Ok(root) => {
            let mut out: Vec<OpenCodeProviderEntry> = root
                .get("provider")
                .and_then(Value::as_object)
                .map(|obj| {
                    obj.iter()
                        .map(|(id, value)| value_to_entry(id, value))
                        .collect()
                })
                .unwrap_or_default();
            out.sort_by(|a, b| a.id.cmp(&b.id));
            out
        }
        Err(_) => Vec::new(),
    };

    OpenCodeProvidersInfo {
        config_file: path.display().to_string(),
        exists,
        providers,
        npm_packages,
    }
}

/// 写入 / 更新一个 provider（幂等：同 id 重复保存 = 覆盖）。
///
/// 这是整个功能的核心 —— 用户点「保存」后走这一条。
pub fn save_provider(entry: &OpenCodeProviderEntry) -> Result<OpenCodeProvidersInfo, String> {
    save_provider_at(&resolve_config_path(), entry)
}

/// `save_provider` 的显式路径版本（测试用，不碰用户真实配置）。
pub fn save_provider_at(
    path: &Path,
    entry: &OpenCodeProviderEntry,
) -> Result<OpenCodeProvidersInfo, String> {
    let id = entry.id.trim().to_string();
    if !is_valid_provider_key(&id) {
        return Err(format!(
            "invalid provider key '{id}': use lowercase letters, digits and single dashes (e.g. my-deepseek)"
        ));
    }
    if entry.name.trim().is_empty() {
        return Err("provider name must not be empty".into());
    }
    if entry.base_url.trim().is_empty() {
        return Err("baseURL must not be empty".into());
    }
    let base = entry.base_url.trim();
    if !(base.starts_with("http://") || base.starts_with("https://")) {
        return Err("baseURL must start with http:// or https://".into());
    }
    if entry.models.iter().all(|m| m.id.trim().is_empty()) {
        return Err("at least one model is required".into());
    }

    let _guard = config_lock().lock().map_err(|_| "config lock poisoned".to_string())?;

    // 读全文 → 只动 provider.<id> → 写回（其余键原样保留）
    let mut root = read_config_at(path)?;
    {
        let providers = normalize_provider_section(&mut root);
        let mut normalized = entry.clone();
        normalized.id = id.clone();
        normalized.base_url = base.trim_end_matches('/').to_string();
        providers.insert(id.clone(), entry_to_value(&normalized));
    }
    write_config_at(path, &root)?;

    // 复用 list：保证返回结构与 get 完全一致
    let mut info = list_providers_at(path);
    info.exists = true;
    Ok(info)
}

/// 删除一个 provider（按 id；不存在则视为成功 = 幂等）。
pub fn delete_provider(id: &str) -> Result<OpenCodeProvidersInfo, String> {
    delete_provider_at(&resolve_config_path(), id)
}

/// `delete_provider` 的显式路径版本（测试用）。
pub fn delete_provider_at(path: &Path, id: &str) -> Result<OpenCodeProvidersInfo, String> {
    let id = id.trim();
    if id.is_empty() {
        return Err("provider id must not be empty".into());
    }
    let _guard = config_lock().lock().map_err(|_| "config lock poisoned".to_string())?;
    if !path.is_file() {
        return Ok(list_providers_at(path));
    }
    let mut root = read_config_at(path)?;
    let removed = root
        .get_mut("provider")
        .and_then(Value::as_object_mut)
        .map(|providers| providers.remove(id).is_some())
        .unwrap_or(false);
    if removed {
        write_config_at(path, &root)?;
    }
    Ok(list_providers_at(path))
}

/// 读一份指定路径的配置（测试与 command 层可能的"自定义路径"场景）。
pub fn read_config(path: &Path) -> Result<Value, String> {
    read_config_at(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "brewping-opencode-{}-{}",
            tag,
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn sample_entry(id: &str, name: &str) -> OpenCodeProviderEntry {
        OpenCodeProviderEntry {
            id: id.to_string(),
            name: name.to_string(),
            npm: "@ai-sdk/openai-compatible".to_string(),
            base_url: "https://api.deepseek.com/v1".to_string(),
            api_key: "sk-test".to_string(),
            headers: Map::new(),
            models: vec![
                OpenCodeModelEntry { id: "deepseek-chat".into(), name: "DeepSeek Chat".into() },
                OpenCodeModelEntry { id: "deepseek-reasoner".into(), name: String::new() },
            ],
        }
    }

    // TC-OC-16  🔴 真实配置形态回归：用户在 ~/.config/opencode/opencode.json 里
    // 通常还有 `mcp`（本地 MCP 服务器）等顶层块 —— 添加 / 删除厂商时
    // 这些块必须**逐字节语义保留**（我们这个功能最容易踩的坑）。
    #[test]
    fn real_world_config_with_mcp_block_is_preserved() {
        let dir = temp_dir("mcp");
        let path = dir.join("opencode.json");
        // 与用户实际文件同构：$schema + mcp + 空 provider
        std::fs::write(
            &path,
            r#"{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "pencil": {
      "command": ["C:\\Users\\x\\.pencil\\mcp\\mcp-server.exe", "--app", "vscode"],
      "enabled": true,
      "type": "local"
    }
  },
  "provider": {}
}"#,
        )
        .unwrap();

        // 添加一个厂商
        let mut ds = sample_entry("deepseek", "DeepSeek");
        ds.base_url = "https://api.deepseek.com".into();
        ds.models = vec![OpenCodeModelEntry { id: "deepseek-chat".into(), name: "DeepSeek Chat".into() }];
        save_provider_at(&path, &ds).unwrap();

        let after = read_config(&path).unwrap();
        // mcp 块完整保留（含嵌套 command 数组与 enabled/type）
        assert_eq!(
            after.pointer("/mcp/pencil/type").and_then(Value::as_str),
            Some("local"),
            "mcp 块必须原样保留"
        );
        assert_eq!(
            after.pointer("/mcp/pencil/enabled").and_then(Value::as_bool),
            Some(true)
        );
        assert_eq!(
            after.pointer("/mcp/pencil/command").and_then(Value::as_array).map(|a| a.len()),
            Some(3),
            "mcp command 数组必须原样保留"
        );
        assert!(after.pointer("/provider/deepseek").is_some());

        // 删除该厂商 → mcp 仍在，provider 回到空对象
        delete_provider_at(&path, "deepseek").unwrap();
        let final_state = read_config(&path).unwrap();
        assert!(final_state.pointer("/mcp/pencil").is_some(), "删除厂商后 mcp 必须仍在");
        assert_eq!(
            final_state.get("provider").and_then(Value::as_object).map(|o| o.len()),
            Some(0),
            "provider 回到空对象而不是被删掉"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    // TC-OC-01  provider key 校验：合法 / 非法全覆盖
    #[test]
    fn provider_key_validation() {
        for ok in ["a", "deepseek", "my-deepseek", "zhipu-2024", "a1-b2-c3"] {
            assert!(is_valid_provider_key(ok), "{ok} 应当合法");
        }
        for bad in [
            "", "-a", "a-", "a--b", "My-DeepSeek", "my_deepseek", "my deepseek", "深度求索",
            "my.deepseek", "A",
        ] {
            assert!(!is_valid_provider_key(bad), "{bad} 应当被拒绝");
        }
    }

    // TC-OC-02  slug 派生：中英文/空格/符号都能折成合法 key
    #[test]
    fn provider_key_slugify() {
        assert_eq!(slugify_provider_key("My DeepSeek"), "my-deepseek");
        assert_eq!(slugify_provider_key("  Zhipu  "), "zhipu");
        assert_eq!(slugify_provider_key("MiniMax!!"), "minimax");
        assert_eq!(slugify_provider_key("a__b"), "a-b");
        assert_eq!(slugify_provider_key("深度求索"), "provider", "全中文回落默认值");
        assert_eq!(slugify_provider_key(""), "provider");
        // 派生结果必须过校验（自洽性）
        for name in ["My DeepSeek", "  Zhipu  ", "MiniMax!!", "深度求索", ""] {
            assert!(is_valid_provider_key(&slugify_provider_key(name)), "{name} 派生结果非法");
        }
    }

    // TC-OC-03  写入保留既有顶层键（深合并，绝不重建根节点）
    #[test]
    fn save_preserves_other_root_keys() {
        let dir = temp_dir("preserve");
        let path = dir.join("opencode.json");
        std::fs::write(
            &path,
            r#"{
  "$schema": "https://opencode.ai/config.json",
  "theme": "latte",
  "autoupdate": false,
  "provider": { "existing": { "name": "Existing", "npm": "@ai-sdk/openai" } }
}"#,
        )
        .unwrap();

        let info = save_provider_at(&path, &sample_entry("my-deepseek", "My DeepSeek")).unwrap();
        assert_eq!(info.providers.len(), 2, "返回的清单应含既有 + 新增");

        let after = read_config(&path).unwrap();
        assert_eq!(after.get("theme").and_then(Value::as_str), Some("latte"), "顶层 theme 必须保留");
        assert_eq!(after.get("autoupdate").and_then(Value::as_bool), Some(false));
        assert!(after.get("$schema").is_some(), "$schema 必须保留");
        assert!(after.pointer("/provider/existing").is_some(), "既有 provider 必须保留");
        assert!(after.pointer("/provider/my-deepseek").is_some(), "新 provider 必须写入");
        // 尾斜杠写入时被剥掉
        assert_eq!(
            after.pointer("/provider/my-deepseek/options/baseURL").and_then(Value::as_str),
            Some("https://api.deepseek.com/v1"),
            "尾斜杠必须剥离"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    // TC-OC-04  幂等：同 id 重复写入不产生副本、不改变既有兄弟项
    #[test]
    fn save_is_idempotent() {
        let dir = temp_dir("idempotent");
        let path = dir.join("opencode.json");
        std::fs::write(&path, r#"{ "provider": {} }"#).unwrap();

        let entry = sample_entry("my-deepseek", "My DeepSeek");
        for _ in 0..3 {
            save_provider_at(&path, &entry).unwrap();
        }

        let after = read_config(&path).unwrap();
        let obj = after.get("provider").and_then(Value::as_object).unwrap();
        assert_eq!(obj.len(), 1, "重复写入不得产生副本");
        let list = after
            .pointer("/provider/my-deepseek/models")
            .and_then(Value::as_object)
            .unwrap();
        assert_eq!(list.len(), 2, "模型不得累积");
        let _ = std::fs::remove_dir_all(&dir);
    }

    // TC-OC-05  删除：按 id 精确移除，兄弟项保留
    #[test]
    fn delete_provider_by_id() {
        let dir = temp_dir("delete");
        let path = dir.join("opencode.json");
        save_provider_at(&path, &sample_entry("alpha", "Alpha")).unwrap();
        save_provider_at(&path, &sample_entry("beta", "Beta")).unwrap();

        let info = delete_provider_at(&path, "alpha").unwrap();
        assert_eq!(info.providers.len(), 1, "删除后清单只剩 1 项");
        assert_eq!(info.providers[0].id, "beta");

        let after = read_config(&path).unwrap();
        assert!(after.pointer("/provider/alpha").is_none(), "alpha 应被删除");
        assert!(after.pointer("/provider/beta").is_some(), "beta 必须保留");

        // 幂等：删不存在的 id 也不报错
        assert!(delete_provider_at(&path, "nope").is_ok());
        let _ = std::fs::remove_dir_all(&dir);
    }

    // TC-OC-06  provider 段非对象 → 归一化为空对象（不 panic、不丢其他键）
    #[test]
    fn non_object_provider_section_is_normalized() {
        let dir = temp_dir("normalize");
        let path = dir.join("opencode.json");
        std::fs::write(&path, r#"{ "theme": "x", "provider": "oops" }"#).unwrap();

        // 走真实保存路径：非对象 provider 必须被归一化而不是让写入炸掉
        save_provider_at(&path, &sample_entry("p1", "P1")).unwrap();

        let after = read_config(&path).unwrap();
        assert_eq!(after.get("theme").and_then(Value::as_str), Some("x"), "其他键必须保留");
        assert!(after.pointer("/provider/p1").is_some(), "新 provider 必须写入");
        assert!(after.pointer("/provider/p1").unwrap().is_object(), "provider 段必须已是对象");
        let _ = std::fs::remove_dir_all(&dir);
    }

    // TC-OC-07  根非对象 → 报错（不静默清空用户配置）
    #[test]
    fn non_object_root_is_rejected() {
        let dir = temp_dir("reject");
        let path = dir.join("opencode.json");
        std::fs::write(&path, r#"[1, 2, 3]"#).unwrap();
        let err = read_config(&path).unwrap_err();
        assert!(err.contains("root must be a JSON object"), "错误信息应说明根类型: {err}");
        // 文件未被改动
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "[1, 2, 3]");
        // 保存路径同样拒绝（不覆盖用户文件）
        assert!(save_provider_at(&path, &sample_entry("p1", "P1")).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "[1, 2, 3]");
        let _ = std::fs::remove_dir_all(&dir);
    }

    // TC-OC-08  文件缺失 → 返回 $schema 骨架（首次添加厂商的合法场景）
    #[test]
    fn missing_file_yields_schema_skeleton() {
        let dir = temp_dir("missing");
        let path = dir.join("opencode.json");
        let root = read_config(&path).unwrap();
        assert_eq!(root.get("$schema").and_then(Value::as_str), Some(OPENCODE_SCHEMA));
        assert!(root.get("provider").is_none(), "骨架不带 provider（读侧自行回落空清单）");

        // 首次保存：自动建目录 + 建文件 + 写入
        let nested = dir.join("opencode").join("opencode.json");
        let info = save_provider_at(&nested, &sample_entry("first", "First")).unwrap();
        assert!(info.exists);
        assert_eq!(info.providers.len(), 1);
        assert!(nested.is_file(), "父目录应被自动创建");
        let _ = std::fs::remove_dir_all(&dir);
    }

    // TC-OC-09  往返：entry → 磁盘 → entry 保真（含默认 npm / 空 name 回落 id）
    #[test]
    fn entry_roundtrip_is_lossless() {
        let entry = sample_entry("my-deepseek", "My DeepSeek");
        let value = entry_to_value(&entry);
        let back = value_to_entry("my-deepseek", &value);
        assert_eq!(back.name, "My DeepSeek");
        assert_eq!(back.base_url, "https://api.deepseek.com/v1");
        assert_eq!(back.api_key, "sk-test");
        assert_eq!(back.npm, "@ai-sdk/openai-compatible");
        assert_eq!(back.models.len(), 2);
        // 空 name 的模型回落 id
        let reasoner = back.models.iter().find(|m| m.id == "deepseek-reasoner").unwrap();
        assert_eq!(reasoner.name, "deepseek-reasoner", "空 name 回落模型 id");
    }

    // TC-OC-10  空字段不落盘（不留空串 options），空 npm 回落默认值
    #[test]
    fn empty_fields_are_omitted() {
        let entry = OpenCodeProviderEntry {
            id: "bare".into(),
            name: "Bare".into(),
            npm: String::new(),
            base_url: "https://x.test".into(),
            api_key: String::new(),
            headers: Map::new(),
            models: vec![OpenCodeModelEntry { id: "m1".into(), name: String::new() }],
        };
        let value = entry_to_value(&entry);
        assert_eq!(value.get("npm").and_then(Value::as_str), Some(DEFAULT_NPM), "空 npm 回落默认");
        let options = value.get("options").and_then(Value::as_object).unwrap();
        assert!(!options.contains_key("apiKey"), "空 apiKey 不应落盘");
        assert!(!options.contains_key("headers"), "空 headers 不应落盘");
        assert_eq!(options.get("baseURL").and_then(Value::as_str), Some("https://x.test"));
    }

    // TC-OC-11  list 序列化契约：camelCase + baseURL / apiKey 原样
    #[test]
    fn info_serializes_camel_case() {
        let info = OpenCodeProvidersInfo {
            config_file: "/tmp/opencode.json".into(),
            exists: true,
            providers: vec![sample_entry("my-deepseek", "My DeepSeek")],
            npm_packages: vec![NpmPackageOption {
                value: DEFAULT_NPM.into(),
                label: "OpenAI 兼容".into(),
            }],
        };
        let v = serde_json::to_value(&info).unwrap();
        assert!(v.get("configFile").is_some(), "必须 camelCase configFile");
        assert!(v.get("npmPackages").is_some());
        assert!(v["providers"][0].get("baseURL").is_some(), "磁盘格式字段名 baseURL 必须原样");
        assert!(v["providers"][0].get("apiKey").is_some());
        assert!(v["providers"][0].get("id").is_some());
    }

    // TC-OC-12  默认 npm 必须在可选清单里（下拉不会给出清单外的默认值）
    #[test]
    fn default_npm_is_listed() {
        assert!(
            NPM_PACKAGES.iter().any(|(v, _)| *v == DEFAULT_NPM),
            "DEFAULT_NPM 必须在 NPM_PACKAGES 中"
        );
        for (value, label) in NPM_PACKAGES {
            assert!(value.starts_with('@'), "{value} 应是 scoped npm 包名");
            assert!(!label.is_empty(), "{value} 必须有中文标签");
        }
    }

    // TC-OC-13  输入校验：非法 key / 空名称 / 空地址 / 非 http / 无模型 全部拒绝
    #[test]
    fn save_rejects_invalid_input() {
        let dir = temp_dir("invalid");
        let path = dir.join("opencode.json");

        let mut bad_key = sample_entry("Bad_Key", "Bad");
        bad_key.id = "Bad_Key".into();
        assert!(save_provider_at(&path, &bad_key).is_err(), "非法 key 必须拒绝");

        let mut no_name = sample_entry("ok", "Ok");
        no_name.name = "  ".into();
        assert!(save_provider_at(&path, &no_name).is_err(), "空名称必须拒绝");

        let mut no_url = sample_entry("ok", "Ok");
        no_url.base_url = "".into();
        assert!(save_provider_at(&path, &no_url).is_err(), "空地址必须拒绝");

        let mut bad_url = sample_entry("ok", "Ok");
        bad_url.base_url = "ftp://x.test".into();
        assert!(save_provider_at(&path, &bad_url).is_err(), "非 http(s) 地址必须拒绝");

        let mut no_models = sample_entry("ok", "Ok");
        no_models.models = vec![OpenCodeModelEntry { id: "  ".into(), name: "".into() }];
        assert!(save_provider_at(&path, &no_models).is_err(), "无有效模型必须拒绝");

        // 全部被拒 → 文件不该被创建（校验在写盘之前）
        assert!(!path.exists(), "校验失败不得创建文件");
        let _ = std::fs::remove_dir_all(&dir);
    }

    // TC-OC-14  用户完整流程（对标 cc-switch 的「添加厂商」）：
    //   1. 初始无文件 → 列表为空但给出骨架路径；
    //   2. 添加 DeepSeek → opencode.json 出现 provider.my-deepseek；
    //   3. 再添加一家 → 两家共存；
    //   4. 编辑其中一家（换模型） → 覆盖而非追加；
    //   5. 删除一家 → 另一家还在。
    #[test]
    fn full_user_flow_add_edit_delete() {
        let dir = temp_dir("flow");
        let path = dir.join("opencode.json");

        // 1. 初始：文件不存在，列表空，路径已给出
        let initial = list_providers_at(&path);
        assert!(!initial.exists);
        assert!(initial.providers.is_empty());
        assert!(initial.config_file.ends_with("opencode.json"));
        assert!(!initial.npm_packages.is_empty(), "npm 选项清单必须下发");

        // 2. 添加 DeepSeek
        let mut deepseek = sample_entry("my-deepseek", "DeepSeek");
        deepseek.base_url = "https://api.deepseek.com".into();
        let after_add = save_provider_at(&path, &deepseek).unwrap();
        assert!(after_add.exists);
        assert_eq!(after_add.providers.len(), 1);
        assert_eq!(after_add.providers[0].id, "my-deepseek");
        assert_eq!(after_add.providers[0].name, "DeepSeek");
        assert_eq!(after_add.providers[0].models.len(), 2);

        // 3. 再添加一家 → 共存
        let mut kimi = sample_entry("my-kimi", "Kimi");
        kimi.base_url = "https://api.moonshot.cn/anthropic".into();
        let after_two = save_provider_at(&path, &kimi).unwrap();
        assert_eq!(after_two.providers.len(), 2);
        assert_eq!(
            after_two.providers.iter().map(|p| p.id.as_str()).collect::<Vec<_>>(),
            vec!["my-deepseek", "my-kimi"],
            "按 id 排序"
        );

        // 4. 编辑 DeepSeek：换模型 + 改名 → 覆盖
        let mut edited = deepseek.clone();
        edited.name = "DeepSeek (edited)".into();
        edited.models = vec![OpenCodeModelEntry { id: "deepseek-reasoner".into(), name: "R1".into() }];
        let after_edit = save_provider_at(&path, &edited).unwrap();
        assert_eq!(after_edit.providers.len(), 2, "编辑不得新增条目");
        let ds = after_edit.providers.iter().find(|p| p.id == "my-deepseek").unwrap();
        assert_eq!(ds.name, "DeepSeek (edited)");
        assert_eq!(ds.models.len(), 1);
        assert_eq!(ds.models[0].id, "deepseek-reasoner");

        // 5. 删除 Kimi → DeepSeek 还在
        let after_del = delete_provider_at(&path, "my-kimi").unwrap();
        assert_eq!(after_del.providers.len(), 1);
        assert_eq!(after_del.providers[0].id, "my-deepseek");

        let _ = std::fs::remove_dir_all(&dir);
    }

    // TC-OC-15  https / http 均接受，尾斜杠剥离，apiKey 不脱敏读出（用户自己的文件）
    #[test]
    fn url_trimming_and_key_not_masked() {
        let dir = temp_dir("url");
        let path = dir.join("opencode.json");

        let mut e = sample_entry("plain", "Plain");
        e.base_url = "http://127.0.0.1:8080/v1///".into();
        e.api_key = "sk-raw-key".into();
        let info = save_provider_at(&path, &e).unwrap();
        assert_eq!(
            info.providers[0].base_url, "http://127.0.0.1:8080/v1",
            "http 允许 + 尾斜杠全部剥离"
        );
        assert_eq!(info.providers[0].api_key, "sk-raw-key", "读回不得脱敏（供表单回填）");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
