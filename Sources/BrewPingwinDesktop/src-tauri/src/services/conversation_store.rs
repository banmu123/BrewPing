//! 多对话存储（方案 §4）：元数据（索引）与转录（逐对话文件）两层分离，
//! 对齐 Lody「会话即文档」的设计。
//!
//! 落盘布局：
//! ```text
//! ~/.brewping/conversations/
//!   index.json              ← ConversationSummary 列表（列表页数据源，派生缓存）
//!   conv_<id>.json          ← 完整转录（含 messages，权威数据）
//! ```
//!
//! 铁律（与 `workdir_prefs.rs` 同源）：
//! 1. 结构体全部 `#[serde(default)]`——旧文件缺键不得清空数据；
//! 2. 测试必须 `with_dir(temp)` 隔离，禁止写真实 `~/.brewping/`；
//! 3. 文件损坏/缺失 → 从文件扫描恢复，退化不 panic；
//! 4. 「锁内改快照、锁外写盘」——Mutex guard 不跨 I/O 持有。
//!
//! 状态写入权边界（方案 §2-A5）：命令状态与 `latest_command_id` 只由
//! `command_runner`（执行者上下文）写入；HTTP 层 / Tauri 命令层无权改。

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use super::approval_gate::ApprovalMode;

/// Lody `pinnedFirstRootRank` 的置顶偏移量：一个数值同时表达两个排序维度
/// （置顶 > 未置顶，各自内部按 updated_at 降序）。
pub const PINNED_RANK_OFFSET: f64 = 1e15;

/// 一条对话消息（转录的最小单元，对应 Lody 的 history entry）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptEntry {
    pub id: String,
    /// "user" | "assistant" | "error" | "system"
    pub role: String,
    pub text: String,
    /// 命令来源渠道（"desktop" | "ios" | "watch"）。
    #[serde(default)]
    pub source: Option<String>,
    /// 关联 CommandStore 的命令 ID。
    #[serde(default)]
    pub command_id: Option<String>,
    pub created_at_ms: u64,
}

/// 对话完整内容（逐对话一个文件，对应 Lody 的会话文档 body）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Conversation {
    pub id: String,
    pub agent_id: String,
    #[serde(default)]
    pub title: Option<String>,
    /// "auto"（首条消息截取）| "manual"（用户命名，永不覆盖）。
    #[serde(default)]
    pub title_source: Option<String>,
    pub created_at_ms: u64,
    /// 单调：只在更大时写（对齐 Lody buildSessionActivityPatch，乱序事件不回拉）。
    pub updated_at_ms: u64,
    #[serde(default)]
    pub archived: bool,
    #[serde(default)]
    pub is_pinned: bool,
    /// 对话级覆盖项：不设则回落到全局 model_prefs / workdir_prefs。
    #[serde(default)]
    pub model_override: Option<String>,
    /// 与 `model_override` 配对的 providerId（同名模型可来自多个厂商；
    /// opencode 的 `--model` 需要 `provider/model` 复合限定名）。
    #[serde(default)]
    pub model_provider_override: Option<String>,
    #[serde(default)]
    pub workdir_override: Option<String>,
    /// 对话级授权档位（`safe` / `askAll` / `auto`，创建时固化）。
    /// 不设则回落到全局 `~/.brewping/approval.json`（旧对话 / iOS 创建）。
    #[serde(default)]
    pub approval_mode: Option<String>,
    /// 调度指针：最近一条已提交且未终态的命令（恢复真相，方案 §2-A4）。
    #[serde(default)]
    pub latest_command_id: Option<String>,
    #[serde(default)]
    pub messages: Vec<TranscriptEntry>,
}

/// 列表页用的摘要（除 messages 外的元数据 + message_count）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationSummary {
    pub id: String,
    pub agent_id: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub title_source: Option<String>,
    pub created_at_ms: u64,
    pub updated_at_ms: u64,
    #[serde(default)]
    pub archived: bool,
    #[serde(default)]
    pub is_pinned: bool,
    #[serde(default)]
    pub model_override: Option<String>,
    #[serde(default)]
    pub model_provider_override: Option<String>,
    #[serde(default)]
    pub workdir_override: Option<String>,
    #[serde(default)]
    pub approval_mode: Option<String>,
    #[serde(default)]
    pub latest_command_id: Option<String>,
    pub message_count: usize,
}

/// 对话操作的领域错误（HTTP 层映射为状态码，Tauri 层映射为 Err 字符串）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConvError {
    NotFound,
    /// 归档对话不能直接激活（须先恢复）。
    Archived,
    /// 两段式删除：未归档不能删。
    NotArchived,
    /// 恢复时 workdir_override 指向的目录已不存在（错误文案 = 用户动作指引）。
    WorkdirMissing(String),
    /// 绑定 / 更改目录时目标不存在或不是目录（set_workdir 前置校验）。
    InvalidWorkdir(String),
}

impl std::fmt::Display for ConvError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConvError::NotFound => write!(f, "conversation not found"),
            ConvError::Archived => write!(f, "conversation is archived — restore it first"),
            ConvError::NotArchived => write!(f, "conversation must be archived before deletion"),
            ConvError::WorkdirMissing(dir) => write!(
                f,
                "workdir no longer exists: {dir} — change the working folder before restoring"
            ),
            ConvError::InvalidWorkdir(dir) => {
                write!(f, "workdir does not exist or is not a directory: {dir}")
            }
        }
    }
}

/// 绑定目录的统一归一化：trim 后空串视为不绑定（`None`）。
fn normalize_workdir(workdir: Option<&str>) -> Option<String> {
    workdir
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
}

/// 授权档位归一化：只认 `safe` / `askAll` / `auto`（与 `ApprovalMode::parse`
/// 同一份判定），其余一律视作「未设置」→ 回落全局默认。
fn normalize_approval_mode(mode: Option<&str>) -> Option<String> {
    mode.map(str::trim)
        .and_then(ApprovalMode::parse)
        .map(|m| m.as_str().to_string())
}

/// 索引文件结构（派生缓存，权威数据是逐对话文件）。
#[derive(Debug, Default, Serialize, Deserialize)]
struct IndexStored {
    #[serde(default)]
    conversations: Vec<ConversationSummary>,
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn new_id() -> String {
    format!("conv_{}", &uuid::Uuid::new_v4().to_string()[..8])
}

/// 每台机器一份对话仓库。
pub struct ConversationStore {
    dir: PathBuf,
    inner: Mutex<HashMap<String, Conversation>>,
}

impl ConversationStore {
    /// 使用默认目录 `~/.brewping/conversations`。
    pub fn new() -> Self {
        Self::with_dir(default_dir())
    }

    /// 指定目录构造（测试用）。加载后执行启动清理：
    /// 零消息对话删除（空对话从根上不存在）、悬空调度指针补「中断」条目。
    pub fn with_dir(dir: PathBuf) -> Self {
        let map = load_all(&dir);
        let map = startup_recover(map, &dir);
        Self {
            dir,
            inner: Mutex::new(map),
        }
    }

    fn conv_path(&self, id: &str) -> PathBuf {
        self.dir.join(format!("{id}.json"))
    }

    /// 把单个对话写盘 + 重写索引（调用方必须已释放 inner 锁）。
    fn persist(&self, conv: &Conversation) {
        let index = {
            let inner = self.inner.lock().expect("conversation store poisoned");
            write_conv_file(&self.conv_path(&conv.id), conv);
            summaries(&inner)
        };
        write_index(&self.dir.join("index.json"), &index);
    }

    /// 创建对话（不 spawn 任何进程、不写消息——用户消息永远走
    /// `append` 单一写入口，方案 §6.3）。
    pub fn create(&self, agent_id: &str) -> Conversation {
        self.create_with_options(agent_id, None, None)
    }

    /// 创建对话并绑定工作目录（目录历史分组的数据源）。
    /// 空串 / 纯空白视为不绑定（与前端「留空」语义一致）。
    pub fn create_with_workdir(&self, agent_id: &str, workdir: Option<&str>) -> Conversation {
        self.create_with_options(agent_id, workdir, None)
    }

    /// 创建对话（完整选项）：工作目录绑定 + 创建时固化的授权档位。
    ///
    /// 授权档位随对话**固化**而非共享一份全局值——这是「每个对话独立」的
    /// 前提：新对话继承草稿里当时选的档位，之后各对话互不影响。
    pub fn create_with_options(
        &self,
        agent_id: &str,
        workdir: Option<&str>,
        approval_mode: Option<&str>,
    ) -> Conversation {
        let ts = now_ms();
        let conv = Conversation {
            id: new_id(),
            agent_id: agent_id.to_string(),
            title: None,
            title_source: None,
            created_at_ms: ts,
            updated_at_ms: ts,
            archived: false,
            is_pinned: false,
            model_override: None,
            model_provider_override: None,
            workdir_override: normalize_workdir(workdir),
            approval_mode: normalize_approval_mode(approval_mode),
            latest_command_id: None,
            messages: Vec::new(),
        };
        {
            let mut inner = self.inner.lock().expect("conversation store poisoned");
            inner.insert(conv.id.clone(), conv.clone());
        }
        self.persist(&conv);
        conv
    }

    /// 更改既有对话的绑定目录（`None` = 解绑）。目录必须真实存在
    /// （执行 cwd 白名单之外的防护在 command_runner / folder_browser，
    /// 这里只挡“绑一个不存在的目录”这种明显误操作）。
    /// 与 rename 一致不 bump `updated_at_ms`（改目录不应拉动列表排序）。
    pub fn set_workdir(
        &self,
        conv_id: &str,
        workdir: Option<&str>,
    ) -> Result<ConversationSummary, ConvError> {
        let normalized = normalize_workdir(workdir);
        if let Some(dir) = &normalized {
            if !std::path::Path::new(dir).is_dir() {
                return Err(ConvError::InvalidWorkdir(dir.clone()));
            }
        }
        self.mutate(conv_id, |conv| conv.workdir_override = normalized)
    }

    /// 更改对话绑定的 Agent（对话级）。换 Agent 时**清除模型覆盖** ——
    /// 旧 Agent 的模型 id / provider 对新 Agent 没有意义，留着必然拼错参数。
    pub fn set_agent(
        &self,
        conv_id: &str,
        agent_id: &str,
    ) -> Result<ConversationSummary, ConvError> {
        let trimmed = agent_id.trim().to_string();
        self.mutate(conv_id, |conv| {
            conv.agent_id = trimmed;
            conv.model_override = None;
            conv.model_provider_override = None;
        })
    }

    /// 设置 / 清除对话的授权档位（`None` 或非法值 = 回落全局默认）。
    /// 授权是**对话级**设置：改一个对话不影响其它对话。
    pub fn set_approval_mode(
        &self,
        conv_id: &str,
        mode: Option<&str>,
    ) -> Result<ConversationSummary, ConvError> {
        let normalized = normalize_approval_mode(mode);
        self.mutate(conv_id, |conv| conv.approval_mode = normalized)
    }

    /// 设置 / 清除对话的模型覆盖（`None` = 回落该 Agent 的全局偏好）。
    /// model 与 provider 成对写入 —— 同名模型可能来自多个厂商，
    /// 只记 id 会让 opencode 的 `--model provider/model` 拼错。
    pub fn set_model(
        &self,
        conv_id: &str,
        model: Option<&str>,
        provider: Option<&str>,
    ) -> Result<ConversationSummary, ConvError> {
        let model = model
            .map(str::trim)
            .filter(|m| !m.is_empty())
            .map(|m| m.to_string());
        let provider = provider
            .map(str::trim)
            .filter(|p| !p.is_empty())
            .map(|p| p.to_string());
        self.mutate(conv_id, |conv| {
            conv.model_override = model;
            conv.model_provider_override = if conv.model_override.is_some() {
                provider
            } else {
                None
            };
        })
    }

    /// 对话级设置的统一写入口（workdir / model / approval 共用）。
    ///
    /// 「锁内改快照、锁外写盘」；刻意不 bump `updated_at_ms`
    /// ——改设置不应拉动列表排序（与 rename / 归档一致）。
    fn mutate<F>(&self, conv_id: &str, apply: F) -> Result<ConversationSummary, ConvError>
    where
        F: FnOnce(&mut Conversation),
    {
        let updated = {
            let inner = self.inner.lock().expect("conversation store poisoned");
            let conv = inner.get(conv_id).ok_or(ConvError::NotFound)?.clone();
            drop(inner);
            let mut conv = conv;
            apply(&mut conv);
            {
                let mut inner = self.inner.lock().expect("conversation store poisoned");
                if !inner.contains_key(conv_id) {
                    return Err(ConvError::NotFound);
                }
                inner.insert(conv_id.to_string(), conv.clone());
            }
            summary(&conv)
        };
        if let Some(conv) = self.get(conv_id) {
            self.persist(&conv);
        }
        Ok(updated)
    }

    pub fn get(&self, id: &str) -> Option<Conversation> {
        let inner = self.inner.lock().expect("conversation store poisoned");
        inner.get(id).cloned()
    }

    /// 列表（pinned 优先 + updated_at 降序，Lody §1.5 公式）。
    pub fn list(&self, include_archived: bool) -> Vec<ConversationSummary> {
        let inner = self.inner.lock().expect("conversation store poisoned");
        let mut list: Vec<ConversationSummary> = summaries(&inner)
            .into_iter()
            .filter(|s| include_archived || !s.archived)
            .collect();
        list.sort_by(|a, b| {
            rank(b).partial_cmp(&rank(a)).unwrap_or(std::cmp::Ordering::Equal)
        });
        list
    }

    /// 追加一条消息（写路径唯一出口）。首条 user 消息自动生成标题；
    /// `updated_at_ms` 单调写入。返回写入的条目（未知对话返回 None）。
    pub fn append(
        &self,
        conv_id: &str,
        role: &str,
        text: &str,
        source: Option<&str>,
        command_id: Option<&str>,
    ) -> Option<TranscriptEntry> {
        let ts = now_ms();
        let entry = TranscriptEntry {
            id: format!("msg_{}", &uuid::Uuid::new_v4().to_string()[..8]),
            role: role.to_string(),
            text: text.to_string(),
            source: source.map(|s| s.to_string()),
            command_id: command_id.map(|c| c.to_string()),
            created_at_ms: ts,
        };
        let updated = {
            let mut inner = self.inner.lock().expect("conversation store poisoned");
            let conv = inner.get_mut(conv_id)?;
            conv.messages.push(entry.clone());
            // 单调守卫：乱序事件不能把 updated_at 拉回去。
            conv.updated_at_ms = conv.updated_at_ms.max(ts);
            // 首条 user 消息自动命名（title_source = manual 永不覆盖）。
            if role == "user" && conv.title.is_none() {
                let t: String = text.trim().chars().take(32).collect();
                conv.title = Some(if text.trim().chars().count() > 32 {
                    format!("{t}…")
                } else {
                    t
                });
                conv.title_source = Some("auto".to_string());
            }
            conv.clone()
        };
        self.persist(&updated);
        Some(entry)
    }

    /// 修改标题 / 归档态 / 置顶。改名置 `title_source = "manual"`。
    /// 归档不改 `updated_at_ms`（重命名/归档不应拉动列表排序）。
    pub fn patch(
        &self,
        conv_id: &str,
        title: Option<&str>,
        archived: Option<bool>,
        pinned: Option<bool>,
    ) -> Result<ConversationSummary, ConvError> {
        let updated = {
            let inner = self.inner.lock().expect("conversation store poisoned");
            let conv = inner.get(conv_id).ok_or(ConvError::NotFound)?.clone();
            drop(inner);
            let mut conv = conv;
            if let Some(t) = title {
                let t = t.trim();
                if !t.is_empty() {
                    conv.title = Some(t.to_string());
                    conv.title_source = Some("manual".to_string());
                }
            }
            if let Some(a) = archived {
                conv.archived = a;
            }
            if let Some(p) = pinned {
                conv.is_pinned = p;
            }
            {
                let mut inner = self.inner.lock().expect("conversation store poisoned");
                if !inner.contains_key(conv_id) {
                    return Err(ConvError::NotFound);
                }
                inner.insert(conv_id.to_string(), conv.clone());
            }
            summary(&conv)
        };
        if let Some(conv) = self.get(conv_id) {
            self.persist(&conv);
        }
        Ok(updated)
    }

    /// 删除对话（两段式：仅归档态可删）。删转录文件 + 从内存移除；
    /// 该对话的 CommandEntry 不清理（轮询中的客户端拿到终态即可）。
    pub fn delete(&self, conv_id: &str) -> Result<(), ConvError> {
        {
            let mut inner = self.inner.lock().expect("conversation store poisoned");
            let conv = inner.get(conv_id).ok_or(ConvError::NotFound)?;
            if !conv.archived {
                return Err(ConvError::NotArchived);
            }
            inner.remove(conv_id);
            let index = summaries(&inner);
            drop(inner);
            write_index(&self.dir.join("index.json"), &index);
        }
        let _ = std::fs::remove_file(self.conv_path(conv_id));
        Ok(())
    }

    /// 写调度指针（只有 command_runner / 启动恢复可以调用）。
    pub fn set_latest_command(&self, conv_id: &str, command_id: Option<&str>) {
        let updated = {
            let mut inner = self.inner.lock().expect("conversation store poisoned");
            match inner.get_mut(conv_id) {
                Some(conv) => {
                    conv.latest_command_id = command_id.map(|c| c.to_string());
                    Some(conv.clone())
                }
                None => None,
            }
        };
        if let Some(conv) = updated {
            self.persist(&conv);
        }
    }

    /// 归档 / 删除前的可执行性检查（供调用方在 spawn_blocking 里探测目录）。
    pub fn workdir_missing(conv: &Conversation) -> Option<String> {
        let dir = conv.workdir_override.as_deref()?;
        if dir.is_empty() {
            return None;
        }
        if Path::new(dir).is_dir() {
            None
        } else {
            Some(dir.to_string())
        }
    }
}

impl Default for ConversationStore {
    fn default() -> Self {
        Self::new()
    }
}

fn rank(s: &ConversationSummary) -> f64 {
    if s.is_pinned {
        PINNED_RANK_OFFSET + s.updated_at_ms as f64
    } else {
        s.updated_at_ms as f64
    }
}

fn summary(conv: &Conversation) -> ConversationSummary {
    ConversationSummary {
        id: conv.id.clone(),
        agent_id: conv.agent_id.clone(),
        title: conv.title.clone(),
        title_source: conv.title_source.clone(),
        created_at_ms: conv.created_at_ms,
        updated_at_ms: conv.updated_at_ms,
        archived: conv.archived,
        is_pinned: conv.is_pinned,
        model_override: conv.model_override.clone(),
        model_provider_override: conv.model_provider_override.clone(),
        workdir_override: conv.workdir_override.clone(),
        approval_mode: conv.approval_mode.clone(),
        latest_command_id: conv.latest_command_id.clone(),
        message_count: conv.messages.len(),
    }
}

fn summaries(inner: &HashMap<String, Conversation>) -> Vec<ConversationSummary> {
    inner.values().map(summary).collect()
}

fn default_dir() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".brewping")
        .join("conversations")
}

/// 从目录加载全部对话文件。index.json 只是缓存：损坏 / 缺失时直接从
/// conv_*.json 重建（TC-CV-02：索引损坏不丢转录）。
fn load_all(dir: &Path) -> HashMap<String, Conversation> {
    let mut map = HashMap::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return map;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name_ok = path
            .file_name()
            .and_then(|n| n.to_str())
            .map(|n| n.starts_with("conv_") && n.ends_with(".json"))
            .unwrap_or(false);
        if !name_ok {
            continue;
        }
        if let Ok(data) = std::fs::read_to_string(&path) {
            if let Ok(conv) = serde_json::from_str::<Conversation>(&data) {
                map.insert(conv.id.clone(), conv);
            }
        }
    }
    map
}

/// 启动清理（方案 §8.8 / §6.1 兜底）：
/// 1. 零消息对话 → 删除文件（空对话从根上不存在）；
/// 2. `latest_command_id` 悬空（重启后 CommandStore 已清空）→
///    补一条 system「上次执行被中断」并清指针——指针是恢复真相。
fn startup_recover(mut map: HashMap<String, Conversation>, dir: &Path) -> HashMap<String, Conversation> {
    let mut changed: Vec<Conversation> = Vec::new();
    let mut removed: Vec<String> = Vec::new();
    for conv in map.values_mut() {
        if conv.messages.is_empty() {
            removed.push(conv.id.clone());
            continue;
        }
        if conv.latest_command_id.is_some() {
            let ts = now_ms();
            conv.messages.push(TranscriptEntry {
                id: format!("msg_{}", &uuid::Uuid::new_v4().to_string()[..8]),
                role: "system".to_string(),
                text: "上次执行被中断".to_string(),
                source: None,
                command_id: conv.latest_command_id.clone(),
                created_at_ms: ts,
            });
            conv.updated_at_ms = conv.updated_at_ms.max(ts);
            conv.latest_command_id = None;
            changed.push(conv.clone());
        }
    }
    for id in &removed {
        map.remove(id);
        let _ = std::fs::remove_file(dir.join(format!("{id}.json")));
    }
    if !changed.is_empty() || !removed.is_empty() {
        let index: Vec<ConversationSummary> = map.values().map(summary).collect();
        write_index(&dir.join("index.json"), &index);
        for conv in &changed {
            write_conv_file(&dir.join(format!("{}.json", conv.id)), conv);
        }
    }
    map
}

fn write_conv_file(path: &Path, conv: &Conversation) {
    if let Ok(data) = serde_json::to_string_pretty(conv) {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(path, data);
    }
}

fn write_index(path: &Path, index: &[ConversationSummary]) {
    let stored = IndexStored {
        conversations: index.to_vec(),
    };
    if let Ok(data) = serde_json::to_string_pretty(&stored) {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(path, data);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "brewping-convs-test-{tag}-{}",
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    // TC-CV-01  create → append ×3 → 重启（重新加载）后转录与顺序完整恢复
    #[test]
    fn create_append_reload_restores_transcript() {
        let dir = temp_dir("persist");
        let store = ConversationStore::with_dir(dir.clone());
        let conv = store.create("opencode");
        assert!(conv.id.starts_with("conv_"));
        store.append(&conv.id, "user", "第一问", None, None).unwrap();
        store
            .append(&conv.id, "assistant", "第一答", None, Some("cmd_1"))
            .unwrap();
        store.append(&conv.id, "user", "第二问", None, None).unwrap();

        let again = ConversationStore::with_dir(dir.clone());
        let loaded = again.get(&conv.id).expect("重启后应能恢复");
        assert_eq!(loaded.messages.len(), 3);
        assert_eq!(loaded.messages[0].role, "user");
        assert_eq!(loaded.messages[0].text, "第一问");
        assert_eq!(loaded.messages[1].role, "assistant");
        assert_eq!(loaded.messages[1].command_id.as_deref(), Some("cmd_1"));
        assert_eq!(loaded.messages[2].text, "第二问");
        let _ = std::fs::remove_dir_all(dir);
    }

    // TC-CV-02  index.json 损坏 → 从 conv 文件重建，转录不丢
    #[test]
    fn corrupted_index_is_rebuilt_from_conv_files() {
        let dir = temp_dir("broken-index");
        let store = ConversationStore::with_dir(dir.clone());
        let conv = store.create("opencode");
        store.append(&conv.id, "user", "hello", None, None).unwrap();
        drop(store);

        std::fs::write(dir.join("index.json"), "{ this is not json").unwrap();
        let again = ConversationStore::with_dir(dir.clone());
        let list = again.list(true);
        assert_eq!(list.len(), 1, "索引损坏必须能从转录文件重建");
        assert_eq!(list[0].id, conv.id);
        let _ = std::fs::remove_dir_all(dir);
    }

    // TC-CV-05  首条消息自动命名 + 手动重命名后不被覆盖
    #[test]
    fn auto_title_then_manual_never_overwritten() {
        let dir = temp_dir("title");
        let store = ConversationStore::with_dir(dir.clone());
        let conv = store.create("opencode");
        assert!(conv.title.is_none());

        store.append(&conv.id, "user", "帮我写一个很长的标题会自动截取", None, None).unwrap();
        let after = store.get(&conv.id).unwrap();
        assert_eq!(after.title_source.as_deref(), Some("auto"));
        assert!(after.title.as_deref().unwrap().starts_with("帮我写"));

        store.patch(&conv.id, Some("我的命名"), None, None).unwrap();
        let manual = store.get(&conv.id).unwrap();
        assert_eq!(manual.title.as_deref(), Some("我的命名"));
        assert_eq!(manual.title_source.as_deref(), Some("manual"));

        // 再来一条 user 消息：manual 命名不得被 auto 覆盖
        store.append(&conv.id, "user", "又一条消息", None, None).unwrap();
        let kept = store.get(&conv.id).unwrap();
        assert_eq!(kept.title.as_deref(), Some("我的命名"));
        let _ = std::fs::remove_dir_all(dir);
    }

    // TC-CV-09  乱序 append（旧时间戳后到）不回退 updated_at（模拟：手改文件时间戳）
    #[test]
    fn updated_at_is_monotonic() {
        let dir = temp_dir("mono");
        let store = ConversationStore::with_dir(dir.clone());
        let conv = store.create("opencode");
        store.append(&conv.id, "user", "a", None, None).unwrap();
        let after_first = store.get(&conv.id).unwrap().updated_at_ms;

        // 模拟乱序：把 updated_at 拉高再 append（append 不得拉低）
        {
            let mut inner = store.inner.lock().unwrap();
            inner.get_mut(&conv.id).unwrap().updated_at_ms = after_first + 10_000;
        }
        store.append(&conv.id, "user", "b", None, None).unwrap();
        let after_second = store.get(&conv.id).unwrap().updated_at_ms;
        assert!(after_second >= after_first + 10_000, "updated_at 不得回退");
        let _ = std::fs::remove_dir_all(dir);
    }

    // TC-CV-10  重启时 latest_command_id 悬空 → 补 system 中断条目并清指针
    #[test]
    fn dangling_command_pointer_recovers_with_system_entry() {
        let dir = temp_dir("dangling");
        let store = ConversationStore::with_dir(dir.clone());
        let conv = store.create("opencode");
        store.append(&conv.id, "user", "跑一半", None, None).unwrap();
        store.set_latest_command(&conv.id, Some("cmd_dead"));
        drop(store);

        // 直接改文件模拟"指针残留但命令已不存在"（重启后 CommandStore 必为空）
        let again = ConversationStore::with_dir(dir.clone());
        let loaded = again.get(&conv.id).unwrap();
        assert!(loaded.latest_command_id.is_none(), "指针应被清空");
        let last = loaded.messages.last().unwrap();
        assert_eq!(last.role, "system");
        assert_eq!(last.text, "上次执行被中断");
        let _ = std::fs::remove_dir_all(dir);
    }

    // TC-CV-06  启动清理：零消息对话直接删除，不留空壳
    #[test]
    fn empty_conversations_are_removed_on_startup() {
        let dir = temp_dir("empty");
        let store = ConversationStore::with_dir(dir.clone());
        let conv = store.create("opencode");
        assert!(dir.join(format!("{}.json", conv.id)).exists());
        drop(store);

        let again = ConversationStore::with_dir(dir.clone());
        assert!(again.get(&conv.id).is_none(), "空对话应被启动清理删除");
        assert!(!dir.join(format!("{}.json", conv.id)).exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    // TC-CV-04 / TC-CA-08  归档对话不能激活；未归档不能删；归档后可删
    #[test]
    fn archive_delete_lifecycle() {
        let dir = temp_dir("lifecycle");
        let store = ConversationStore::with_dir(dir.clone());
        let conv = store.create("opencode");
        store.append(&conv.id, "user", "x", None, None).unwrap();

        // 未归档 → 删除被拒
        assert_eq!(store.delete(&conv.id), Err(ConvError::NotArchived));

        // 归档 → 删除成功，文件消失
        store.patch(&conv.id, None, Some(true), None).unwrap();
        assert!(store.get(&conv.id).unwrap().archived);
        store.delete(&conv.id).unwrap();
        assert!(store.get(&conv.id).is_none());
        assert!(!dir.join(format!("{}.json", conv.id)).exists());

        // 未知对话 → NotFound
        assert_eq!(store.delete("conv_ghost"), Err(ConvError::NotFound));
        assert!(matches!(
            store.patch("conv_ghost", Some("t"), None, None),
            Err(ConvError::NotFound)
        ));
        let _ = std::fs::remove_dir_all(dir);
    }

    // TC-CL-01  列表排序：置顶优先（1e15 偏移），区内按 updated_at 降序
    #[test]
    fn list_sorts_pinned_first_then_recency() {
        let dir = temp_dir("sort");
        let store = ConversationStore::with_dir(dir.clone());
        let old = store.create("opencode");
        std::thread::sleep(std::time::Duration::from_millis(5));
        let new = store.create("opencode");
        std::thread::sleep(std::time::Duration::from_millis(5));
        let mid = store.create("opencode");

        // 不置顶：新 → 中 → 旧
        let order: Vec<String> = store.list(true).iter().map(|s| s.id.clone()).collect();
        assert_eq!(order, vec![mid.id.clone(), new.id.clone(), old.id.clone()]);

        // 置顶最旧的 → 恒在第一
        store.patch(&old.id, None, None, Some(true)).unwrap();
        let order: Vec<String> = store.list(true).iter().map(|s| s.id.clone()).collect();
        assert_eq!(order.first(), Some(&old.id), "置顶必须排最前");

        // 归档的默认不出现在列表里
        store.patch(&new.id, None, Some(true), None).unwrap();
        let order: Vec<String> = store.list(false).iter().map(|s| s.id.clone()).collect();
        assert!(!order.contains(&new.id));
        let all: Vec<String> = store.list(true).iter().map(|s| s.id.clone()).collect();
        assert!(all.contains(&new.id));
        let _ = std::fs::remove_dir_all(dir);
    }

    // TC-CV-08  恢复校验：workdir_override 指向的目录已删除 → WorkdirMissing
    #[test]
    fn restore_with_missing_workdir_is_rejected() {
        let dir = temp_dir("restore");
        let store = ConversationStore::with_dir(dir.clone());
        let conv = store.create("opencode");

        // 没设 override → 无阻碍
        assert!(ConversationStore::workdir_missing(&store.get(&conv.id).unwrap()).is_none());

        let gone = dir.join("gone-workdir");
        std::fs::create_dir_all(&gone).unwrap();
        store
            .patch(
                &conv.id,
                None,
                None,
                None,
            )
            .unwrap();
        // 直接写文件设置 override（patch 不暴露该字段，协议里由后续版本补）
        let mut raw = store.get(&conv.id).unwrap();
        raw.workdir_override = Some(gone.to_string_lossy().to_string());
        write_conv_file(&dir.join(format!("{}.json", conv.id)), &raw);
        {
            let mut inner = store.inner.lock().unwrap();
            inner.insert(conv.id.clone(), raw.clone());
        }
        std::fs::remove_dir_all(&gone).unwrap();

        assert_eq!(
            ConversationStore::workdir_missing(&store.get(&conv.id).unwrap()),
            Some(gone.to_string_lossy().to_string())
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    // TC-CV-10  创建时绑定目录：空串视为不绑定；持久化后可读回
    #[test]
    fn create_with_workdir_binds_and_persists() {
        let dir = temp_dir("cv10");
        std::fs::create_dir_all(&dir).unwrap();
        let store = ConversationStore::with_dir(dir.join("store"));

        let bound = store.create_with_workdir("opencode", Some(dir.to_string_lossy().as_ref()));
        assert_eq!(
            bound.workdir_override.as_deref(),
            Some(dir.to_string_lossy().as_ref())
        );
        let unbound_empty = store.create_with_workdir("opencode", Some("   "));
        assert!(unbound_empty.workdir_override.is_none(), "空白等于不绑定");
        let unbound = store.create("opencode");
        assert!(unbound.workdir_override.is_none());

        // 空对话会在下次启动时被 startup_recover 清理（TC-CV-07 的既定行为），
        // 所以落盘验证前先给 bound 追加一条消息让它"活过"重载。
        store.append(&bound.id, "user", "hello", None, None);

        // 落盘可复用（重开 store 后 summary 仍带目录）
        let again = ConversationStore::with_dir(dir.join("store"));
        let listed = again.list(false);
        let hit = listed.iter().find(|s| s.id == bound.id).unwrap();
        assert_eq!(
            hit.workdir_override.as_deref(),
            Some(dir.to_string_lossy().as_ref())
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    // TC-CV-11  set_workdir：改绑 / 解绑 / 不存在目录被拒；不改 updated_at
    #[test]
    fn set_workdir_updates_unbinds_and_rejects_missing() {
        let dir = temp_dir("cv11");
        let real = dir.join("real-dir");
        std::fs::create_dir_all(&real).unwrap();
        let store = ConversationStore::with_dir(dir.join("store"));
        let conv = store.create("opencode");
        let before = store.get(&conv.id).unwrap().updated_at_ms;

        // 改绑
        let s = store
            .set_workdir(&conv.id, Some(real.to_string_lossy().as_ref()))
            .unwrap();
        assert_eq!(
            s.workdir_override.as_deref(),
            Some(real.to_string_lossy().as_ref())
        );
        // 改目录不拉动排序
        assert_eq!(store.get(&conv.id).unwrap().updated_at_ms, before);
        // 解绑（None / 空串等价）
        let s = store.set_workdir(&conv.id, None).unwrap();
        assert!(s.workdir_override.is_none());
        let s = store.set_workdir(&conv.id, Some("")).unwrap();
        assert!(s.workdir_override.is_none());
        // 不存在的目录被拒
        let err = store
            .set_workdir(&conv.id, Some(dir.join("nope").to_string_lossy().as_ref()))
            .unwrap_err();
        assert!(matches!(err, ConvError::InvalidWorkdir(_)));
        // 未知对话
        assert!(matches!(
            store.set_workdir("conv_missing", None),
            Err(ConvError::NotFound)
        ));
        let _ = std::fs::remove_dir_all(dir);
    }

    // TC-CV-12  对话级授权档位：创建时固化、只改自己、可清除、可落盘
    #[test]
    fn approval_mode_is_per_conversation() {
        let dir = temp_dir("cv12");
        let store = ConversationStore::with_dir(dir.join("store"));

        // 创建时固化（草稿里选好的档位随首条消息落库）
        let a = store.create_with_options("opencode", None, Some("auto"));
        assert_eq!(a.approval_mode.as_deref(), Some("auto"));
        let b = store.create_with_options("opencode", None, Some("safe"));
        // 非法 / 空白档位一律视为未设置（回落全局默认）
        let bad = store.create_with_options("opencode", None, Some("yolo"));
        assert!(bad.approval_mode.is_none());
        assert!(store.create("opencode").approval_mode.is_none());

        // 只改 a：b 必须原样不动（"改一个对话全都跟着切换"的回归护栏）
        store.set_approval_mode(&a.id, Some("askAll")).unwrap();
        assert_eq!(
            store.get(&a.id).unwrap().approval_mode.as_deref(),
            Some("askAll")
        );
        assert_eq!(
            store.get(&b.id).unwrap().approval_mode.as_deref(),
            Some("safe")
        );

        // 改档位不拉动列表排序
        let before = store.get(&a.id).unwrap().updated_at_ms;
        store.set_approval_mode(&a.id, Some("auto")).unwrap();
        assert_eq!(store.get(&a.id).unwrap().updated_at_ms, before);

        // 落盘可复用：追加一条消息让它活过 startup_recover，重开后档位仍在
        store.append(&a.id, "user", "hi", None, None);
        let again = ConversationStore::with_dir(dir.join("store"));
        assert_eq!(
            again.get(&a.id).unwrap().approval_mode.as_deref(),
            Some("auto")
        );

        // 清除 → 回落全局默认
        let s = store.set_approval_mode(&a.id, None).unwrap();
        assert!(s.approval_mode.is_none());
        let s = store.set_approval_mode(&b.id, Some("bogus")).unwrap();
        assert!(s.approval_mode.is_none(), "非法档位一律视为未设置");

        assert!(matches!(
            store.set_approval_mode("conv_missing", Some("auto")),
            Err(ConvError::NotFound)
        ));
        let _ = std::fs::remove_dir_all(dir);
    }

    // TC-CV-13  对话级模型覆盖：model 与 provider 成对写入 / 成对清除
    #[test]
    fn model_override_pairs_model_with_provider() {
        let dir = temp_dir("cv13");
        let store = ConversationStore::with_dir(dir.join("store"));
        let conv = store.create("opencode");

        store
            .set_model(&conv.id, Some("claude-sonnet-4-5"), Some("anthropic"))
            .unwrap();
        let got = store.get(&conv.id).unwrap();
        assert_eq!(got.model_override.as_deref(), Some("claude-sonnet-4-5"));
        assert_eq!(got.model_provider_override.as_deref(), Some("anthropic"));

        // 只给 model（provider 空白）→ 不得残留上一个 provider，
        // 否则 opencode 会拼出错误的 `provider/model`
        store.set_model(&conv.id, Some("gpt-5"), Some("  ")).unwrap();
        let got = store.get(&conv.id).unwrap();
        assert_eq!(got.model_override.as_deref(), Some("gpt-5"));
        assert!(got.model_provider_override.is_none());

        // 清除覆盖（空串等价于 None）→ 两个字段一起清
        store.set_model(&conv.id, Some(""), None).unwrap();
        let got = store.get(&conv.id).unwrap();
        assert!(got.model_override.is_none());
        assert!(got.model_provider_override.is_none());

        assert!(matches!(
            store.set_model("conv_missing", Some("x"), None),
            Err(ConvError::NotFound)
        ));
        let _ = std::fs::remove_dir_all(dir);
    }
}
