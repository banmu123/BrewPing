//! 「获取文件夹」HTTP handler 层（Windows 端）。
//!
//! 3 个端点（方案 §3）：
//!   - `GET  /api/folders/roots`   根列表（home + 盘符），Bearer 免 nonce
//!   - `GET  /api/folders`         浏览目录，Bearer 免 nonce（只读）
//!   - `POST /api/agents/workdir`  设 / 清 Agent 工作目录，Bearer + Timestamp + Nonce
//!
//! Query 参数**全部声明为 `Option<String>` 手工解析**：若用 `Query<T>` 直接反序列化成
//! `bool`/`usize`，axum 在解析失败时返回 400 纯文本，违反 TC-HT-26
//! 「错误响应体必须是可解析的 JSON」契约（方案 §5.5）。

use axum::extract::{Query, State};
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::{Deserialize, Serialize};

use super::folder_browser;
use super::http_server::AppState;

/// 统一构造 JSON 响应（与 `http_server::json_response` 一致）。
fn json_response<T: Serialize>(status: u16, body: T) -> Response
where
    T: serde::Serialize,
{
    let status = axum::http::StatusCode::from_u16(status)
        .unwrap_or(axum::http::StatusCode::INTERNAL_SERVER_ERROR);
    (status, Json(body)).into_response()
}

// ─── GET /api/folders/roots ──────────────────────────────────────────────────

pub async fn handle_folder_roots(State(_state): State<AppState>) -> Response {
    json_response(200, folder_browser::list_roots())
}

// ─── GET /api/folders ────────────────────────────────────────────────────────

/// `limit` / `cursor` / `hidden` 一律是字符串：非法值降级为缺省（宽容策略），不报错。
#[derive(Debug, Deserialize)]
pub struct BrowseQuery {
    pub path: Option<String>,
    pub limit: Option<String>,
    pub cursor: Option<String>,
    pub hidden: Option<String>,
}

fn parse_bool_flag(raw: Option<&str>) -> bool {
    matches!(
        raw.map(str::trim),
        Some("1") | Some("true") | Some("TRUE") | Some("True") | Some("yes")
    )
}

fn parse_limit(raw: Option<&str>) -> Option<usize> {
    raw.and_then(|s| s.trim().parse::<usize>().ok())
}

pub async fn handle_browse_folder(
    State(_state): State<AppState>,
    Query(q): Query<BrowseQuery>,
) -> Response {
    let show_hidden = parse_bool_flag(q.hidden.as_deref());
    let limit = parse_limit(q.limit.as_deref());
    // 持有所有权再 move 进 spawn_blocking：借 q 的引用活不过本函数体。
    let cursor = q
        .cursor
        .as_deref()
        .map(str::trim)
        .filter(|c| !c.is_empty())
        .map(str::to_string);
    let path = q
        .path
        .as_deref()
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .map(str::to_string);

    // 文件系统 I/O 必须 spawn_blocking：慢盘 / 网络映射盘上的 read_dir、canonicalize
    // 是阻塞调用，直接跑会卡住整个 tokio runtime（表现为所有 API 一起变慢）。
    let result = tokio::task::spawn_blocking(move || {
        folder_browser::browse_directory(
            path.as_deref(),
            show_hidden,
            limit,
            cursor.as_deref(),
        )
    })
    .await;

    match result {
        Ok(Ok(browse)) => json_response(200, browse),
        Ok(Err(e)) => json_response(
            e.status(),
            serde_json::json!({ "success": false, "error": e.code() }),
        ),
        Err(e) => json_response(
            500,
            serde_json::json!({ "success": false, "error": format!("browse task failed: {}", e) }),
        ),
    }
}

// ─── POST /api/agents/workdir ────────────────────────────────────────────────

/// `path` 缺省 / null / 空串 = 清除该 Agent 的工作目录（回到"跟随进程当前目录"）。
#[derive(Debug, Deserialize)]
pub struct SetWorkdirBody {
    #[serde(rename = "agentId")]
    pub agent_id: String,
    #[serde(default)]
    pub path: Option<String>,
}

pub async fn handle_set_agent_workdir(
    State(state): State<AppState>,
    Json(body): Json<SetWorkdirBody>,
) -> Response {
    let agent_id = body.agent_id.trim().to_string();
    if agent_id.is_empty() {
        return json_response(
            400,
            serde_json::json!({
                "success": false,
                "error": "expected JSON body {\"agentId\": \"...\", \"path\": \"...\" | null}"
            }),
        );
    }

    if !super::agent_config::is_known_agent(&agent_id) {
        return json_response(
            404,
            serde_json::json!({ "success": false, "error": "unknown agent" }),
        );
    }

    // opencode 是 stub、从不 spawn 进程：设了 workdir 也不会生效。
    // 必须明确拒绝（方案 §2.3 事实 2），不能沉默接受让用户以为"时好时坏"。
    if agent_id == "opencode" {
        return json_response(
            400,
            serde_json::json!({
                "success": false,
                "error": "opencode does not support workdir yet"
            }),
        );
    }

    // 清除分支：幂等，重复清除也是成功
    let Some(path) = body.path.as_deref().map(str::trim).filter(|p| !p.is_empty()) else {
        state.workdir_prefs.set(&agent_id, None);
        log::info!("Workdir for '{}' cleared", agent_id);
        return json_response(
            200,
            serde_json::json!({ "success": true, "agentId": agent_id, "workdir": null }),
        );
    };

    // 设置分支：realpath + 目录校验 + UNC 拒绝 + 白名单，全在 folder_browser 里
    match folder_browser::validate_workdir(path) {
        Ok(dir) => {
            state.workdir_prefs.set(&agent_id, Some(&dir));
            log::info!("Workdir for '{}' set to {}", agent_id, dir);
            json_response(
                200,
                serde_json::json!({ "success": true, "agentId": agent_id, "workdir": dir }),
            )
        }
        Err(e) => json_response(
            e.status(),
            serde_json::json!({ "success": false, "error": e.code() }),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // TC-HT-31 的解析层单元用例：非法参数必须降级而不是报错
    #[test]
    fn bool_flag_parsing_is_strict_then_tolerant() {
        assert!(parse_bool_flag(Some("1")));
        assert!(parse_bool_flag(Some("true")));
        assert!(parse_bool_flag(Some("TRUE")));
        assert!(parse_bool_flag(Some("yes")));
        assert!(parse_bool_flag(Some(" yes ")), "前后空白应被 trim");
        assert!(!parse_bool_flag(Some("0")));
        assert!(!parse_bool_flag(Some("false")));
        assert!(!parse_bool_flag(Some("abc")));
        assert!(!parse_bool_flag(None));
    }

    #[test]
    fn limit_parsing_tolerates_garbage() {
        assert_eq!(parse_limit(Some("10")), Some(10));
        assert_eq!(parse_limit(Some(" 10 ")), Some(10));
        assert_eq!(parse_limit(Some("abc")), None, "非法 limit 应降级为 None");
        assert_eq!(parse_limit(Some("")), None);
        assert_eq!(parse_limit(None), None);
    }
}
