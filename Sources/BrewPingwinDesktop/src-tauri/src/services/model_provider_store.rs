//! 模型供应商配置（多厂商接入）——内置 cc-switch 的「供应商接入」能力。
//!
//! 数据模型对齐 cc-switch `Provider` 的核心字段（typed 化，不用异构 JSON 快照：
//! 我们只服务自家的转发代理，不需要兼容各 CLI 的原生配置格式）。
//! 持久化沿用本项目惯例：`~/.brewping/` 下一个偏好一个 JSON 文件
//! （与 `pairing.json` / `models.json` 同目录；`api_key` 与 pairing token 同级明文存储，
//! 该目录是用户私有目录，与 cc-switch 把 key 存 SQLite 的安全边界一致）。
//!
//! 切换语义：`current_id` 指向当前生效配置；转发代理（`model_proxy`）**每个请求**
//! 都读当前值，因此切换即时生效，CLI 端无需重启（对齐 cc-switch 切换供应商后
//! CLI 无感的核心体验）。

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

/// 转发代理默认端口：对齐 cc-switch（CLI 配置从 cc-switch 迁过来时无需改端口）。
pub const DEFAULT_PROXY_PORT: u16 = 15721;

fn default_proxy_port() -> u16 {
    DEFAULT_PROXY_PORT
}

/// 上游 API 协议族（决定鉴权头与代理转发语义；协议转换属后续分期）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ApiFormat {
    /// Anthropic Messages（Claude 系；`x-api-key` + `anthropic-version`）。
    #[default]
    Anthropic,
    /// OpenAI Chat Completions（`Authorization: Bearer`）。
    OpenaiChat,
    /// OpenAI Responses（`Authorization: Bearer`）。
    OpenaiResponses,
}

impl ApiFormat {
    /// 该协议族的默认鉴权头形态（`auth_style = Auto` 时使用）。
    pub fn default_auth_is_bearer(self) -> bool {
        !matches!(self, ApiFormat::Anthropic)
    }

    /// 是否需要 anthropic-version 头（仅 Anthropic 协议族）。
    pub fn default_version_header_needed(self) -> bool {
        matches!(self, ApiFormat::Anthropic)
    }
}

/// 鉴权方式覆盖（对齐 cc-switch `meta.apiKeyField` 的诉求：部分 anthropic 兼容
/// 中转站要求 Bearer 而不是 x-api-key；`Auto` 按协议族默认）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum AuthStyle {
    #[default]
    Auto,
    Bearer,
    #[serde(rename = "x-api-key")]
    XApiKey,
}

/// 一条模型供应商配置。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct ModelProviderConfig {
    /// 稳定 ID（uuid；空串视为新建，由后端生成）。
    pub id: String,
    /// 归属 Agent（"" = 通用：所有 Agent 可见可用；旧数据缺字段自动归通用）。
    /// 创建时锁定 —— 编辑更新时后端保留原归属，不允许改（防「编辑厂商」串味）。
    pub agent_id: String,
    /// 展示名（如 "Kimi" / "DeepSeek"）。
    pub name: String,
    /// 上游接口地址。`is_full_url = false` 时为 base（拼接路径）；
    /// `true` 时为完整端点（转发不再拼路径，对齐 cc-switch `meta.isFullUrl`）。
    #[serde(rename = "baseUrl")]
    pub base_url: String,
    /// 上游 API Key（转发时替换 CLI 送来的凭据）。
    #[serde(rename = "apiKey")]
    pub api_key: String,
    /// 接口协议族。
    #[serde(rename = "apiFormat")]
    pub api_format: ApiFormat,
    /// 鉴权方式（Auto = 按协议族默认）。
    #[serde(rename = "authStyle")]
    pub auth_style: AuthStyle,
    /// base_url 已是完整端点，不再拼接请求路径。
    #[serde(rename = "isFullUrl")]
    pub is_full_url: bool,
    /// 该配置的默认模型（展示/后续路由用；透传模式不改写请求体）。
    pub model: Option<String>,
    pub notes: Option<String>,
    /// 创建时刻（ms epoch）。
    #[serde(rename = "createdAtMs")]
    pub created_at_ms: i64,
    /// 展示排序（小的在前）。
    #[serde(rename = "sortIndex")]
    pub sort_index: usize,
}

impl Default for ModelProviderConfig {
    fn default() -> Self {
        Self {
            id: String::new(),
            agent_id: String::new(),
            name: String::new(),
            base_url: String::new(),
            api_key: String::new(),
            api_format: ApiFormat::default(),
            auth_style: AuthStyle::default(),
            is_full_url: false,
            model: None,
            notes: None,
            created_at_ms: 0,
            sort_index: 0,
        }
    }
}

/// 落盘结构（`~/.brewping/model_providers.json`）。全部字段带 default：
/// 旧版文件 / 缺字段都能加载，不破坏已有配置。
#[derive(Debug, Default, Clone, Serialize, Deserialize)]
struct Stored {
    #[serde(default)]
    providers: Vec<ModelProviderConfig>,
    /// 当前生效的配置（代理转发目标）——通用槽：所有 Agent 的回落值。
    #[serde(rename = "currentId", default)]
    current_id: Option<String>,
    /// 按 Agent 的当前配置（Agent 专属槽，优先于通用 `current_id`；
    /// key = agent id 如 "claude-code"，缺条目的 Agent 直接用通用槽）。
    #[serde(rename = "currentByAgent", default)]
    current_by_agent: HashMap<String, String>,
    /// 转发代理开关（默认关闭：不开 = 与旧版行为零差异）。
    #[serde(rename = "proxyEnabled", default)]
    proxy_enabled: bool,
    #[serde(rename = "proxyPort", default = "default_proxy_port")]
    proxy_port: u16,
    /// 自动故障转移（默认关，对齐 cc-switch `auto_failover_enabled`；
    /// 开启后代理按 sortIndex 顺序逐个尝试并在成功后自动切换 current）。
    #[serde(rename = "failoverEnabled", default)]
    failover_enabled: bool,
}

/// 模型供应商配置仓库（进程内单例，Mutex 串行写）。
pub struct ModelProviderStore {
    path: PathBuf,
    inner: Mutex<Stored>,
}

impl ModelProviderStore {
    /// 使用默认路径 `~/.brewping/model_providers.json`。
    pub fn new() -> Self {
        Self::with_path(default_path())
    }

    /// 指定持久化路径构造（测试用）。
    pub fn with_path(path: PathBuf) -> Self {
        let inner = load(&path);
        Self {
            path,
            inner: Mutex::new(inner),
        }
    }

    /// 当前全量快照（含代理设置；供命令层渲染 DTO）。
    pub fn snapshot(&self) -> StoredSnapshot {
        StoredSnapshot::from(&*self.inner.lock().expect("model provider store poisoned"))
    }

    /// 当前生效的供应商配置（无 current 或 id 已不存在 → None）。
    pub fn current(&self) -> Option<ModelProviderConfig> {
        let stored = self.inner.lock().expect("model provider store poisoned");
        stored
            .current_id
            .as_deref()
            .and_then(|id| stored.providers.iter().find(|p| p.id == id))
            .cloned()
    }

    /// 当前配置 ID（可能指向已删除的项 → None）。
    pub fn current_id(&self) -> Option<String> {
        let stored = self.inner.lock().expect("model provider store poisoned");
        stored
            .current_id
            .as_deref()
            .filter(|id| stored.providers.iter().any(|p| &p.id == id))
            .map(String::from)
    }

    /// 是否开启自动故障转移。
    pub fn failover_enabled(&self) -> bool {
        self.inner
            .lock()
            .expect("model provider store poisoned")
            .failover_enabled
    }

    /// 设置自动故障转移开关。
    pub fn set_failover(&self, enabled: bool) -> StoredSnapshot {
        let mut stored = self.inner.lock().expect("model provider store poisoned");
        stored.failover_enabled = enabled;
        save(&self.path, &stored);
        StoredSnapshot::from(&*stored)
    }

    /// 路由链（对齐 cc-switch `ProviderRouter::select_providers`）：
    /// - failover 关 → 仅当前配置；
    /// - failover 开 → 全部配置按 sortIndex 升序（列表顺序即故障转移顺序）。
    /// 返回 (配置列表, 请求开始时的 currentId)。通用版 = `route_chain_for("")`。
    pub fn route_chain(&self) -> (Vec<ModelProviderConfig>, Option<String>) {
        self.route_chain_for("")
    }

    /// per-Agent 路由链：与 `route_chain` 的唯一差异是「当前」的解析——
    /// Agent 专属槽（`current_by_agent[agent_id]`）优先，回落通用槽。
    /// failover 开时全量参与兜底，排序 = 同归属 → 通用 → 异归属（组内按 sortIndex），
    /// 即「给本 Agent 配的厂商优先扛，其它归属只做最后兜底」。
    pub fn route_chain_for(&self, agent_id: &str) -> (Vec<ModelProviderConfig>, Option<String>) {
        let stored = self.inner.lock().expect("model provider store poisoned");
        let start = resolve_current_for(agent_id, &stored);
        let current = start
            .as_deref()
            .and_then(|id| stored.providers.iter().find(|p| &p.id == id));
        if !stored.failover_enabled {
            return (
                current.cloned().into_iter().collect(),
                current.map(|c| c.id.clone()),
            );
        }
        let mut chain: Vec<ModelProviderConfig> = stored.providers.clone();
        chain.sort_by_key(|p| (ownership_rank(&p.agent_id, agent_id), p.sort_index));
        (chain, current.map(|c| c.id.clone()))
    }

    /// 新增或更新（按 id upsert；`id` 为空 = 新建并生成 uuid）。
    /// 校验：name 与 base_url 必填（base_url 至少要像 http(s) URL）。
    pub fn upsert(&self, mut cfg: ModelProviderConfig) -> Result<ModelProviderConfig, String> {
        cfg.name = cfg.name.trim().to_string();
        cfg.base_url = cfg.base_url.trim().to_string();
        cfg.agent_id = cfg.agent_id.trim().to_string();
        if cfg.name.is_empty() {
            return Err("name is required".to_string());
        }
        let lowered = cfg.base_url.to_lowercase();
        if !(lowered.starts_with("http://") || lowered.starts_with("https://")) {
            return Err("base_url must start with http:// or https://".to_string());
        }
        if cfg.base_url.ends_with('/') {
            cfg.base_url.pop();
        }

        let mut stored = self.inner.lock().expect("model provider store poisoned");
        if cfg.id.trim().is_empty() {
            cfg.id = uuid::Uuid::new_v4().simple().to_string();
            cfg.created_at_ms = chrono::Utc::now().timestamp_millis();
            cfg.sort_index = stored.providers.len();
            stored.providers.push(cfg.clone());
        } else {
            match stored.providers.iter_mut().find(|p| p.id == cfg.id) {
                Some(slot) => {
                    // Key 保留语义（掩码回填）：提交为空或等于掩码串
                    // = 用户没动 Key 字段 → 保留旧值（前端只拿得到掩码，
                    // 原样回填时绝不能把掩码当新 Key 孰进去）。
                    let submitted = cfg.api_key.trim();
                    if submitted.is_empty() || submitted == mask_api_key(&slot.api_key) {
                        cfg.api_key = slot.api_key.clone();
                    }
                    // 归属创建时锁定：编辑更新一律保留原归属（防「编辑串味」）。
                    cfg.agent_id = slot.agent_id.clone();
                    // 保留创建时间与排序（id 是身份，其余字段以提交为准）
                    cfg.created_at_ms = slot.created_at_ms;
                    cfg.sort_index = slot.sort_index;
                    *slot = cfg.clone();
                }
                None => {
                    cfg.created_at_ms = chrono::Utc::now().timestamp_millis();
                    cfg.sort_index = stored.providers.len();
                    stored.providers.push(cfg.clone());
                }
            }
        }
        // 首条配置自动成为当前（开箱即用；已有 current 时不覆盖）
        if stored.current_id.is_none() {
            stored.current_id = Some(cfg.id.clone());
        }
        save(&self.path, &stored);
        Ok(cfg)
    }

    /// 删除配置；删的是当前项时一并清除 current（代理下个请求会 503 提示）。
    pub fn delete(&self, id: &str) -> Result<(), String> {
        let mut stored = self.inner.lock().expect("model provider store poisoned");
        let before = stored.providers.len();
        stored.providers.retain(|p| p.id != id);
        if stored.providers.len() == before {
            return Err(format!("unknown provider id: {id}"));
        }
        if stored.current_id.as_deref() == Some(id) {
            stored.current_id = None;
        }
        // 清理指向被删配置的 Agent 专属槽（下个请求回落通用槽）
        stored.current_by_agent.retain(|_, v| v != id);
        save(&self.path, &stored);
        Ok(())
    }

    /// 切换当前配置（即时生效：代理每请求读 current）。通用槽版 = `switch_current_for("")`。
    pub fn switch_current(&self, id: &str) -> Result<(), String> {
        self.switch_current_for("", id)
    }

    /// 切换某个 Agent 的当前配置。`agent_id` 为空 = 通用槽（全 Agent 回落）；
    /// 非空 = 该 Agent 的专属槽（优先于通用槽生效）。
    /// 归属防串味：目标配置明确归属**其他** Agent 时不落 current（failover 允许
    /// 跨归属临时兜底，但不得改写归属语义）——返回 Ok 且状态不变。
    pub fn switch_current_for(&self, agent_id: &str, id: &str) -> Result<(), String> {
        let mut stored = self.inner.lock().expect("model provider store poisoned");
        let Some(cfg) = stored.providers.iter().find(|p| p.id == id) else {
            return Err(format!("unknown provider id: {id}"));
        };
        if agent_id.is_empty() {
            stored.current_id = Some(id.to_string());
        } else if cfg.agent_id.is_empty() || cfg.agent_id == agent_id {
            stored
                .current_by_agent
                .insert(agent_id.to_string(), id.to_string());
        }
        // cfg.agent_id 与 agent_id 都非空且不等：防串味，不写 current。
        save(&self.path, &stored);
        Ok(())
    }

    /// 更新代理开关与端口（返回快照；代理进程的启停由调用方 `ModelProxyManager` 负责）。
    pub fn set_proxy(&self, enabled: bool, port: u16) -> StoredSnapshot {
        let mut stored = self.inner.lock().expect("model provider store poisoned");
        stored.proxy_enabled = enabled;
        stored.proxy_port = if port == 0 { DEFAULT_PROXY_PORT } else { port };
        save(&self.path, &stored);
        StoredSnapshot::from(&*stored)
    }
}

impl Default for ModelProviderStore {
    fn default() -> Self {
        Self::new()
    }
}

/// 某 Agent 的当前配置解析：专属槽 → 通用槽 → None（指向已删除项视为 None）。
/// `agent_id` 为空 = 通用请求，只看通用槽。
fn resolve_current_for(agent_id: &str, stored: &Stored) -> Option<String> {
    let candidate = if agent_id.is_empty() {
        stored.current_id.clone()
    } else {
        stored
            .current_by_agent
            .get(agent_id)
            .cloned()
            .or_else(|| stored.current_id.clone())
    };
    candidate.filter(|id| stored.providers.iter().any(|p| &p.id == id))
}

/// failover 兜底排序秩：同归属最优先 → 通用次之 → 异归属最后（组内按 sortIndex）。
/// 异归属仍参与兜底（最大化可用性），只是排到最后。
fn ownership_rank(owner: &str, agent_id: &str) -> u8 {
    if owner.is_empty() {
        1
    } else if owner == agent_id {
        0
    } else {
        2
    }
}

/// 生成密钥掩码：保留前 3 位与后 4 位，中间统一 8 个圆点。
/// 短于 12 位时整体打码，避免「掩码本身泄露密钥」。
pub fn mask_api_key(key: &str) -> String {
    let k = key.trim();
    if k.is_empty() {
        return String::new();
    }
    if k.chars().count() < 12 {
        return "•".repeat(8);
    }
    let prefix: String = k.chars().take(3).collect();
    let suffix: String = k
        .chars()
        .rev()
        .take(4)
        .collect::<String>()
        .chars()
        .rev()
        .collect();
    format!("{prefix}••••••••{suffix}")
}

/// 对前端的出参视图：apiKey 已掩码，明文 Key 绝不回传 WebView。
/// （保存语义：前端提交空串或等于掩码 = 用户没动该字段 → 后端保留旧 Key。）
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderView {
    pub id: String,
    /// 归属 Agent（"" = 通用；camelCase 序列化为 agentId）。
    pub agent_id: String,
    pub name: String,
    #[serde(rename = "baseUrl")]
    pub base_url: String,
    /// 掩码（如 "sk-••••••••abcd"）；空 Key 时为空串。
    pub api_key_masked: String,
    /// 是否已配置 Key（前端显示「已配置/未配置」依据此字段，不解析掩码串）。
    pub has_key: bool,
    pub api_format: ApiFormat,
    pub auth_style: AuthStyle,
    #[serde(rename = "isFullUrl")]
    pub is_full_url: bool,
    pub model: Option<String>,
    pub notes: Option<String>,
    #[serde(rename = "createdAtMs")]
    pub created_at_ms: i64,
    #[serde(rename = "sortIndex")]
    pub sort_index: usize,
}

impl From<&ModelProviderConfig> for ProviderView {
    fn from(p: &ModelProviderConfig) -> Self {
        Self {
            id: p.id.clone(),
            agent_id: p.agent_id.clone(),
            name: p.name.clone(),
            base_url: p.base_url.clone(),
            api_key_masked: mask_api_key(&p.api_key),
            has_key: !p.api_key.trim().is_empty(),
            api_format: p.api_format,
            auth_style: p.auth_style,
            is_full_url: p.is_full_url,
            model: p.model.clone(),
            notes: p.notes.clone(),
            created_at_ms: p.created_at_ms,
            sort_index: p.sort_index,
        }
    }
}

/// 快照 DTO（对前端 camelCase；proxy 字段与 Stored 对齐）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StoredSnapshot {
    pub providers: Vec<ProviderView>,
    pub current_id: Option<String>,
    /// Agent 专属当前（key = agent id；前端解析顺序：专属 → current_id → None）。
    pub current_by_agent: HashMap<String, String>,
    pub proxy_enabled: bool,
    pub proxy_port: u16,
    pub failover_enabled: bool,
}

impl From<&Stored> for StoredSnapshot {
    fn from(s: &Stored) -> Self {
        Self {
            providers: s.providers.iter().map(ProviderView::from).collect(),
            current_id: s.current_id.clone(),
            current_by_agent: s.current_by_agent.clone(),
            proxy_enabled: s.proxy_enabled,
            proxy_port: s.proxy_port,
            failover_enabled: s.failover_enabled,
        }
    }
}

impl From<Stored> for StoredSnapshot {
    fn from(s: Stored) -> Self {
        (&s).into()
    }
}

fn default_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".brewping")
        .join("model_providers.json")
}

fn load(path: &PathBuf) -> Stored {
    let Ok(data) = std::fs::read_to_string(path) else {
        return Stored::default();
    };
    // 损坏/旧版缺字段：退化成默认值（或保留能解析出的部分），绝不 panic
    serde_json::from_str::<Stored>(&data).unwrap_or_default()
}

fn save(path: &PathBuf, stored: &Stored) {
    let Ok(data) = serde_json::to_string_pretty(stored) else {
        return;
    };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if std::fs::write(path, data).is_ok() {
        harden_permissions(path);
    }
}

/// 收紧配置文件权限（api_key 是敏感数据，Windows 默认 ACL 允许同机其他用户读）：
/// - Windows：icacls 移除继承，仅当前用户 + SYSTEM 完全控制；
/// - 其他平台：0o600。
/// 失败静默 —— 权限收紧是尽力而为，不阻塞保存。
fn harden_permissions(path: &std::path::Path) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let user = std::env::var("USERNAME").unwrap_or_default();
        if user.is_empty() {
            return;
        }
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        let _ = std::process::Command::new("icacls")
            .arg(path)
            .arg("/inheritance:r")
            .arg("/grant:r")
            .arg(format!("{user}:F"))
            .arg("/grant:r")
            .arg("SYSTEM:F")
            .creation_flags(CREATE_NO_WINDOW)
            .output();
    }
    #[cfg(not(windows))]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_path(tag: &str) -> PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!(
            "brewping-mp-store-test-{}-{}.json",
            tag,
            uuid::Uuid::new_v4().simple()
        ));
        path
    }

    fn sample(name: &str) -> ModelProviderConfig {
        ModelProviderConfig {
            name: name.to_string(),
            base_url: "https://api.example.com".to_string(),
            api_key: "sk-test".to_string(),
            api_format: ApiFormat::Anthropic,
            ..Default::default()
        }
    }

    // TC-MPS-01  upsert 新建（生成 id + 首条自动成为 current）+ 按 id 更新，落盘可复用
    #[test]
    fn upsert_create_update_and_persist() {
        let path = temp_path("upsert");
        let store = ModelProviderStore::with_path(path.clone());

        let created = store.upsert(sample("Kimi")).unwrap();
        assert!(!created.id.is_empty(), "新建必须生成 id");
        assert_eq!(
            store.current().map(|c| c.id),
            Some(created.id.clone()),
            "首条配置自动成为当前"
        );

        let mut edited = created.clone();
        edited.base_url = "https://api2.example.com".to_string();
        let saved = store.upsert(edited).unwrap();
        assert_eq!(saved.id, created.id, "同 id 是更新不是新建");
        assert_eq!(store.snapshot().providers.len(), 1, "不产生重复条目");

        let again = ModelProviderStore::with_path(path.clone());
        assert_eq!(again.snapshot().providers[0].base_url, "https://api2.example.com");
        let _ = std::fs::remove_file(path);
    }

    // TC-MPS-02  upsert 校验：空名 / 非 http(s) 地址拒绝
    #[test]
    fn upsert_validates_input() {
        let path = temp_path("validate");
        let store = ModelProviderStore::with_path(path.clone());

        let mut bad = sample("x");
        bad.name = "  ".to_string();
        assert!(store.upsert(bad).is_err(), "空名必须拒绝");

        let mut bad = sample("x");
        bad.base_url = "ftp://example.com".to_string();
        assert!(store.upsert(bad).is_err(), "非 http(s) 地址必须拒绝");

        assert!(store.snapshot().providers.is_empty(), "被拒条目不得落盘");
        let _ = std::fs::remove_file(path);
    }

    // TC-MPS-03  delete：删当前项清 current；未知 id 报错
    #[test]
    fn delete_clears_current_and_rejects_unknown() {
        let path = temp_path("delete");
        let store = ModelProviderStore::with_path(path.clone());
        let a = store.upsert(sample("A")).unwrap();
        let b = store.upsert(sample("B")).unwrap();
        store.switch_current(&b.id).unwrap();

        store.delete(&a.id).unwrap();
        assert_eq!(store.snapshot().providers.len(), 1);
        assert_eq!(store.current().map(|c| c.id), Some(b.id.clone()), "删非当前项不动 current");

        store.delete(&b.id).unwrap();
        assert!(store.current().is_none(), "删当前项必须清 current");

        assert!(store.delete("nope").is_err(), "未知 id 必须报错");
        let _ = std::fs::remove_file(path);
    }

    // TC-MPS-04  switch_current：存在/不存在
    #[test]
    fn switch_current_validates() {
        let path = temp_path("switch");
        let store = ModelProviderStore::with_path(path.clone());
        let a = store.upsert(sample("A")).unwrap();
        let b = store.upsert(sample("B")).unwrap();

        store.switch_current(&b.id).unwrap();
        assert_eq!(store.current().map(|c| c.id), Some(b.id.clone()));

        assert!(store.switch_current("nope").is_err(), "未知 id 必须报错");
        assert_eq!(store.current().map(|c| c.id), Some(b.id.clone()), "失败切换不改变状态");

        // 重载后 current 保持
        let again = ModelProviderStore::with_path(path.clone());
        assert_eq!(again.current().map(|c| c.id), Some(b.id), "current 必须落盘");
        let _ = std::fs::remove_file(path);
    }

    // TC-MPS-05  损坏文件 / 旧版缺字段文件：容错加载
    #[test]
    fn tolerates_broken_and_legacy_files() {
        let path = temp_path("broken");
        std::fs::write(&path, "{ this is not json").unwrap();
        let store = ModelProviderStore::with_path(path.clone());
        assert!(store.snapshot().providers.is_empty());
        drop(store);

        // 旧版缺 proxy 字段：serde default 补齐
        std::fs::write(&path, r#"{"providers":[],"currentId":null}"#).unwrap();
        let store = ModelProviderStore::with_path(path.clone());
        let snap = store.snapshot();
        assert_eq!(snap.proxy_port, DEFAULT_PROXY_PORT);
        assert!(!snap.proxy_enabled);
        let _ = std::fs::remove_file(path);
    }

    // TC-MPS-06  set_proxy 持久化 + 端口 0 回落默认
    #[test]
    fn set_proxy_persists() {
        let path = temp_path("proxy");
        let store = ModelProviderStore::with_path(path.clone());
        let snap = store.set_proxy(true, 0);
        assert!(snap.proxy_enabled);
        assert_eq!(snap.proxy_port, DEFAULT_PROXY_PORT, "0 回落默认端口");

        let again = ModelProviderStore::with_path(path.clone());
        let snap = again.snapshot();
        assert!(snap.proxy_enabled);
        assert_eq!(snap.proxy_port, DEFAULT_PROXY_PORT);
        let _ = std::fs::remove_file(path);
    }

    // TC-MPS-07  failover：默认关；route_chain 关=仅 current、开=按 sortIndex 全量
    #[test]
    fn failover_route_chain() {
        let path = temp_path("failover");
        let store = ModelProviderStore::with_path(path.clone());
        assert!(!store.failover_enabled(), "默认关闭");

        let a = store.upsert(sample("A")).unwrap(); // sort_index 0
        let b = store.upsert(sample("B")).unwrap(); // sort_index 1
        store.switch_current(&b.id).unwrap();

        // 关：仅 current
        let (chain, start) = store.route_chain();
        assert_eq!(chain.iter().map(|p| p.id.clone()).collect::<Vec<_>>(), vec![b.id.clone()]);
        assert_eq!(start.as_deref(), Some(b.id.as_str()));

        // 开：按 sortIndex 全量（a 在前，尽管 current 是 b —— 对齐 cc-switch
        // “队列顺序优先于当前”语义）
        store.set_failover(true);
        let (chain, start) = store.route_chain();
        assert_eq!(chain.iter().map(|p| p.id.clone()).collect::<Vec<_>>(), vec![a.id.clone(), b.id.clone()]);
        assert_eq!(start.as_deref(), Some(b.id.as_str()));

        // 落盘
        let again = ModelProviderStore::with_path(path.clone());
        assert!(again.failover_enabled());
        let _ = std::fs::remove_file(path);
    }

    // TC-MPS-08  mask_api_key 各长度：空 / 短 / 正常
    #[test]
    fn mask_api_key_lengths() {
        assert_eq!(mask_api_key(""), "", "空 Key 掩码为空串");
        assert_eq!(mask_api_key("   "), "", "纯空白视同空");
        assert_eq!(mask_api_key("short"), "•".repeat(8), "短 Key 整体打码");
        assert_eq!(
            mask_api_key("sk-1234567890abcdef"),
            "sk-••••••••cdef",
            "正常 Key 保前 3 后 4"
        );
    }

    // TC-MPS-09/10/11  掩码回填 / 空串不覆盖真 Key；新 Key 正常覆盖
    #[test]
    fn upsert_key_keep_semantics() {
        let path = temp_path("mask");
        let store = ModelProviderStore::with_path(path.clone());
        let created = store.upsert(sample("A")).unwrap(); // api_key = "sk-test"

        // TC-MPS-09  掩码回填（用户没动字段）→ 真 Key 保留
        let mut edited = created.clone();
        edited.api_key = mask_api_key("sk-test");
        store.upsert(edited).unwrap();
        assert_eq!(
            store.current().unwrap().api_key,
            "sk-test",
            "掩码回填不得覆盖真 Key"
        );

        // TC-MPS-10  空串提交 → 真 Key 保留
        let mut edited = created.clone();
        edited.api_key = String::new();
        store.upsert(edited).unwrap();
        assert_eq!(store.current().unwrap().api_key, "sk-test", "空串不得覆盖真 Key");

        // TC-MPS-11  新 Key 正常覆盖
        let mut edited = created.clone();
        edited.api_key = "sk-brand-new-key".to_string();
        store.upsert(edited).unwrap();
        assert_eq!(store.current().unwrap().api_key, "sk-brand-new-key");
        let _ = std::fs::remove_file(path);
    }

    // TC-MPS-12  出参不含明文 Key（序列化层面验证）
    #[test]
    fn provider_view_hides_plaintext_key() {
        let view = ProviderView::from(&ModelProviderConfig {
            name: "Kimi".to_string(),
            api_key: "sk-super-secret-0001".to_string(),
            ..Default::default()
        });
        let text = serde_json::to_string(&view).unwrap();
        assert!(!text.contains("sk-super-secret-0001"), "出参不得含明文 Key");
        assert!(text.contains("apiKeyMasked"), "字段名必须 camelCase");
        assert!(view.has_key, "有 Key 时 hasKey 必须为 true");

        let empty = ProviderView::from(&ModelProviderConfig::default());
        assert!(!empty.has_key);
        assert_eq!(empty.api_key_masked, "");
    }

    // TC-MPS-13  归属与 per-agent current：专属 → 通用回落；Agent 之间互不影响
    #[test]
    fn per_agent_current_resolution() {
        let path = temp_path("peragent");
        let store = ModelProviderStore::with_path(path.clone());

        let universal = store.upsert(sample("U")).unwrap(); // 通用（agent_id=""）
        let mut owned = sample("O");
        owned.agent_id = "claude-code".to_string();
        let owned = store.upsert(owned).unwrap();

        // 无专属槽时回落通用槽
        assert_eq!(
            store.snapshot().current_id.as_deref(),
            Some(universal.id.as_str()),
            "首条自动成为通用当前"
        );
        // 给 claude-code 设专属当前
        store.switch_current_for("claude-code", &owned.id).unwrap();
        // codex 没有专属条目 → 仍回落通用（currentByAgent 不含 codex）
        let snap = store.snapshot();
        assert_eq!(snap.current_by_agent.get("claude-code").map(String::as_str), Some(owned.id.as_str()));
        assert!(!snap.current_by_agent.contains_key("codex"), "未设置的 Agent 不得有条目");
        // 通用槽不受 per-agent 切换影响
        assert_eq!(snap.current_id.as_deref(), Some(universal.id.as_str()));

        // 落盘可复用
        let again = ModelProviderStore::with_path(path.clone());
        assert_eq!(
            again.snapshot().current_by_agent.get("claude-code").map(String::as_str),
            Some(owned.id.as_str()),
            "per-agent current 必须落盘"
        );
        let _ = std::fs::remove_file(path);
    }

    // TC-MPS-14  route_chain_for：failover 开时 同归属 → 通用 → 异归属（组内按 sortIndex）
    #[test]
    fn route_chain_for_orders_by_ownership() {
        let path = temp_path("chain");
        let store = ModelProviderStore::with_path(path.clone());

        // 通用（sort 0）→ claude-code 专属（sort 1、3）→ codex 专属（sort 2）
        let mut a1 = sample("A1");
        a1.sort_index = 0;
        let mut m1 = sample("M1");
        m1.agent_id = "claude-code".to_string();
        m1.sort_index = 1;
        let mut x1 = sample("X1");
        x1.agent_id = "codex".to_string();
        x1.sort_index = 2;
        let mut m2 = sample("M2");
        m2.agent_id = "claude-code".to_string();
        m2.sort_index = 3;
        store.upsert(a1).unwrap();
        store.upsert(m1).unwrap();
        store.upsert(x1).unwrap();
        store.upsert(m2).unwrap();
        store.set_failover(true);

        let (chain, _) = store.route_chain_for("claude-code");
        let names: Vec<&str> = chain.iter().map(|p| p.name.as_str()).collect();
        assert_eq!(
            names,
            vec!["M1", "M2", "A1", "X1"],
            "同归属 → 通用 → 异归属（组内按 sortIndex）"
        );
        let _ = std::fs::remove_file(path);
    }

    // TC-MPS-15  switch_current_for 跨归属防护：归属他人的配置不落 current
    #[test]
    fn switch_current_for_rejects_cross_ownership() {
        let path = temp_path("cross");
        let store = ModelProviderStore::with_path(path.clone());
        let mut theirs = sample("T");
        theirs.agent_id = "codex".to_string();
        let theirs = store.upsert(theirs).unwrap();
        let universal = store.upsert(sample("U")).unwrap();

        // claude-code 想把 codex 专属配置设为自己的当前 → Ok 但不落槽
        store.switch_current_for("claude-code", &theirs.id).unwrap();
        let snap = store.snapshot();
        assert!(
            !snap.current_by_agent.contains_key("claude-code"),
            "跨归属配置不得写入本 Agent 专属槽"
        );

        // 通用配置可以被任意 Agent 设为专属当前
        store.switch_current_for("claude-code", &universal.id).unwrap();
        assert_eq!(
            store.snapshot().current_by_agent.get("claude-code").map(String::as_str),
            Some(universal.id.as_str())
        );
        // 未知 id 仍报错
        assert!(store.switch_current_for("claude-code", "nope").is_err());
        let _ = std::fs::remove_file(path);
    }

    // TC-MPS-16  删除清理专属槽 + 旧版文件（无 currentByAgent）容错加载
    #[test]
    fn delete_cleans_agent_slots_and_legacy_load() {
        let path = temp_path("cleanup");

        // 旧版 JSON（没有 currentByAgent 字段）能加载
        std::fs::write(&path, r#"{"providers":[],"currentId":null}"#).unwrap();
        let legacy = ModelProviderStore::with_path(path.clone());
        assert!(legacy.snapshot().current_by_agent.is_empty());
        drop(legacy);

        let store = ModelProviderStore::with_path(path.clone());
        let mut owned = sample("O");
        owned.agent_id = "claude-code".to_string();
        let created = store.upsert(owned).unwrap();
        store.switch_current_for("claude-code", &created.id).unwrap();
        assert!(store.snapshot().current_by_agent.contains_key("claude-code"));

        store.delete(&created.id).unwrap();
        assert!(
            !store.snapshot().current_by_agent.contains_key("claude-code"),
            "删除配置必须清理指向它的专属槽"
        );
        let _ = std::fs::remove_file(path);
    }
}
