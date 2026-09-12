//! 授权网关：在命令进入 agent 之前判定「放行」还是「挂起等确认」。
//!
//! 与 macOS `Sources/App/ApprovalGate.swift` 行为一致：
//! - 三档模式 `safe`（默认）/ `askAll` / `auto`；
//!   档位**按对话**存放（`Conversation.approval_mode`，创建时固化），
//!   对话未设置时回落到本网关的全局默认值（`~/.brewping/approval.json`）；
//! - `safe` 命中危险模式且不在「总是允许」白名单里 → 挂起；
//! - pending 有效期 300 秒，超时自动作废（缺席不表态 ≠ 默认放行）；
//! - 「总是允许」只接受**已知的** danger code，拒绝未知 code 注入持久化；
//! - 全局档位与白名单落在 `~/.brewping/approval.json`（权限 0600）。
//!
//! 职责单一 —— 只管**判定与队列**，不执行命令。执行动作由调用方
//! （HTTP 层的 `/api/approvals/:id`，或桌面前端）拿到 `Resolution` 后完成，
//! 这样网关不会反向依赖命令执行层，避免循环引用。

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Mutex;

use chrono::{DateTime, Duration, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::danger_pattern::{self, DangerHit};

/// 授权模式：决定 agent 发起的操作在多大程度上需要用户确认。
///
/// - `Safe`（默认）：只拦截命中危险模式的操作，其余自动放行；
/// - `AskAll`：每一条命令都要确认（供极度谨慎的用户手动升级）；
/// - `Auto`：全程免确认，等同 Claude Code 的 `--dangerously-skip-permissions`。
///
/// 默认落在 `Safe`，是「默认谨慎 + 渐进放权」策略的锚点。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ApprovalMode {
    #[serde(rename = "safe")]
    Safe,
    #[serde(rename = "askAll")]
    AskAll,
    #[serde(rename = "auto")]
    Auto,
}

impl Default for ApprovalMode {
    fn default() -> Self {
        ApprovalMode::Safe
    }
}

impl ApprovalMode {
    /// 与 macOS `ApprovalMode.rawValue` / iOS `Mode.rawValue` 完全一致的字符串。
    pub fn as_str(&self) -> &'static str {
        match self {
            ApprovalMode::Safe => "safe",
            ApprovalMode::AskAll => "askAll",
            ApprovalMode::Auto => "auto",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "safe" => Some(ApprovalMode::Safe),
            "askAll" => Some(ApprovalMode::AskAll),
            "auto" => Some(ApprovalMode::Auto),
            _ => None,
        }
    }
}

/// 一条等待用户确认的命令。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingApproval {
    pub id: String,
    pub text: String,
    pub reasons: Vec<DangerHit>,
    /// 序列化为 ISO8601（秒级、UTC），与 macOS `ISO8601DateFormatter()` 输出一致。
    #[serde(serialize_with = "serialize_iso8601")]
    pub created_at: DateTime<Utc>,
}

fn serialize_iso8601<S: serde::Serializer>(
    value: &DateTime<Utc>,
    serializer: S,
) -> Result<S::Ok, S::Error> {
    serializer.serialize_str(&value.to_rfc3339_opts(SecondsFormat::Secs, true))
}

/// 判定结果。
pub enum Decision {
    /// 放行（auto 模式，或 safe 模式下未命中危险、或命中项已被「总是允许」）。
    Allow,
    /// 挂起，等用户确认。
    Pending(PendingApproval),
}

/// 用户对某条 pending 做出的决定。
#[derive(Debug, Clone)]
pub struct Resolution {
    /// "approve" | "deny" | "always_approve"
    pub action: String,
    /// approve / always_approve 时为挂起的命令正文。
    pub text: Option<String>,
    /// 用于 always_approve 时记入白名单。
    pub reason_codes: Vec<String>,
}

/// pending 有效期：超过后自动作废，避免"挂起没人管"的命令永久占坑。
const PENDING_TTL_SECS: i64 = 300;

#[derive(Default)]
struct Inner {
    mode: ApprovalMode,
    always_allow_codes: HashSet<String>,
    pending: HashMap<String, PendingApproval>,
}

/// 授权网关。进程内单例（`Arc<ApprovalGate>`），HTTP 层与桌面前端共用同一份状态。
pub struct ApprovalGate {
    inner: Mutex<Inner>,
    path: PathBuf,
}

impl ApprovalGate {
    /// 使用默认路径 `~/.brewping/approval.json` 构造。
    pub fn new() -> Self {
        Self::with_path(default_path())
    }

    /// 指定持久化路径构造（便于测试与多环境隔离）。
    pub fn with_path(path: PathBuf) -> Self {
        let inner = load_stored(&path);
        Self {
            inner: Mutex::new(inner),
            path,
        }
    }

    // ─── Mode ────────────────────────────────────────────────────────────────

    pub fn mode(&self) -> ApprovalMode {
        self.inner.lock().expect("approval gate poisoned").mode
    }

    pub fn set_mode(&self, new_mode: ApprovalMode) {
        let mut inner = self.inner.lock().expect("approval gate poisoned");
        inner.mode = new_mode;
        persist(&self.path, &inner);
    }

    /// 当前「总是允许」白名单（只读快照，测试与诊断用）。
    pub fn always_allow_codes(&self) -> HashSet<String> {
        self.inner
            .lock()
            .expect("approval gate poisoned")
            .always_allow_codes
            .clone()
    }

    // ─── Check ───────────────────────────────────────────────────────────────

    pub fn check(&self, text: &str) -> Decision {
        self.check_with(text, self.mode())
    }

    /// 按**指定档位**判定。
    ///
    /// 授权档位是**对话级**设置（`Conversation.approval_mode`，创建时固化），
    /// 调用方（HTTP 层）传入该对话的档位；对话未设置时回落到本网关的全局
    /// 默认值。白名单（always allow）保持全局一份 —— 它描述的是
    /// 「这台机器允许哪些危险模式」，与某个对话无关。
    pub fn check_with(&self, text: &str, mode: ApprovalMode) -> Decision {
        let mut inner = self.inner.lock().expect("approval gate poisoned");
        match mode {
            ApprovalMode::Auto => Decision::Allow,
            ApprovalMode::AskAll => {
                let reasons = vec![DangerHit {
                    code: "ask_all".to_string(),
                    detail: String::new(),
                }];
                Decision::Pending(make_pending(&mut inner, text, reasons))
            }
            ApprovalMode::Safe => {
                let hits: Vec<DangerHit> = danger_pattern::detect(text)
                    .into_iter()
                    .filter(|hit| !inner.always_allow_codes.contains(&hit.code))
                    .collect();
                if hits.is_empty() {
                    Decision::Allow
                } else {
                    Decision::Pending(make_pending(&mut inner, text, hits))
                }
            }
        }
    }

    // ─── Pending queue ───────────────────────────────────────────────────────

    pub fn pending_approvals(&self) -> Vec<PendingApproval> {
        let mut inner = self.inner.lock().expect("approval gate poisoned");
        prune_expired(&mut inner);
        let mut list: Vec<PendingApproval> = inner.pending.values().cloned().collect();
        list.sort_by_key(|a| a.created_at);
        list
    }

    pub fn pending_approval(&self, id: &str) -> Option<PendingApproval> {
        self.inner
            .lock()
            .expect("approval gate poisoned")
            .pending
            .get(id)
            .cloned()
    }

    // ─── Decide ──────────────────────────────────────────────────────────────

    /// 用户对某条 pending 做出决定。返回 `Resolution`，由调用方决定是否执行正文。
    /// 未知 id / 已过期 / 已处理 返回 `None`。
    pub fn decide(&self, id: &str, action: &str) -> Option<Resolution> {
        let mut inner = self.inner.lock().expect("approval gate poisoned");
        let approval = inner.pending.remove(id)?;
        let reason_codes: Vec<String> = approval.reasons.iter().map(|r| r.code.clone()).collect();

        match action {
            "deny" => Some(Resolution {
                action: "deny".to_string(),
                text: None,
                reason_codes,
            }),
            "approve" => Some(Resolution {
                action: "approve".to_string(),
                text: Some(approval.text),
                reason_codes,
            }),
            "always_approve" => {
                // 只白名单化"已知的" danger code，拒绝未知 code 注入持久化。
                let known = danger_pattern::known_codes();
                for code in &reason_codes {
                    if known.contains(code) {
                        inner.always_allow_codes.insert(code.clone());
                    }
                }
                persist(&self.path, &inner);
                Some(Resolution {
                    action: "always_approve".to_string(),
                    text: Some(approval.text),
                    reason_codes,
                })
            }
            // 与 macOS 一致：未知 action 也会消费掉这条 pending，并返回 None。
            _ => None,
        }
    }
}

impl Default for ApprovalGate {
    fn default() -> Self {
        Self::new()
    }
}

// ─── Internals ───────────────────────────────────────────────────────────────

fn make_pending(inner: &mut Inner, text: &str, reasons: Vec<DangerHit>) -> PendingApproval {
    let approval = PendingApproval {
        id: format!("apv_{}", Uuid::new_v4().simple()),
        text: text.to_string(),
        reasons,
        created_at: Utc::now(),
    };
    inner.pending.insert(approval.id.clone(), approval.clone());
    approval
}

fn prune_expired(inner: &mut Inner) {
    let cutoff = Utc::now() - Duration::seconds(PENDING_TTL_SECS);
    inner.pending.retain(|_, a| a.created_at > cutoff);
}

// ─── Persistence ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Stored {
    mode: ApprovalMode,
    #[serde(rename = "alwaysAllowCodes")]
    always_allow_codes: HashSet<String>,
}

/// 默认落盘位置：`~/.brewping/approval.json`（与 device.json / pairing.json 同目录）。
fn default_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".brewping")
        .join("approval.json")
}

fn load_stored(path: &PathBuf) -> Inner {
    let mut inner = Inner::default();
    let Ok(data) = std::fs::read_to_string(path) else {
        return inner;
    };
    let Ok(stored) = serde_json::from_str::<Stored>(&data) else {
        return inner;
    };
    // 白名单只保留仍然存在的已知 code，防止规则表变更后残留失效项。
    let known = danger_pattern::known_codes();
    inner.mode = stored.mode;
    inner.always_allow_codes = stored
        .always_allow_codes
        .into_iter()
        .filter(|code| known.contains(code))
        .collect();
    inner
}

fn persist(path: &PathBuf, inner: &Inner) {
    let stored = Stored {
        mode: inner.mode,
        always_allow_codes: inner.always_allow_codes.clone(),
    };
    let Ok(data) = serde_json::to_string_pretty(&stored) else {
        return;
    };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if std::fs::write(path, data).is_err() {
        return;
    }
    restrict_permissions(path);
}

/// 只有当前用户可读：approval.json 描述了这台机器的放行策略。
#[cfg(unix)]
fn restrict_permissions(path: &PathBuf) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
}

/// Windows 上没有 POSIX 权限位，文件默认落在用户 profile 下（仅当前用户可访问）。
#[cfg(not(unix))]
fn restrict_permissions(_path: &PathBuf) {}

#[cfg(test)]
mod tests {
    use super::*;

    /// 每个用例用独立临时文件，避免相互污染真实 `~/.brewping`。
    fn temp_path(tag: &str) -> PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!("brewping-approval-test-{}-{}.json", tag, Uuid::new_v4().simple()));
        path
    }

    fn gate(tag: &str) -> (ApprovalGate, PathBuf) {
        let path = temp_path(tag);
        (ApprovalGate::with_path(path.clone()), path)
    }

    // TC-AG-01  默认模式必须是 safe（默认谨慎）
    #[test]
    fn defaults_to_safe_mode() {
        let (g, path) = gate("default");
        assert_eq!(g.mode(), ApprovalMode::Safe);
        let _ = std::fs::remove_file(path);
    }

    // TC-AG-02  safe 模式下危险命令挂起，普通命令放行
    #[test]
    fn safe_mode_pends_only_dangerous_commands() {
        let (g, path) = gate("safe");
        assert!(matches!(g.check("帮我看看 README"), Decision::Allow));
        match g.check("rm -rf /") {
            Decision::Pending(a) => {
                assert!(a.id.starts_with("apv_"));
                assert_eq!(a.text, "rm -rf /");
                assert!(a.reasons.iter().any(|r| r.code == "rm_root"));
            }
            Decision::Allow => panic!("危险命令必须挂起"),
        }
        let _ = std::fs::remove_file(path);
    }

    // TC-AG-03  askAll 模式下任何命令都挂起，reason code 为 ask_all
    #[test]
    fn ask_all_mode_pends_everything() {
        let (g, path) = gate("askall");
        g.set_mode(ApprovalMode::AskAll);
        match g.check("ls -la") {
            Decision::Pending(a) => {
                assert_eq!(a.reasons.len(), 1);
                assert_eq!(a.reasons[0].code, "ask_all");
            }
            Decision::Allow => panic!("askAll 模式下必须挂起"),
        }
        let _ = std::fs::remove_file(path);
    }

    // TC-AG-04  auto 模式下一律放行，包括危险命令
    #[test]
    fn auto_mode_allows_everything() {
        let (g, path) = gate("auto");
        g.set_mode(ApprovalMode::Auto);
        assert!(matches!(g.check("rm -rf /"), Decision::Allow));
        assert!(g.pending_approvals().is_empty());
        let _ = std::fs::remove_file(path);
    }

    // TC-AG-05  approve 会返回正文并清空 pending
    #[test]
    fn approve_returns_text_and_clears_pending() {
        let (g, path) = gate("approve");
        let id = match g.check("sudo reboot") {
            Decision::Pending(a) => a.id,
            Decision::Allow => panic!("应挂起"),
        };
        assert_eq!(g.pending_approvals().len(), 1);

        let r = g.decide(&id, "approve").expect("approve 应成功");
        assert_eq!(r.action, "approve");
        assert_eq!(r.text.as_deref(), Some("sudo reboot"));
        assert!(g.pending_approvals().is_empty(), "处理后 pending 必须清空");
        let _ = std::fs::remove_file(path);
    }

    // TC-AG-06  deny 不返回正文
    #[test]
    fn deny_returns_no_text() {
        let (g, path) = gate("deny");
        let id = match g.check("git reset --hard HEAD~3") {
            Decision::Pending(a) => a.id,
            Decision::Allow => panic!("应挂起"),
        };
        let r = g.decide(&id, "deny").expect("deny 应成功");
        assert_eq!(r.action, "deny");
        assert!(r.text.is_none());
        assert_eq!(r.reason_codes, vec!["git_reset_hard".to_string()]);
        let _ = std::fs::remove_file(path);
    }

    // TC-AG-07  always_approve 写入白名单并持久化，同一 code 不再挂起
    #[test]
    fn always_approve_persists_whitelist() {
        let (g, path) = gate("always");
        let id = match g.check("sudo apt update") {
            Decision::Pending(a) => a.id,
            Decision::Allow => panic!("应挂起"),
        };
        let r = g.decide(&id, "always_approve").expect("always_approve 应成功");
        assert_eq!(r.action, "always_approve");
        assert!(g.always_allow_codes().contains("sudo"));

        // 重新加载同一个文件，白名单必须还在
        let reloaded = ApprovalGate::with_path(path.clone());
        assert!(reloaded.always_allow_codes().contains("sudo"));
        assert!(
            matches!(reloaded.check("sudo apt update"), Decision::Allow),
            "白名单内的 code 不应再挂起"
        );
        let _ = std::fs::remove_file(path);
    }

    // TC-AG-08  ask_all 不是已知 code，绝不允许被写入白名单
    #[test]
    fn always_approve_rejects_unknown_code() {
        let (g, path) = gate("unknown");
        g.set_mode(ApprovalMode::AskAll);
        let id = match g.check("hello") {
            Decision::Pending(a) => a.id,
            Decision::Allow => panic!("应挂起"),
        };
        g.decide(&id, "always_approve").expect("应返回 resolution");
        assert!(
            !g.always_allow_codes().contains("ask_all"),
            "ask_all 不是已知 danger code，不得进入白名单"
        );
        let _ = std::fs::remove_file(path);
    }

    // TC-AG-09  边界：未知 id / 旧的 id 返回 None
    #[test]
    fn decide_unknown_id_returns_none() {
        let (g, path) = gate("unknownid");
        assert!(g.decide("apv_does_not_exist", "approve").is_none());
        // 同一条 pending 只能被消费一次
        let id = match g.check("chmod 777 /") {
            Decision::Pending(a) => a.id,
            Decision::Allow => panic!("应挂起"),
        };
        assert!(g.decide(&id, "approve").is_some());
        assert!(g.decide(&id, "approve").is_none(), "重复处理应返回 None");
        let _ = std::fs::remove_file(path);
    }

    // TC-AG-10  边界：未知 action 消费 pending 且不返回 resolution（对齐 macOS）
    #[test]
    fn decide_unknown_action_consumes_pending() {
        let (g, path) = gate("unknownaction");
        let id = match g.check("dd if=/dev/zero of=/dev/sda") {
            Decision::Pending(a) => a.id,
            Decision::Allow => panic!("应挂起"),
        };
        assert!(g.decide(&id, "banana").is_none());
        assert!(g.pending_approvals().is_empty());
        let _ = std::fs::remove_file(path);
    }

    // TC-AG-11  模式持久化：切换后重新加载仍是新模式
    #[test]
    fn mode_is_persisted() {
        let (g, path) = gate("modepersist");
        g.set_mode(ApprovalMode::AskAll);
        let reloaded = ApprovalGate::with_path(path.clone());
        assert_eq!(reloaded.mode(), ApprovalMode::AskAll);
        let _ = std::fs::remove_file(path);
    }

    // TC-AG-12  契约：mode 的字符串形式必须与 iOS 端一致
    #[test]
    fn mode_raw_values_match_ios_contract() {
        assert_eq!(ApprovalMode::Safe.as_str(), "safe");
        assert_eq!(ApprovalMode::AskAll.as_str(), "askAll");
        assert_eq!(ApprovalMode::Auto.as_str(), "auto");
        assert_eq!(ApprovalMode::parse("askAll"), Some(ApprovalMode::AskAll));
        assert_eq!(ApprovalMode::parse("bogus"), None);

        let json = serde_json::to_value(ApprovalMode::AskAll).unwrap();
        assert_eq!(json, serde_json::json!("askAll"));
    }

    // TC-AG-13  契约：pending 序列化字段名与 iOS 解码结构一致
    #[test]
    fn pending_serializes_with_expected_keys() {
        let (g, path) = gate("serialize");
        let approval = match g.check("DROP TABLE users;") {
            Decision::Pending(a) => a,
            Decision::Allow => panic!("应挂起"),
        };
        let v = serde_json::to_value(&approval).unwrap();
        assert!(v["id"].is_string());
        assert_eq!(v["text"], "DROP TABLE users;");
        assert!(v["createdAt"].is_string());
        assert_eq!(v["reasons"][0]["code"], "drop_table");
        assert_eq!(v["reasons"][0]["detail"], "DROP TABLE");
        assert!(v.get("created_at").is_none(), "不应输出 snake_case 键名");
        // createdAt 必须是秒级 UTC ISO8601，形如 2026-09-11T12:00:00Z
        let created = v["createdAt"].as_str().unwrap();
        assert!(created.ends_with('Z'), "createdAt 应以 Z 结尾: {created}");
        assert!(chrono::DateTime::parse_from_rfc3339(created).is_ok());
        let _ = std::fs::remove_file(path);
    }

    // TC-AG-14  过期 pending 在列表查询时被清理（缺席不表态 ≠ 默认放行）
    #[test]
    fn expired_pending_is_pruned() {
        let (g, path) = gate("prune");
        let id = match g.check("rm -rf /tmp/x") {
            Decision::Pending(a) => a.id,
            Decision::Allow => panic!("应挂起"),
        };
        // 直接构造一条已过期的 pending，模拟"挂起半天没人管"
        {
            let mut inner = g.inner.lock().unwrap();
            if let Some(a) = inner.pending.get_mut(&id) {
                a.created_at = Utc::now() - Duration::seconds(PENDING_TTL_SECS + 60);
            }
        }
        assert!(g.pending_approvals().is_empty(), "过期 pending 应被清理");
        assert!(g.decide(&id, "approve").is_none(), "过期 pending 不得被执行");
        let _ = std::fs::remove_file(path);
    }

    // TC-AG-15  对话级档位：check_with 用「传入的」档位判定，与网关全局档位解耦
    #[test]
    fn check_with_uses_the_passed_mode() {
        let (g, path) = gate("checkwith");
        // 网关全局是 safe（默认），但对话 A 固化了 auto → 危险命令放行
        assert!(matches!(
            g.check_with("rm -rf /", ApprovalMode::Auto),
            Decision::Allow
        ));
        // 对话 B 固化了 askAll → 连普通命令也挂起
        assert!(matches!(
            g.check_with("ls -la", ApprovalMode::AskAll),
            Decision::Pending(_)
        ));
        // 显式传档位不得改动网关自身的全局档位
        assert_eq!(g.mode(), ApprovalMode::Safe);
        // 全局档位被改后，显式入参依然是唯一依据
        g.set_mode(ApprovalMode::Auto);
        assert!(matches!(
            g.check_with("rm -rf /", ApprovalMode::Safe),
            Decision::Pending(_)
        ));
        // 无参 check 仍走全局档位（旧行为不变）
        assert!(matches!(g.check("rm -rf /"), Decision::Allow));
        let _ = std::fs::remove_file(path);
    }
}
