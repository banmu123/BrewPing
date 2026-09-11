//! 配对与请求鉴权。
//!
//! 背景：命令通道原来是**完全无鉴权**的明文 HTTP ——
//! 同一 Wi-Fi 下任何设备都能 POST `/api/message` 在用户电脑上执行命令。
//! 这既是真实安全漏洞，也容易被审核侧读成"可被滥用的远程控制工具"。
//!
//! 与 macOS `Sources/App/PairingStore.swift` 行为一致：
//!  1. **配对**：桌面端生成 6 位配对码（10 分钟有效、一次性），
//!     iPhone 输入后由 `POST /api/pair` 换取长期 token；
//!  2. **鉴权**：除 `/api/pair` 与 `/api/status`（只读健康检查）外，
//!     所有接口都要求 `Authorization: Bearer <token>`；
//!  3. **防重放**：写操作额外要求 `X-BrewPing-Timestamp` + `X-BrewPing-Nonce`，
//!     时间窗 120 秒，nonce 不可重复使用。
//!
//! token 是 32 字节系统随机数（64 位 hex），落在 `~/.brewping/pairing.json`（权限 0600）。
//! 没有引入任何自研加密算法。

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

use axum::http::HeaderMap;
use chrono::{DateTime, Duration, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// 鉴权结论。放在这里而不是抛错，是为了让 HTTP 调用点保持扁平。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuthDecision {
    Allowed,
    Denied { status: u16, error: String },
}

impl AuthDecision {
    pub fn is_allowed(&self) -> bool {
        matches!(self, AuthDecision::Allowed)
    }
}

/// 配对码有效期（秒）。
const CODE_VALIDITY_SECS: i64 = 600;
/// 允许的客户端时钟偏移（同时也就是重放窗口，秒）。
const REPLAY_WINDOW_SECS: i64 = 120;
/// nonce 记忆上限，防止长时间运行后无限增长。
const MAX_NONCES: usize = 2048;

struct Inner {
    pairing_code: Option<String>,
    pairing_code_issued_at: Option<DateTime<Utc>>,
    seen_nonces: HashMap<String, DateTime<Utc>>,
}

/// 配对与鉴权状态。进程内单例（`Arc<PairingStore>`）。
pub struct PairingStore {
    token: String,
    inner: Mutex<Inner>,
}

impl PairingStore {
    /// 使用默认路径 `~/.brewping/pairing.json` 构造（token 不存在时生成并落盘）。
    pub fn new() -> Self {
        Self::with_path(default_path())
    }

    /// 指定持久化路径构造。
    pub fn with_path(path: PathBuf) -> Self {
        Self {
            token: load_or_create_token(&path),
            inner: Mutex::new(Inner {
                pairing_code: None,
                pairing_code_issued_at: None,
                seen_nonces: HashMap::new(),
            }),
        }
    }

    /// 使用调用方给定的 token 构造，**不读写磁盘**。
    ///
    /// 用途：HTTP 层集成测试需要一个可预期的 token，
    /// 而真实路径下 token 是随机生成的，测试无法预先得知。
    pub fn with_fixed_token(token: impl Into<String>) -> Self {
        Self {
            token: token.into(),
            inner: Mutex::new(Inner {
                pairing_code: None,
                pairing_code_issued_at: None,
                seen_nonces: HashMap::new(),
            }),
        }
    }

    /// 当前长期 token。
    ///
    /// 配对流程内部使用（`exchange` 返回它），测试也用它拼鉴权头。
    pub fn token(&self) -> &str {
        &self.token
    }

    // ─── Pairing code ────────────────────────────────────────────────────────

    /// 生成（或复用未过期的）配对码，供桌面 UI / 托盘展示。
    pub fn issue_pairing_code(&self) -> String {
        let mut inner = self.inner.lock().expect("pairing store poisoned");
        if let (Some(code), Some(issued)) = (&inner.pairing_code, inner.pairing_code_issued_at) {
            if (Utc::now() - issued).num_seconds() < CODE_VALIDITY_SECS {
                return code.clone();
            }
        }
        let code = random_code();
        inner.pairing_code = Some(code.clone());
        inner.pairing_code_issued_at = Some(Utc::now());
        code
    }

    /// 强制作废当前配对码并立刻生成一个新的。
    ///
    /// 与 `issue_pairing_code()` 的区别：后者会复用未过期的码，前者无脑轮换。
    /// 用于 UI 上的"刷新"按钮 —— 用户想换码（比如怀疑泄露）时一键换。
    /// 已经换过 token 的设备不受影响（token 与码无关）。
    pub fn regenerate_pairing_code(&self) -> String {
        let mut inner = self.inner.lock().expect("pairing store poisoned");
        let code = random_code();
        inner.pairing_code = Some(code.clone());
        inner.pairing_code_issued_at = Some(Utc::now());
        code
    }

    /// 当前仍**有效**的配对码；未生成 / 已过期 / 已被消费时为 `None`。
    ///
    /// 用于界面启动时判断"要不要显示码"——不点开就不该存在，也不该在屏幕上停留。
    pub fn current_code(&self) -> Option<String> {
        let inner = self.inner.lock().expect("pairing store poisoned");
        let code = inner.pairing_code.clone()?;
        let issued = inner.pairing_code_issued_at?;
        if (Utc::now() - issued).num_seconds() < CODE_VALIDITY_SECS {
            Some(code)
        } else {
            None
        }
    }

    /// 当前配对码的过期时刻（序列化为 ISO8601 供前端显示）。
    pub fn pairing_code_expiry(&self) -> Option<DateTime<Utc>> {
        let inner = self.inner.lock().expect("pairing store poisoned");
        inner
            .pairing_code_issued_at
            .map(|issued| issued + Duration::seconds(CODE_VALIDITY_SECS))
    }

    /// 用配对码换 token。配对码一次性：换过立刻作废，避免被重复使用。
    pub fn exchange(&self, input: &str) -> Option<String> {
        let mut inner = self.inner.lock().expect("pairing store poisoned");
        let trimmed = input.trim();
        let code = inner.pairing_code.clone()?;
        let issued = inner.pairing_code_issued_at?;
        if (Utc::now() - issued).num_seconds() >= CODE_VALIDITY_SECS {
            return None;
        }
        if !constant_time_equals(trimmed, &code) {
            return None;
        }
        inner.pairing_code = None;
        inner.pairing_code_issued_at = None;
        Some(self.token.clone())
    }

    // ─── Authorization ───────────────────────────────────────────────────────

    /// 校验一个请求是否被允许。`method` 为 HTTP 方法，`headers` 为请求头。
    pub fn authorize(&self, method: &str, headers: &HeaderMap) -> AuthDecision {
        let raw_header = headers
            .get("authorization")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");

        let lowered = raw_header.to_ascii_lowercase();
        if raw_header.len() <= "Bearer ".len() || !lowered.starts_with("bearer ") {
            return AuthDecision::Denied {
                status: 401,
                error: "missing bearer token".to_string(),
            };
        }
        let presented = raw_header.get("Bearer ".len()..).unwrap_or("").trim();
        if !constant_time_equals(presented, &self.token) {
            return AuthDecision::Denied {
                status: 401,
                error: "invalid token".to_string(),
            };
        }

        // 只读请求不校验时间戳/nonce：GET 不产生副作用，重放无害，
        // 而移动端手表链路会频繁轮询状态，加 nonce 只会徒增开销。
        if method.eq_ignore_ascii_case("GET") {
            return AuthDecision::Allowed;
        }

        let raw_timestamp = headers
            .get("x-brewping-timestamp")
            .and_then(|v| v.to_str().ok());
        let nonce = headers
            .get("x-brewping-nonce")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");

        let Some(raw_timestamp) = raw_timestamp else {
            return AuthDecision::Denied {
                status: 401,
                error: "missing timestamp/nonce".to_string(),
            };
        };
        let Ok(timestamp) = raw_timestamp.parse::<f64>() else {
            return AuthDecision::Denied {
                status: 401,
                error: "missing timestamp/nonce".to_string(),
            };
        };
        if nonce.is_empty() {
            return AuthDecision::Denied {
                status: 401,
                error: "missing timestamp/nonce".to_string(),
            };
        }

        let now = Utc::now().timestamp() as f64;
        if (now - timestamp).abs() > REPLAY_WINDOW_SECS as f64 {
            return AuthDecision::Denied {
                status: 401,
                error: "stale request".to_string(),
            };
        }

        let mut inner = self.inner.lock().expect("pairing store poisoned");
        prune_nonces(&mut inner);
        let replayed = inner.seen_nonces.contains_key(nonce);
        if !replayed {
            inner.seen_nonces.insert(nonce.to_string(), Utc::now());
        }
        drop(inner);

        if replayed {
            AuthDecision::Denied {
                status: 401,
                error: "replayed nonce".to_string(),
            }
        } else {
            AuthDecision::Allowed
        }
    }
}

impl Default for PairingStore {
    fn default() -> Self {
        Self::new()
    }
}

// ─── Internals ───────────────────────────────────────────────────────────────

fn prune_nonces(inner: &mut Inner) {
    // 过期 nonce 直接清掉；若仍超过上限，按时间淘汰最旧的一半。
    let cutoff = Utc::now() - Duration::seconds(REPLAY_WINDOW_SECS);
    inner.seen_nonces.retain(|_, seen| *seen > cutoff);
    if inner.seen_nonces.len() <= MAX_NONCES {
        return;
    }
    let mut ordered: Vec<(String, DateTime<Utc>)> = inner
        .seen_nonces
        .iter()
        .map(|(k, v)| (k.clone(), *v))
        .collect();
    ordered.sort_by_key(|(_, seen)| *seen);
    for (key, _) in ordered.iter().take(ordered.len() / 2) {
        inner.seen_nonces.remove(key);
    }
}

/// 6 位十进制配对码（取自系统 CSPRNG）。
fn random_code() -> String {
    let uuid = Uuid::new_v4();
    let bytes = uuid.as_bytes();
    let value = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
    format!("{:06}", value % 1_000_000)
}

/// 32 字节系统随机数（64 位 hex）。
///
/// `Uuid::new_v4()` 的随机位来自操作系统 CSPRNG（getrandom），
/// 两个 UUID 拼起来正好 64 位 hex，与 macOS 端 `UInt8.random` 的强度同量级。
fn random_token() -> String {
    let mut token = String::with_capacity(64);
    while token.len() < 64 {
        token.push_str(&Uuid::new_v4().simple().to_string());
    }
    token.truncate(64);
    token
}

/// 定长比较，避免按字节提前返回泄露 token 前缀。
fn constant_time_equals(lhs: &str, rhs: &str) -> bool {
    let a = lhs.as_bytes();
    let b = rhs.as_bytes();
    if a.is_empty() || a.len() != b.len() {
        return false;
    }
    let mut diff: u8 = 0;
    for i in 0..a.len() {
        diff |= a[i] ^ b[i];
    }
    diff == 0
}

// ─── Token persistence ───────────────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize)]
struct Stored {
    token: String,
    #[serde(rename = "createdAt")]
    created_at: String,
}

/// 默认落盘位置：`~/.brewping/pairing.json`（与 device.json / approval.json 同目录）。
fn default_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".brewping")
        .join("pairing.json")
}

fn load_or_create_token(path: &PathBuf) -> String {
    if let Ok(data) = std::fs::read_to_string(path) {
        if let Ok(stored) = serde_json::from_str::<Stored>(&data) {
            if stored.token.len() >= 32 {
                return stored.token;
            }
        }
    }
    let token = random_token();
    let stored = Stored {
        token: token.clone(),
        created_at: Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true),
    };
    if let Ok(data) = serde_json::to_string_pretty(&stored) {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if std::fs::write(path, data).is_ok() {
            restrict_permissions(path);
        }
    }
    token
}

/// 只有当前用户可读：token 等价于这台电脑的命令执行权限。
#[cfg(unix)]
fn restrict_permissions(path: &PathBuf) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
}

/// Windows 上没有 POSIX 权限位，文件默认落在用户 profile 下（仅当前用户可访问）。
#[cfg(not(unix))]
fn restrict_permissions(_path: &PathBuf) {}

/// 为查询串做百分号编码（配对 URL 里的设备名可能含空格 / 中文）。
pub fn percent_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char)
            }
            _ => out.push_str(&format!("%{:02X}", byte)),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;

    fn temp_path(tag: &str) -> PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!("brewping-pairing-test-{}-{}.json", tag, Uuid::new_v4().simple()));
        path
    }

    fn headers(token: &str, method: &str) -> HeaderMap {
        let mut map = HeaderMap::new();
        map.insert("authorization", HeaderValue::from_str(&format!("Bearer {token}")).unwrap());
        if method != "GET" {
            map.insert(
                "x-brewping-timestamp",
                HeaderValue::from_str(&Utc::now().timestamp().to_string()).unwrap(),
            );
            map.insert(
                "x-brewping-nonce",
                HeaderValue::from_str(&Uuid::new_v4().to_string()).unwrap(),
            );
        }
        map
    }

    // TC-PS-01  token 生成：64 位小写 hex，且落盘后可复用
    #[test]
    fn token_is_persisted_and_stable() {
        let path = temp_path("token");
        let store = PairingStore::with_path(path.clone());
        let token = store.token().to_string();
        assert_eq!(token.len(), 64, "token 必须是 64 位 hex");
        assert!(token.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));

        let again = PairingStore::with_path(path.clone());
        assert_eq!(again.token(), token, "重复加载必须复用同一个 token");
        let _ = std::fs::remove_file(path);
    }

    // TC-PS-02  配对码格式：6 位十进制
    #[test]
    fn pairing_code_is_six_digits() {
        let path = temp_path("code");
        let store = PairingStore::with_path(path.clone());
        let code = store.issue_pairing_code();
        assert_eq!(code.len(), 6);
        assert!(code.chars().all(|c| c.is_ascii_digit()), "配对码必须是数字: {code}");
        let _ = std::fs::remove_file(path);
    }

    // TC-PS-03  issue 复用未过期码；regenerate 强制轮换
    #[test]
    fn issue_reuses_regenerate_rotates() {
        let path = temp_path("rotate");
        let store = PairingStore::with_path(path.clone());
        let first = store.issue_pairing_code();
        assert_eq!(store.issue_pairing_code(), first, "未过期时应复用");

        let rotated = store.regenerate_pairing_code();
        assert_ne!(rotated, first, "regenerate 必须轮换");
        assert_eq!(store.issue_pairing_code(), rotated);
        let _ = std::fs::remove_file(path);
    }

    // TC-PS-04  exchange：码正确则返回 token，且一次性
    #[test]
    fn exchange_is_one_shot() {
        let path = temp_path("exchange");
        let store = PairingStore::with_path(path.clone());
        let code = store.issue_pairing_code();
        let token = store.exchange(&code).expect("首次兑换应成功");
        assert_eq!(token, store.token());
        assert!(store.exchange(&code).is_none(), "配对码一次性，不能重复兑换");
        assert!(store.current_code().is_none(), "兑换后不应再有过期码");
        let _ = std::fs::remove_file(path);
    }

    // TC-PS-05  exchange：错误码 / 空码 / 未生成码一律失败
    #[test]
    fn exchange_rejects_wrong_or_missing_code() {
        let path = temp_path("wrongcode");
        let store = PairingStore::with_path(path.clone());
        assert!(store.exchange("000000").is_none(), "尚未生成码时不得兑换");

        let code = store.issue_pairing_code();
        let wrong = if code == "000000" { "111111" } else { "000000" };
        assert!(store.exchange(wrong).is_none());
        assert!(store.exchange("   ").is_none());
        // 错误尝试不应消费掉真码
        assert!(store.exchange(&code).is_some());
        let _ = std::fs::remove_file(path);
    }

    // TC-PS-06  exchange 前后空白容忍（对齐 macOS trimmingCharacters）
    #[test]
    fn exchange_trims_whitespace() {
        let path = temp_path("trim");
        let store = PairingStore::with_path(path.clone());
        let code = store.issue_pairing_code();
        assert!(store.exchange(&format!("  {code} \n")).is_some());
        let _ = std::fs::remove_file(path);
    }

    // TC-PS-07  鉴权：无头 / 非 Bearer / 错 token → 401
    #[test]
    fn authorize_rejects_missing_or_invalid_token() {
        let store = PairingStore::with_fixed_token("a".repeat(64));
        let empty = HeaderMap::new();
        assert_eq!(
            store.authorize("GET", &empty),
            AuthDecision::Denied { status: 401, error: "missing bearer token".into() }
        );

        let mut wrong_scheme = HeaderMap::new();
        wrong_scheme.insert("authorization", HeaderValue::from_static("Basic abcdef"));
        assert!(!store.authorize("GET", &wrong_scheme).is_allowed());

        let mut wrong_token = HeaderMap::new();
        wrong_token.insert(
            "authorization",
            HeaderValue::from_str(&format!("Bearer {}", "b".repeat(64))).unwrap(),
        );
        assert_eq!(
            store.authorize("GET", &wrong_token),
            AuthDecision::Denied { status: 401, error: "invalid token".into() }
        );
    }

    // TC-PS-08  鉴权：GET 只需 token，不需要时间戳 / nonce
    #[test]
    fn get_requires_only_token() {
        let token = "c".repeat(64);
        let store = PairingStore::with_fixed_token(token.clone());
        let mut map = HeaderMap::new();
        map.insert("authorization", HeaderValue::from_str(&format!("Bearer {token}")).unwrap());
        assert!(store.authorize("GET", &map).is_allowed());
    }

    // TC-PS-09  鉴权：写操作缺时间戳 / nonce → 401
    #[test]
    fn write_requires_timestamp_and_nonce() {
        let token = "d".repeat(64);
        let store = PairingStore::with_fixed_token(token.clone());
        let mut bare = HeaderMap::new();
        bare.insert("authorization", HeaderValue::from_str(&format!("Bearer {token}")).unwrap());
        assert_eq!(
            store.authorize("POST", &bare),
            AuthDecision::Denied { status: 401, error: "missing timestamp/nonce".into() }
        );
    }

    // TC-PS-10  鉴权：时间戳超出 120 秒窗口 → stale
    #[test]
    fn write_rejects_stale_timestamp() {
        let token = "e".repeat(64);
        let store = PairingStore::with_fixed_token(token.clone());
        let mut map = HeaderMap::new();
        map.insert("authorization", HeaderValue::from_str(&format!("Bearer {token}")).unwrap());
        map.insert(
            "x-brewping-timestamp",
            HeaderValue::from_str(&(Utc::now().timestamp() - 600).to_string()).unwrap(),
        );
        map.insert(
            "x-brewping-nonce",
            HeaderValue::from_str(&Uuid::new_v4().to_string()).unwrap(),
        );
        assert_eq!(
            store.authorize("POST", &map),
            AuthDecision::Denied { status: 401, error: "stale request".into() }
        );
    }

    // TC-PS-11  鉴权：nonce 不可重复使用（防重放）
    #[test]
    fn write_rejects_replayed_nonce() {
        let token = "f".repeat(64);
        let store = PairingStore::with_fixed_token(token.clone());
        let nonce = Uuid::new_v4().to_string();
        let build = || {
            let mut map = HeaderMap::new();
            map.insert("authorization", HeaderValue::from_str(&format!("Bearer {token}")).unwrap());
            map.insert(
                "x-brewping-timestamp",
                HeaderValue::from_str(&Utc::now().timestamp().to_string()).unwrap(),
            );
            map.insert("x-brewping-nonce", HeaderValue::from_str(&nonce).unwrap());
            map
        };
        assert!(store.authorize("POST", &build()).is_allowed(), "首次使用应放行");
        assert_eq!(
            store.authorize("POST", &build()),
            AuthDecision::Denied { status: 401, error: "replayed nonce".into() }
        );
    }

    // TC-PS-12  鉴权：合法写请求放行；GET 也用同一 token 正常放行
    #[test]
    fn authorize_allows_valid_writes() {
        let token = "0123456789abcdef".repeat(4);
        let store = PairingStore::with_fixed_token(token.clone());
        assert!(store.authorize("POST", &headers(&token, "POST")).is_allowed());
        assert!(store.authorize("GET", &headers(&token, "GET")).is_allowed());
    }

    // TC-PS-13  边界：定长比较对不同长度 / 空串一律 false
    #[test]
    fn constant_time_equals_edge_cases() {
        assert!(constant_time_equals("abc", "abc"));
        assert!(!constant_time_equals("abc", "abd"));
        assert!(!constant_time_equals("abc", "abcd"));
        assert!(!constant_time_equals("", ""));
        assert!(!constant_time_equals("", "a"));
    }

    // TC-PS-14  配对 URL 查询值编码：中文 / 空格 / & 必须转义
    #[test]
    fn percent_encode_escapes_reserved_chars() {
        assert_eq!(percent_encode("MacBook-Pro"), "MacBook-Pro");
        assert_eq!(percent_encode("a b"), "a%20b");
        assert_eq!(percent_encode("a&b=c"), "a%26b%3Dc");
        assert_eq!(percent_encode("电脑"), "%E7%94%B5%E8%84%91");
    }
}
