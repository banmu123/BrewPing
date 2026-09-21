//! 多对话 HTTP 端点（方案 §5.1：对齐 folder_api.rs 的拆分方式）。
//!
//! 6 条路由，全部自动落入 `auth_middleware` 保护：
//! | 方法   | 路径                              | 语义                          |
//! |--------|-----------------------------------|-------------------------------|
//! | GET    | /api/conversations                | 列表（pinned 优先+最新活动）  |
//! | POST   | /api/conversations                | 物化：{agentId?, firstMessage?} |
//! | GET    | /api/conversations/{id}           | 完整转录                      |
//! | PATCH  | /api/conversations/{id}           | {title?, archived?, pinned?}  |
//! | DELETE | /api/conversations/{id}           | 删除（仅归档态可删）          |
//! | POST   | /api/conversations/{id}/activate  | 切换为当前对话                |

use axum::{
    extract::{Path, Query, State},
    response::Response,
    Json,
};
use serde::Deserialize;

use super::command_runner;
use super::conversation_store::ConvError;
use super::http_server::{json_response, submit_command, AppState};

#[derive(Deserialize, Default)]
pub struct ListConversationsQuery {
    #[serde(rename = "includeArchived", default)]
    include_archived: Option<String>,
}

/// GET /api/conversations
pub async fn handle_list_conversations(
    State(state): State<AppState>,
    Query(query): Query<ListConversationsQuery>,
) -> Response {
    let include_archived = matches!(
        query.include_archived.as_deref(),
        Some("true") | Some("1") | Some("yes")
    );
    let conversations = state.conversations.list(include_archived);
    json_response(
        200,
        serde_json::json!({ "success": true, "conversations": conversations }),
    )
}

#[derive(Deserialize)]
pub struct CreateConversationBody {
    #[serde(rename = "agentId", default)]
    agent_id: Option<String>,
    #[serde(default)]
    title: Option<String>,
    /// 首条消息：非空时创建后立即走 submit_command 执行（用户条目由
    /// submit 流程唯一写入，避免双写）。
    #[serde(rename = "firstMessage", default)]
    first_message: Option<String>,
    /// 创建时绑定的工作目录（空 = 不绑定；与桌面 Tauri `send_command.workdir` 对齐）。
    #[serde(rename = "workdir", default)]
    workdir: Option<String>,
    /// 创建时固化的授权档位（safe / askAll / auto；缺省 = 未设置，回落全局默认）。
    /// 授权是**对话级**设置，与桌面 Tauri `send_command.approvalMode` 对齐。
    #[serde(rename = "approvalMode", default)]
    approval_mode: Option<String>,
}

/// POST /api/conversations —— 物化一个对话。
/// 当前无 active 对话时自动激活（桌面 UI 的草稿发送走 Tauri `send_command`，
/// 同样在无对话时创建并激活）。
pub async fn handle_create_conversation(
    State(state): State<AppState>,
    Json(body): Json<CreateConversationBody>,
) -> Response {
    let fallback_agent = state.default_agent.read().await.clone();
    let agent_id = body
        .agent_id
        .filter(|s| !s.trim().is_empty())
        .unwrap_or(fallback_agent);

    // agentId 必须真实存在（防止手滑把消息发进不存在的 agent）
    {
        let agents = state.agents.read().await;
        if !agents.iter().any(|a| a.id == agent_id) {
            return json_response(
                400,
                serde_json::json!({ "success": false, "error": format!("unknown agent: {agent_id}") }),
            );
        }
    }

    let conv = state.conversations.create_with_options(
        &agent_id,
        body.workdir.as_deref(),
        body.approval_mode.as_deref(),
    );

    // 无 active 时激活（有 active 不动——切换必须显式，掩盖心智的问题见方案 §6.4）。
    {
        let mut active = state.active_conversation_id.write().await;
        if active.is_none() {
            *active = Some(conv.id.clone());
        }
    }
    command_runner::emit(
        &state,
        "conversations-changed",
        serde_json::json!({ "id": conv.id }),
    );

    // 首条消息 → 立即提交执行（唯一写路径：submit 里 append user 条目）。
    // 与 macOS `conversationCreateResponse` 同款契约：submitStatus（HTTP 状态码
    // 语义）必给；命令真的进入执行时再补 commandId / status，pending_approval
    // 时补 status="pending_approval" + approval 对象（客户端据此弹授权确认）。
    let first_message = body.first_message.unwrap_or_default();
    let mut submission: Option<(u16, Option<String>, Option<String>)> = None;
    let mut pending_approval: Option<super::approval_gate::PendingApproval> = None;
    if !first_message.trim().is_empty() {
        // 授权门卫必须在 submit 之前（与 POST /api/message 同一判定点）：
        // 没有它，safe/askAll 档位下首条消息会绕过确认直接执行。
        let effective_mode = conv
            .approval_mode
            .as_deref()
            .and_then(super::approval_gate::ApprovalMode::parse)
            .unwrap_or_else(|| state.approval.mode());
        match state
            .approval
            .check_with(&first_message, effective_mode, Some(&conv.id))
        {
            super::approval_gate::Decision::Pending(approval) => {
                pending_approval = Some(approval);
                submission = Some((200, None, Some("pending_approval".to_string())));
            }
            super::approval_gate::Decision::Allow => {
                match submit_command(&state, &first_message, Some(&conv.id), None, Some("ios"), None).await {
                    Ok(response) => {
                        submission = Some((
                            200,
                            response.command_id.clone(),
                            response.status.clone(),
                        ));
                    }
                    Err(status) => {
                        // 创建本身已成功；提交失败（如授权挂起之外的 4xx）不算创建失败。
                        log::warn!("first message submit failed (HTTP {})", status.as_u16());
                        submission = Some((status.as_u16(), None, None));
                    }
                }
            }
        }
    }

    let mut payload = serde_json::json!({
        "success": true,
        "conversation": state.conversations.get(&conv.id),
    });
    if let Some((submit_status, command_id, status)) = submission {
        payload["submitStatus"] = serde_json::json!(submit_status);
        if let Some(id) = command_id {
            payload["commandId"] = serde_json::Value::String(id);
        }
        if let Some(s) = status {
            payload["status"] = serde_json::Value::String(s);
        }
        // 与 macOS HTTPAPI 一致：pending 时把 approval 对象随响应带回，
        // 客户端不用再查 GET /api/approvals 就能直接弹确认窗。
        if let Some(approval) = pending_approval {
            payload["approval"] = serde_json::to_value(&approval)
                .unwrap_or(serde_json::Value::Null);
        }
    }
    json_response(200, payload)
}

/// GET /api/conversations/{id} —— 完整转录。
pub async fn handle_get_conversation(
    Path(id): Path<String>,
    State(state): State<AppState>,
) -> Response {
    match state.conversations.get(&id) {
        Some(conv) => json_response(
            200,
            serde_json::json!({ "success": true, "conversation": conv }),
        ),
        None => json_response(
            404,
            serde_json::json!({ "success": false, "error": "conversation not found" }),
        ),
    }
}

#[derive(Deserialize)]
pub struct PatchConversationBody {
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    archived: Option<bool>,
    #[serde(default)]
    pinned: Option<bool>,
    /// 更改绑定目录（`null` 不动；要解绑传空串——JSON null 与缺省不可分，
    /// 与 Tauri 侧 `Option<String>` 语义对齐）。
    #[serde(default)]
    workdir: Option<String>,
    /// 切换对话绑定的 Agent（对话级）。换 Agent 会清除该对话的模型覆盖
    /// （旧 Agent 的模型对新 Agent 无意义）。
    #[serde(rename = "agentId", default)]
    agent_id: Option<String>,
    /// 对话级授权档位（safe / askAll / auto；空串 = 清除，回落全局默认）。
    #[serde(rename = "approvalMode", default)]
    approval_mode: Option<String>,
    /// 对话级模型覆盖：与 `modelProviderId` 成对提交（同名模型可来自多个
    /// 厂商，opencode 需要 `provider/model` 复合限定名）。空串 = 清除覆盖。
    #[serde(rename = "modelId", default)]
    model_id: Option<String>,
    #[serde(rename = "modelProviderId", default)]
    model_provider_id: Option<String>,
}

fn conv_error_response(err: ConvError) -> Response {
    let status = match &err {
        ConvError::NotFound => 404,
        ConvError::Archived => 409,
        ConvError::NotArchived => 409,
        ConvError::WorkdirMissing(_) => 409,
        ConvError::InvalidWorkdir(_) => 400,
    };
    json_response(status, serde_json::json!({ "success": false, "error": err.to_string() }))
}

/// PATCH /api/conversations/{id} —— 改名 / 归档 / 恢复 / 置顶。
pub async fn handle_patch_conversation(
    Path(id): Path<String>,
    State(state): State<AppState>,
    Json(body): Json<PatchConversationBody>,
) -> Response {
    if state.conversations.get(&id).is_none() {
        return conv_error_response(ConvError::NotFound);
    }

    // 归档前置检查：存在 queued/working 命令 → 409（等命令终态再归档）。
    if body.archived == Some(true) {
        if let Some(conv) = state.conversations.get(&id) {
            if let Some(cmd) = &conv.latest_command_id {
                if state.command_store.is_in_flight(cmd).await {
                    return json_response(
                        409,
                        serde_json::json!({
                            "success": false,
                            "error": "conversation has a command in flight — wait for it to finish"
                        }),
                    );
                }
            }
        }
    }

    // 恢复前置检查：workdir_override 目录必须仍存在（方案 §2-A8）。
    if body.archived == Some(false) {
        if let Some(conv) = state.conversations.get(&id) {
            if let Some(dir) = super::conversation_store::ConversationStore::workdir_missing(&conv) {
                return conv_error_response(ConvError::WorkdirMissing(dir));
            }
        }
    }

    // 绑定目录更改：走 set_workdir（含目录存在性校验；空串 = 解绑）。
    if let Some(workdir) = &body.workdir {
        if let Err(err) = state.conversations.set_workdir(&id, Some(workdir.as_str())) {
            return conv_error_response(err);
        }
    }

    // 切换对话的 Agent：必须真实存在（与 create 同一套校验）；
    // 换 Agent 时后端自动清除该对话的模型覆盖。
    if let Some(agent_id) = body.agent_id.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        {
            let agents = state.agents.read().await;
            if !agents.iter().any(|a| a.id == agent_id) {
                return json_response(
                    400,
                    serde_json::json!({
                        "success": false,
                        "error": format!("unknown agent: {agent_id}")
                    }),
                );
            }
        }
        if let Err(err) = state.conversations.set_agent(&id, agent_id) {
            return conv_error_response(err);
        }
    }

    // 对话级授权档位（空串 = 清除覆盖，回落全局默认）。
    if let Some(mode) = &body.approval_mode {
        if let Err(err) = state.conversations.set_approval_mode(&id, Some(mode.as_str())) {
            return conv_error_response(err);
        }
    }

    // 对话级模型覆盖（modelId 空串 = 清除；与 modelProviderId 成对）。
    if let Some(model_id) = &body.model_id {
        let provider = body.model_provider_id.as_deref().unwrap_or("");
        if let Err(err) = state.conversations.set_model(&id, Some(model_id.as_str()), Some(provider))
        {
            return conv_error_response(err);
        }
    }

    match state
        .conversations
        .patch(&id, body.title.as_deref(), body.archived, body.pinned)
    {
        Ok(summary) => {
            // 归档 active 对话 → active 置空（landing 态），不自动跳转。
            if body.archived == Some(true) {
                let mut active = state.active_conversation_id.write().await;
                if active.as_deref() == Some(id.as_str()) {
                    *active = None;
                    command_runner::emit(&state, "active-conversation-changed", serde_json::json!(null));
                }
            }
            command_runner::emit(
                &state,
                "conversations-changed",
                serde_json::json!({ "id": id }),
            );
            json_response(
                200,
                serde_json::json!({ "success": true, "conversation": summary }),
            )
        }
        Err(err) => conv_error_response(err),
    }
}

/// DELETE /api/conversations/{id} —— 仅归档态可删（两段式，方案 §2-A7）。
pub async fn handle_delete_conversation(
    Path(id): Path<String>,
    State(state): State<AppState>,
) -> Response {
    match state.conversations.delete(&id) {
        Ok(()) => {
            command_runner::emit(
                &state,
                "conversations-changed",
                serde_json::json!({ "id": id }),
            );
            json_response(200, serde_json::json!({ "success": true }))
        }
        Err(err) => conv_error_response(err),
    }
}

/// POST /api/conversations/{id}/activate —— 切换为当前对话。
pub async fn handle_activate_conversation(
    Path(id): Path<String>,
    State(state): State<AppState>,
) -> Response {
    let Some(conv) = state.conversations.get(&id) else {
        return conv_error_response(ConvError::NotFound);
    };
    if conv.archived {
        return conv_error_response(ConvError::Archived);
    }
    {
        let mut active = state.active_conversation_id.write().await;
        *active = Some(id.clone());
    }
    command_runner::emit(
        &state,
        "active-conversation-changed",
        serde_json::json!(id),
    );
    json_response(
        200,
        serde_json::json!({ "success": true, "conversation": state.conversations.get(&id) }),
    )
}
