//! CLI 配置接管——内置 cc-switch 的「客户端对接层」（takeover）。
//!
//! 一键把本机 AI CLI 的配置指向 BrewPing 转发代理：写一次配置，之后在
//! BrewPing 里切换厂商 / 故障转移都即时生效，CLI 无需再动。行为对齐
//! cc-switch `services/provider/live.rs` 的写入/还原策略：
//! - **深合并写入**：只写属于自己的键，用户配置里的其他内容原样保留；
//! - **按值还原**：关闭接管时只移除「值正是我们写的」的键（用户后来自己改过
//!   的键不动），避免误删；
//! - **Codex 用 toml_edit 编辑** `config.toml`，保留注释与既有格式。
//!
//! 覆盖的 CLI 与写入点（对齐 cc-switch 的 Claude/Codex 支持面）：
//! - Claude Code：`~/.claude/settings.json` → `env.ANTHROPIC_BASE_URL` +
//!   `env.ANTHROPIC_AUTH_TOKEN`（占位 key，代理会替换成真实凭据）；
//! - Codex：`~/.codex/config.toml` → `model_provider = "brewping"` +
//!   `[model_providers.brewping]`（base_url 指代理、wire_api = "chat"）；
//!   `~/.codex/auth.json` → `OPENAI_API_KEY` 占位。
//! - pi：`~/.pi/agent/models.json` → `providers.brewping`（baseUrl 带别名
//!   `/pi`、api = "anthropic-messages"、占位 key、至少一条占位模型——契约
//!   见本机 pi 包 docs/models.md：非内置 provider 自定义模型必须
//!   baseUrl+apiKey+api 三件套齐全）；`~/.pi/agent/settings.json` →
//!   `defaultProvider` + `defaultModel` **成对**写入（pi 的 model-resolver
//!   要求两者都非空才采用默认；pi 无环境变量入口，代理接管必须写默认，
//!   这与 cc-switch「不碰默认选择」的契约是有意差异）。
//!
//! 模块不依赖 tauri 类型（services 层同款约束）。

use serde::Serialize;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

/// 接管时写入 CLI 的占位 API key（代理鉴权替换会丢弃它、注入真实 key）。
pub const PLACEHOLDER_KEY: &str = "brewping-proxy";
/// Codex 里 brewping provider 的注册名。
pub const CODEX_PROVIDER_NAME: &str = "brewping";
/// pi models.json 里 brewping provider 的注册名（同 CodeX 命名，语义独立）。
pub const PI_PROVIDER_NAME: &str = "brewping";
/// pi 的占位模型 id（models.json 必须至少一条模型才能在 /model 里被选中）。
pub const PI_DEFAULT_MODEL: &str = "brewping-default";

/// CLI 种类（与前端约定的字符串值）。
///
/// 扩展新 CLI（qoder 等）三步：
/// ① 这里加枚举值；② `binary_name` / `display_name` / `config_file` 补分支；
/// ③ 若支持配置接管，在 `enable` / `disable` / `item_active` 补实现并把
/// `is_takeover_supported` 改为 true —— 前端列表与按钮**自动**跟上，无需改 UI。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CliKind {
    ClaudeCode,
    Codex,
    OpenCode,
    Pi,
}

/// 全部可检测/展示的 CLI（列表顺序即前端展示顺序）。
pub const ALL_KINDS: &[CliKind] = &[
    CliKind::ClaudeCode,
    CliKind::Codex,
    CliKind::OpenCode,
    CliKind::Pi,
];

impl CliKind {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            // "claude-code"（连字符，agent 命名空间权威形态）与 "claude_code"
            // （历史前端值）都认——过渡期双兼容，见 M3 统一约定。
            "claude-code" | "claude_code" | "claudeCode" => Some(Self::ClaudeCode),
            "codex" => Some(Self::Codex),
            "opencode" => Some(Self::OpenCode),
            "pi" => Some(Self::Pi),
            _ => None,
        }
    }

    pub fn id(self) -> &'static str {
        match self {
            Self::ClaudeCode => "claude_code",
            Self::Codex => "codex",
            Self::OpenCode => "opencode",
            Self::Pi => "pi",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::ClaudeCode => "Claude Code",
            Self::Codex => "Codex",
            Self::OpenCode => "OpenCode",
            Self::Pi => "pi",
        }
    }

    /// 可执行文件名（`installed` 用 which 检测，对齐设置页「已安装 x.y.z」语义）。
    fn binary_name(self) -> &'static str {
        match self {
            Self::ClaudeCode => "claude",
            Self::Codex => "codex",
            Self::OpenCode => "opencode",
            Self::Pi => "pi",
        }
    }

    /// 是否支持「配置接管」（能把上游指向本地代理）。
    /// 其余 CLI 仅做检测与展示；接入实现补齐后改为 true 即可。
    pub fn is_takeover_supported(self) -> bool {
        matches!(self, Self::ClaudeCode | Self::Codex | Self::Pi)
    }

    /// 主配置文件路径（展示用；不存在也显示，供用户了解 CLI 配置位置）。
    fn config_file(self, home: &Path) -> PathBuf {
        match self {
            Self::ClaudeCode => home.join(".claude").join("settings.json"),
            Self::Codex => home.join(".codex").join("config.toml"),
            Self::OpenCode => home.join(".config").join("opencode").join("opencode.json"),
            Self::Pi => home.join(".pi").join("agent").join("models.json"),
        }
    }
}

/// 单个 CLI 的检测/接管状态（前端 DTO；列表项，动态数量）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CliTakeoverItem {
    /// CLI 标识（前端 key 与 set_cli_takeover 的 cli 参数值）。
    pub id: String,
    /// 展示名。
    pub name: String,
    /// 本机是否安装（which 检测可执行文件，对齐设置页语义）。
    pub installed: bool,
    /// 是否支持配置接管（不支持时前端按钮置灰并提示）。
    pub supported: bool,
    /// 代理配置是否已写入（按值精确匹配）。
    pub active: bool,
    /// 主配置文件路径（展示用）。
    pub config_file: String,
    /// 配置文件是否存在（false = CLI 未产生过配置）。
    pub exists: bool,
}

/// 全部 CLI 的接管状态。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CliTakeoverInfo {
    /// 动态列表（顺序 = ALL_KINDS 顺序）。
    pub items: Vec<CliTakeoverItem>,
    pub proxy_port: u16,
}

/// 接管管理器（默认 home 目录）。
pub struct CliTakeover {
    home: PathBuf,
}

impl CliTakeover {
    pub fn new() -> Self {
        Self {
            home: dirs::home_dir().unwrap_or_else(|| PathBuf::from(".")),
        }
    }

    /// 注入 home 目录（测试用）。
    pub fn with_home(home: PathBuf) -> Self {
        Self { home }
    }

    /// 接入地址带 Agent 别名后缀（/claude /codex）：代理据此识别请求来源，
    /// 实现「Agent→厂商」per-Agent 路由（strip_proxy_alias 侧已支持）。
    /// 旧版裸地址仍能工作（走通用路由，软降级），但需重新接管才能获得归属路由。
    fn claude_base_url(&self, port: u16) -> String {
        format!("http://127.0.0.1:{port}/claude")
    }

    fn codex_base_url(&self, port: u16) -> String {
        format!("http://127.0.0.1:{port}/codex")
    }

    fn pi_base_url(&self, port: u16) -> String {
        // pi（anthropic-messages）请求 = {baseUrl}/v1/messages（@anthropic-ai/sdk 拼接），
        // 剥掉 /pi 别名后正好落在本代理的 Anthropic 透传路径上。
        format!("http://127.0.0.1:{port}/pi")
    }

    /// 查询全部 CLI 的接管状态（动态列表，顺序 = ALL_KINDS）。
    pub fn status(&self, port: u16) -> CliTakeoverInfo {
        CliTakeoverInfo {
            items: ALL_KINDS.iter().map(|k| self.item_status(*k, port)).collect(),
            proxy_port: port,
        }
    }

    fn item_status(&self, kind: CliKind, port: u16) -> CliTakeoverItem {
        let file = kind.config_file(&self.home);
        let exists = file.exists();
        let installed = which::which(kind.binary_name()).is_ok();
        let supported = kind.is_takeover_supported();
        // 不支持接管的 CLI 恒为非 active（避免误报）
        let active = supported
            && match kind {
                CliKind::ClaudeCode => self
                    .read_json(&file)
                    .is_some_and(|v| v.pointer("/env/ANTHROPIC_BASE_URL").and_then(Value::as_str)
                        == Some(self.claude_base_url(port).as_str())),
                CliKind::Codex => {
                    let Ok(text) = std::fs::read_to_string(&file) else {
                        return CliTakeoverItem {
                            id: kind.id().into(),
                            name: kind.display_name().into(),
                            installed,
                            supported,
                            active: false,
                            config_file: file.display().to_string(),
                            exists,
                        };
                    };
                    let Ok(doc) = text.parse::<toml_edit::DocumentMut>() else {
                        return CliTakeoverItem {
                            id: kind.id().into(),
                            name: kind.display_name().into(),
                            installed,
                            supported,
                            active: false,
                            config_file: file.display().to_string(),
                            exists,
                        };
                    };
                    doc.get("model_provider").and_then(|i| i.as_str()) == Some(CODEX_PROVIDER_NAME)
                        && doc
                            .get("model_providers")
                            .and_then(|i| i.as_table())
                            .and_then(|t| t.get(CODEX_PROVIDER_NAME))
                            .and_then(|i| i.as_table())
                            .and_then(|t| t.get("base_url"))
                            .and_then(|i| i.as_str())
                            == Some(self.codex_base_url(port).as_str())
                }
                // 尚未实现接管的 CLI：仅展示，恒 false
                CliKind::OpenCode => false,
                // pi：models.json 有 brewping provider 且 baseUrl 按值匹配（与 Codex 双条件同构）
                CliKind::Pi => self
                    .read_json(&file)
                    .and_then(|v| {
                        v.pointer("/providers")
                            .and_then(Value::as_object)?
                            .get(PI_PROVIDER_NAME)?
                            .pointer("/baseUrl")
                            .and_then(Value::as_str)
                            .map(|s| s == self.pi_base_url(port))
                            .or(Some(false))
                    })
                    .unwrap_or(false),
            };
        CliTakeoverItem {
            id: kind.id().into(),
            name: kind.display_name().into(),
            installed,
            supported,
            active,
            config_file: file.display().to_string(),
            exists,
        }
    }

    /// 开启接管：把代理地址写进 CLI 配置（幂等；重复写是 no-op）。
    pub fn enable(&self, kind: CliKind, port: u16) -> Result<(), String> {
        if !kind.is_takeover_supported() {
            return Err(format!("{} does not support takeover yet", kind.display_name()));
        }
        match kind {
            CliKind::ClaudeCode => {
                let file = kind.config_file(&self.home);
                let mut root = self.read_json(&file).unwrap_or_else(|| json!({}));
                let Value::Object(ref mut obj) = root else {
                    return Err("claude settings.json root is not an object".into());
                };
                let env = obj
                    .entry("env")
                    .or_insert_with(|| json!({}))
                    .as_object_mut()
                    .ok_or("claude settings env must be an object")?;
                env.insert("ANTHROPIC_BASE_URL".into(), json!(self.claude_base_url(port)));
                env.insert("ANTHROPIC_AUTH_TOKEN".into(), json!(PLACEHOLDER_KEY));
                self.write_json(&file, &root)
            }
            CliKind::Codex => {
                let file = kind.config_file(&self.home);
                if let Some(parent) = file.parent() {
                    std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
                }
                let text = std::fs::read_to_string(&file).unwrap_or_default();
                let mut doc = text
                    .parse::<toml_edit::DocumentMut>()
                    .map_err(|e| format!("codex config.toml parse failed: {e}"))?;
                doc["model_provider"] = toml_edit::value(CODEX_PROVIDER_NAME);
                // 确保存在 [model_providers] 表（保留既有兄弟条目）
                doc["model_providers"]
                    .or_insert(toml_edit::Item::Table(toml_edit::Table::new()));
                let providers = &mut doc["model_providers"];
                if !providers.is_table_like() {
                    return Err("codex config.toml [model_providers] must be a table".into());
                }
                let mut section = toml_edit::Table::new();
                section["name"] = toml_edit::value("BrewPing Proxy");
                section["base_url"] = toml_edit::value(self.codex_base_url(port));
                section["wire_api"] = toml_edit::value("chat");
                providers[CODEX_PROVIDER_NAME] = toml_edit::Item::Table(section);

                // auth.json：占位 OPENAI_API_KEY（保留其他字段）
                let auth_file = self.home.join(".codex").join("auth.json");
                let mut auth = self.read_json(&auth_file).unwrap_or_else(|| json!({}));
                if let Some(obj) = auth.as_object_mut() {
                    obj.insert("OPENAI_API_KEY".into(), json!(PLACEHOLDER_KEY));
                }
                self.write_json(&auth_file, &auth)?;
                self.write_text(&file, &doc.to_string())
            }
            CliKind::Pi => {
                // ① models.json：providers.brewping（三件套 + 占位模型），保留既有 providers
                let file = kind.config_file(&self.home);
                let mut root = self.read_json(&file).unwrap_or_else(|| json!({}));
                let Value::Object(ref mut obj) = root else {
                    return Err("pi models.json root is not an object".into());
                };
                let providers = obj
                    .entry("providers")
                    .or_insert_with(|| json!({}))
                    .as_object_mut()
                    .ok_or("pi models.json providers must be an object")?;
                providers.insert(
                    PI_PROVIDER_NAME.into(),
                    json!({
                        "baseUrl": self.pi_base_url(port),
                        "apiKey": PLACEHOLDER_KEY,
                        "api": "anthropic-messages",
                        "models": [
                            { "id": PI_DEFAULT_MODEL, "name": "BrewPing (proxied)" }
                        ],
                    }),
                );
                self.write_json(&file, &root)?;

                // ② settings.json：defaultProvider + defaultModel 成对写（缺一不生效）。
                //    pi 无环境变量入口，代理接管必须写默认——与 cc-switch「不碰默认」的有意差异。
                let settings_file = self.home.join(".pi").join("agent").join("settings.json");
                let mut settings = self.read_json(&settings_file).unwrap_or_else(|| json!({}));
                let Value::Object(ref mut sobj) = settings else {
                    return Err("pi settings.json root is not an object".into());
                };
                sobj.insert("defaultProvider".into(), json!(PI_PROVIDER_NAME));
                sobj.insert("defaultModel".into(), json!(PI_DEFAULT_MODEL));
                self.write_json(&settings_file, &settings)
            }
            // 上方 is_takeover_supported 已拦截，此分支不可达（保持穷尽匹配）
            CliKind::OpenCode => {
                Err(format!("{} does not support takeover yet", kind.display_name()))
            }
        }
    }

    /// 关闭接管：按值移除我们写的键；值已被用户改过则保留（不误删）。
    pub fn disable(&self, kind: CliKind, port: u16) -> Result<(), String> {
        if !kind.is_takeover_supported() {
            return Err(format!("{} does not support takeover yet", kind.display_name()));
        }
        match kind {
            CliKind::ClaudeCode => {
                let file = kind.config_file(&self.home);
                let Some(mut root) = self.read_json(&file) else {
                    return Ok(()); // 文件不存在 = 已还原
                };
                let base = self.claude_base_url(port);
                let mut changed = false;
                if let Some(env) = root.pointer_mut("/env").and_then(Value::as_object_mut) {
                    if env.get("ANTHROPIC_BASE_URL").and_then(Value::as_str) == Some(base.as_str()) {
                        env.remove("ANTHROPIC_BASE_URL");
                        changed = true;
                    }
                    if env.get("ANTHROPIC_AUTH_TOKEN").and_then(Value::as_str) == Some(PLACEHOLDER_KEY) {
                        env.remove("ANTHROPIC_AUTH_TOKEN");
                        changed = true;
                    }
                }
                if changed {
                    self.write_json(&file, &root)?;
                }
                Ok(())
            }
            CliKind::Codex => {
                let file = kind.config_file(&self.home);
                let Ok(text) = std::fs::read_to_string(&file) else {
                    return Ok(());
                };
                let Ok(mut doc) = text.parse::<toml_edit::DocumentMut>() else {
                    return Err("codex config.toml parse failed".into());
                };
                let base = self.codex_base_url(port);
                let mut changed = false;
                if doc.get("model_provider").and_then(|i| i.as_str()) == Some(CODEX_PROVIDER_NAME) {
                    doc.as_table_mut().remove("model_provider");
                    changed = true;
                }
                let ours = doc
                    .get("model_providers")
                    .and_then(|i| i.as_table())
                    .and_then(|t| t.get(CODEX_PROVIDER_NAME))
                    .and_then(|i| i.as_table())
                    .and_then(|t| t.get("base_url"))
                    .and_then(|i| i.as_str())
                    == Some(base.as_str());
                if ours {
                    if let Some(providers) = doc.get_mut("model_providers").and_then(|i| i.as_table_like_mut()) {
                        providers.remove(CODEX_PROVIDER_NAME);
                        changed = true;
                    }
                }
                if changed {
                    self.write_text(&file, &doc.to_string())?;
                }
                // auth.json：占位 key 移除
                let auth_file = self.home.join(".codex").join("auth.json");
                if let Some(mut auth) = self.read_json(&auth_file) {
                    let mut changed = false;
                    if let Some(obj) = auth.as_object_mut() {
                        if obj.get("OPENAI_API_KEY").and_then(Value::as_str) == Some(PLACEHOLDER_KEY) {
                            obj.remove("OPENAI_API_KEY");
                            changed = true;
                        }
                    }
                    if changed {
                        self.write_json(&auth_file, &auth)?;
                    }
                }
                Ok(())
            }
            CliKind::Pi => {
                // ① models.json：brewping provider 按值移除（baseUrl 是我们的才删）
                let file = kind.config_file(&self.home);
                let base = self.pi_base_url(port);
                if let Some(mut root) = self.read_json(&file) {
                    let mut changed = false;
                    if let Some(providers) =
                        root.pointer_mut("/providers").and_then(Value::as_object_mut)
                    {
                        let ours = providers
                            .get(PI_PROVIDER_NAME)
                            .and_then(|p| p.pointer("/baseUrl").and_then(Value::as_str))
                            == Some(base.as_str());
                        if ours {
                            providers.remove(PI_PROVIDER_NAME);
                            changed = true;
                        }
                    }
                    if changed {
                        self.write_json(&file, &root)?;
                    }
                }

                // ② settings.json：默认项按值移除（用户改过则保留）
                let settings_file = self.home.join(".pi").join("agent").join("settings.json");
                if let Some(mut settings) = self.read_json(&settings_file) {
                    let mut changed = false;
                    if let Some(sobj) = settings.as_object_mut() {
                        if sobj.get("defaultProvider").and_then(Value::as_str)
                            == Some(PI_PROVIDER_NAME)
                        {
                            sobj.remove("defaultProvider");
                            changed = true;
                        }
                        if sobj.get("defaultModel").and_then(Value::as_str)
                            == Some(PI_DEFAULT_MODEL)
                        {
                            sobj.remove("defaultModel");
                            changed = true;
                        }
                    }
                    if changed {
                        self.write_json(&settings_file, &settings)?;
                    }
                }
                Ok(())
            }
            // 上方 is_takeover_supported 已拦截，此分支不可达（保持穷尽匹配）
            CliKind::OpenCode => {
                Err(format!("{} does not support takeover yet", kind.display_name()))
            }
        }
    }

    fn read_json(&self, path: &Path) -> Option<Value> {
        let text = std::fs::read_to_string(path).ok()?;
        serde_json::from_str(&text).ok()
    }

    fn write_json(&self, path: &Path, value: &Value) -> Result<(), String> {
        let data = serde_json::to_string_pretty(value).map_err(|e| e.to_string())?;
        self.write_text(path, &data)
    }

    fn write_text(&self, path: &Path, text: &str) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        std::fs::write(path, text).map_err(|e| format!("write {}: {e}", path.display()))
    }
}

impl Default for CliTakeover {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_home(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "brewping-takeover-{}-{}",
            tag,
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// 按 id 取列表项（新动态结构下断言辅助）。
    fn item<'a>(info: &'a CliTakeoverInfo, id: &str) -> &'a CliTakeoverItem {
        info.items.iter().find(|i| i.id == id).unwrap_or_else(|| panic!("item {id} missing"))
    }

    // TC-CT-01  Claude Code：开启写入 env 两键 + 保留既有配置 + 幂等
    #[test]
    fn claude_code_enable_merges_and_preserves() {
        let home = temp_home("cc");
        let take = CliTakeover::with_home(home.clone());
        let file = home.join(".claude").join("settings.json");
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(
            &file,
            r#"{"permissions":{"allow":["Bash"]},"env":{"ANTHROPIC_API_KEY":"user-key"}}"#,
        )
        .unwrap();

        take.enable(CliKind::ClaudeCode, 15721).unwrap();
        let v: Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
        assert_eq!(v.pointer("/env/ANTHROPIC_BASE_URL").unwrap(), "http://127.0.0.1:15721/claude");
        assert_eq!(v.pointer("/env/ANTHROPIC_AUTH_TOKEN").unwrap(), PLACEHOLDER_KEY);
        // 既有内容保留
        assert_eq!(v.pointer("/env/ANTHROPIC_API_KEY").unwrap(), "user-key");
        assert_eq!(v.pointer("/permissions/allow/0").unwrap(), "Bash");

        // 幂等：再开一次不炸
        take.enable(CliKind::ClaudeCode, 15721).unwrap();
        // 状态 active（注意：本机若装了 claude，installed 可能是 true，不作断言）
        let info = take.status(15721);
        assert!(item(&info, "claude_code").active);
    }

    // TC-CT-02  Claude Code：关闭按值还原 + 用户改过的键不误删
    #[test]
    fn claude_code_disable_restores_by_value() {
        let home = temp_home("cc-off");
        let take = CliTakeover::with_home(home.clone());
        take.enable(CliKind::ClaudeCode, 15721).unwrap();
        take.disable(CliKind::ClaudeCode, 15721).unwrap();
        let file = home.join(".claude").join("settings.json");
        let v: Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
        assert!(v.pointer("/env/ANTHROPIC_BASE_URL").is_none(), "代理地址必须移除");
        assert!(v.pointer("/env/ANTHROPIC_AUTH_TOKEN").is_none(), "占位 key 必须移除");
        assert!(!item(&take.status(15721), "claude_code").active);

        // 用户改过值 → 不动
        take.enable(CliKind::ClaudeCode, 15721).unwrap();
        let file = home.join(".claude").join("settings.json");
        let mut v: Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
        v["env"]["ANTHROPIC_BASE_URL"] = json!("https://my-own-proxy.com");
        std::fs::write(&file, serde_json::to_string(&v).unwrap()).unwrap();
        take.disable(CliKind::ClaudeCode, 15721).unwrap();
        let v: Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
        assert_eq!(v.pointer("/env/ANTHROPIC_BASE_URL").unwrap(), "https://my-own-proxy.com", "用户的值不得删除");
        // 占位 key 仍按值移除
        assert!(v.pointer("/env/ANTHROPIC_AUTH_TOKEN").is_none());
    }

    // TC-CT-03  Codex：config.toml 写 provider 段（保留既有表与注释）+ auth.json
    #[test]
    fn codex_enable_writes_toml_and_auth() {
        let home = temp_home("codex");
        let take = CliTakeover::with_home(home.clone());
        let file = home.join(".codex").join("config.toml");
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, "# my config\nmodel = \"gpt-5\"\n").unwrap();

        take.enable(CliKind::Codex, 15721).unwrap();
        let text = std::fs::read_to_string(&file).unwrap();
        assert!(text.contains("# my config"), "注释必须保留（toml_edit）");
        assert!(text.contains("model_provider = \"brewping\""));
        assert!(text.contains("[model_providers.brewping]"));
        assert!(text.contains("base_url = \"http://127.0.0.1:15721/codex\""));
        assert!(text.contains("wire_api = \"chat\""));
        assert!(text.contains("model = \"gpt-5\""), "既有键必须保留");

        let auth: Value =
            serde_json::from_str(&std::fs::read_to_string(home.join(".codex/auth.json")).unwrap()).unwrap();
        assert_eq!(auth["OPENAI_API_KEY"], PLACEHOLDER_KEY);
        assert!(item(&take.status(15721), "codex").active);
    }

    // TC-CT-04  Codex：关闭移除 provider 段与 model_provider 键（既有内容保留）
    #[test]
    fn codex_disable_restores() {
        let home = temp_home("codex-off");
        let take = CliTakeover::with_home(home.clone());
        take.enable(CliKind::Codex, 15721).unwrap();
        take.disable(CliKind::Codex, 15721).unwrap();

        let text = std::fs::read_to_string(home.join(".codex/config.toml")).unwrap();
        assert!(!text.contains("model_provider = \"brewping\""));
        assert!(!text.contains("[model_providers.brewping]"));
        let auth: Value =
            serde_json::from_str(&std::fs::read_to_string(home.join(".codex/auth.json")).unwrap()).unwrap();
        assert!(auth.get("OPENAI_API_KEY").is_none());
        assert!(!item(&take.status(15721), "codex").active);
    }

    // TC-CT-05  文件不存在时开启会创建目录与文件
    #[test]
    fn enable_creates_missing_files() {
        let home = temp_home("fresh");
        let take = CliTakeover::with_home(home.clone());
        take.enable(CliKind::ClaudeCode, 15721).unwrap();
        assert!(home.join(".claude/settings.json").exists());
        take.enable(CliKind::Codex, 15721).unwrap();
        assert!(home.join(".codex/config.toml").exists());

        // 从零开始的还原也不报错
        take.disable(CliKind::ClaudeCode, 15721).unwrap();
        take.disable(CliKind::Codex, 15721).unwrap();
    }

    // TC-CT-06  parse：与前端字符串约定的双向
    #[test]
    fn cli_kind_parse() {
        assert_eq!(CliKind::parse("claude_code"), Some(CliKind::ClaudeCode));
        assert_eq!(CliKind::parse("claudeCode"), Some(CliKind::ClaudeCode));
        assert_eq!(CliKind::parse("codex"), Some(CliKind::Codex));
        assert_eq!(CliKind::parse("opencode"), Some(CliKind::OpenCode));
        assert_eq!(CliKind::parse("pi"), Some(CliKind::Pi));
        assert_eq!(CliKind::parse("gemini"), None);
    }

    // TC-CT-07  动态列表：ALL_KINDS 全量展示、字段齐全、顺序稳定
    //（本机可能装了 claude/codex，installed 不作真假断言，只验字段存在）
    #[test]
    fn status_lists_all_kinds_dynamically() {
        let take = CliTakeover::with_home(temp_home("list"));
        let info = take.status(15721);
        let ids: Vec<&str> = info.items.iter().map(|i| i.id.as_str()).collect();
        assert_eq!(ids, vec!["claude_code", "codex", "opencode", "pi"]);
        assert_eq!(info.proxy_port, 15721);
        for it in &info.items {
            assert!(!it.name.is_empty());
            assert!(!it.config_file.is_empty());
            assert_eq!(it.active, false, "空 home 下不可能 active");
            assert_eq!(it.exists, false, "空 home 下配置文件不存在");
            assert_eq!(
                it.supported,
                it.id == "claude_code" || it.id == "codex" || it.id == "pi"
            );
        }
    }

    // TC-CT-08  不支持接管的 CLI：enable/disable 被拦截并报错
    #[test]
    fn unsupported_takeover_is_rejected() {
        let take = CliTakeover::with_home(temp_home("unsup"));
        let err = take.enable(CliKind::OpenCode, 15721).unwrap_err();
        assert!(err.contains("OpenCode"));
        let err = take.disable(CliKind::OpenCode, 15721).unwrap_err();
        assert!(err.contains("OpenCode"));
    }

    // TC-CT-09  pi：写 models.json providers.brewping（三件套+占位模型）+ settings 成对默认
    #[test]
    fn pi_enable_writes_models_and_settings() {
        let home = temp_home("pi");
        let take = CliTakeover::with_home(home.clone());
        let models_file = home.join(".pi").join("agent").join("models.json");
        std::fs::create_dir_all(models_file.parent().unwrap()).unwrap();
        std::fs::write(
            &models_file,
            r#"{"providers":{"ollama":{"baseUrl":"http://localhost:11434/v1","api":"openai-completions","apiKey":"ollama","models":[{"id":"q"}]}}}"#,
        )
        .unwrap();

        take.enable(CliKind::Pi, 15721).unwrap();
        let v: Value = serde_json::from_str(&std::fs::read_to_string(&models_file).unwrap()).unwrap();
        let brew = v.pointer("/providers/brewping").unwrap();
        assert_eq!(brew["baseUrl"], "http://127.0.0.1:15721/pi");
        assert_eq!(brew["apiKey"], PLACEHOLDER_KEY);
        assert_eq!(brew["api"], "anthropic-messages");
        assert_eq!(brew["models"][0]["id"], PI_DEFAULT_MODEL);
        // 既有 provider 保留
        assert!(v.pointer("/providers/ollama/models/0/id").is_some());

        let settings: Value = serde_json::from_str(
            &std::fs::read_to_string(home.join(".pi").join("agent").join("settings.json").as_path())
                .unwrap(),
        )
        .unwrap();
        assert_eq!(settings["defaultProvider"], PI_PROVIDER_NAME);
        assert_eq!(settings["defaultModel"], PI_DEFAULT_MODEL);

        // 幂等 + active
        take.enable(CliKind::Pi, 15721).unwrap();
        assert!(item(&take.status(15721), "pi").active);
    }

    // TC-CT-10  pi：关闭按值还原（models.json 条目与 settings 两键；用户改过不动）
    #[test]
    fn pi_disable_restores_by_value() {
        let home = temp_home("pi-off");
        let take = CliTakeover::with_home(home.clone());
        take.enable(CliKind::Pi, 15721).unwrap();
        take.disable(CliKind::Pi, 15721).unwrap();

        let v: Value = serde_json::from_str(
            &std::fs::read_to_string(home.join(".pi/agent/models.json")).unwrap(),
        )
        .unwrap();
        assert!(v.pointer("/providers/brewping").is_none(), "brewping 条目必须移除");

        let s: Value = serde_json::from_str(
            &std::fs::read_to_string(home.join(".pi/agent/settings.json")).unwrap(),
        )
        .unwrap();
        assert!(s.get("defaultProvider").is_none(), "默认 provider 必须移除");
        assert!(s.get("defaultModel").is_none(), "默认 model 必须移除");
        assert!(!item(&take.status(15721), "pi").active);

        // 用户改过值 → 不动
        take.enable(CliKind::Pi, 15721).unwrap();
        let spath = home.join(".pi/agent/settings.json");
        let mut s: Value =
            serde_json::from_str(&std::fs::read_to_string(&spath).unwrap()).unwrap();
        s["defaultProvider"] = json!("my-own-proxy");
        std::fs::write(&spath, serde_json::to_string(&s).unwrap()).unwrap();
        take.disable(CliKind::Pi, 15721).unwrap();
        let s: Value = serde_json::from_str(&std::fs::read_to_string(&spath).unwrap()).unwrap();
        assert_eq!(s["defaultProvider"], "my-own-proxy", "用户的默认不得删除");
    }
}
