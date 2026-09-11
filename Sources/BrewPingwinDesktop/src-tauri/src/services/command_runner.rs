//! 命令执行器（方案 §5.1 / §6.3 / §8.1）。
//!
//! 两处 spawn 点（HTTP `submit_command` / 桌面 `send_command`）的**唯一**执行路径，
//! 同时是命令状态 `completed/failed` 与调度指针的唯一写入点（方案 §2-A5：
//! 对齐 Lody "only CLI owns that transition"）。
//!
//! 错误是转录条目（`role:"error"`）而不是对话状态——对话不因一次失败进入失败态
//! （方案 §2-A6）。

use crate::services::http_server::AppState;
use crate::services::terminal_state::{AgentStatus, OutputType};

/// 各 Agent 的 headless 参数约定（对齐 macOS `CLIAgentImplementations.executionArguments`）。
/// 用户选过模型就在提示词之后追加 `--model <id>`。
pub fn headless_args(agent_id: &str, text: &str, model: Option<&str>) -> Vec<String> {
    let mut args = match agent_id {
        "claude-code" => vec![
            "-p".to_string(),
            text.to_string(),
            "--output-format".to_string(),
            "text".to_string(),
        ],
        "codex" => vec![
            "exec".to_string(),
            "--skip-git-repo-check".to_string(),
            "-s".to_string(),
            "workspace-write".to_string(),
            text.to_string(),
        ],
        "aider" => vec![
            "--message".to_string(),
            text.to_string(),
            "--yes-always".to_string(),
            "--no-auto-commits".to_string(),
        ],
        // opencode 与其它未知 agent：headless 一次性运行（opencode run <message..>）
        _ => vec!["run".to_string(), text.to_string()],
    };
    if let Some(model) = model {
        args.push("--model".to_string());
        args.push(model.to_string());
    }
    args
}

/// 事件广播（HTTP 路径与桌面路径共用；测试环境 `app_events` 为 None 时静默）。
pub fn emit(state: &AppState, event: &str, payload: serde_json::Value) {
    if let Some(sink) = &state.app_events {
        sink(event, payload);
    }
}

/// 对话转录写入的唯一出口（方案 §6.3）：store 落盘 + `conversations-changed` 事件。
/// 终端回显由调用方负责（终端仍是 per-agent 原始输出，逐行语义保留）。
pub async fn append_to_conversation(
    state: &AppState,
    conv_id: &str,
    role: &str,
    text: &str,
    source: Option<&str>,
    command_id: Option<&str>,
) {
    let appended = state
        .conversations
        .append(conv_id, role, text, source, command_id);
    if appended.is_some() {
        emit(state, "conversations-changed", serde_json::json!({ "id": conv_id }));
    }
}

/// 终端里确保某 agent 的终端条目存在（两条入口路径共用，原 lib.rs 逻辑）。
pub async fn ensure_terminal_entry(state: &AppState, agent_id: &str) {
    let mut map = state.terminal.agents.write().await;
    if !map.contains_key(agent_id) {
        let name = state
            .agents
            .read()
            .await
            .iter()
            .find(|a| a.id == agent_id)
            .map(|a| a.name.clone())
            .unwrap_or_else(|| agent_id.to_string());
        map.insert(
            agent_id.to_string(),
            crate::services::terminal_state::AgentTerminalState::new(
                agent_id.to_string(),
                name,
            ),
        );
    }
}

async fn fail_command(
    state: &AppState,
    command_id: &str,
    conv_id: &str,
    agent_id: &str,
    message: &str,
    failure_reason: Option<String>,
    duration: Option<f64>,
) {
    {
        let mut map = state.terminal.agents.write().await;
        if let Some(term) = map.get_mut(agent_id) {
            term.append_line(&format!("Error: {message}"), OutputType::Error);
            term.set_status(AgentStatus::Error);
        }
    }
    state
        .command_store
        .set_failed(command_id, message.to_string(), failure_reason, duration)
        .await;
    append_to_conversation(state, conv_id, "error", message, None, Some(command_id)).await;
    state.conversations.set_latest_command(conv_id, None);
    emit(state, "terminal-updated", serde_json::json!({}));
}

/// 执行一条已入队的命令：预检 → spawn → 转录写入 → 状态写回。
/// 调用方（submit_command）负责：insert_pending、用户消息转录、`latest_command_id` 设置。
pub async fn execute_agent_command(
    state: &AppState,
    command_id: String,
    conversation_id: String,
    agent_id: String,
    text: String,
) {
    let start = std::time::Instant::now();
    state.command_store.set_working(&command_id).await;

    // ── Agent 与可执行文件 ──────────────────────────────────────────────────
    let agent_entry = state
        .agents
        .read()
        .await
        .iter()
        .find(|a| a.id == agent_id)
        .cloned();
    let Some(agent) = agent_entry else {
        let msg = format!("Agent '{agent_id}' not available");
        fail_command(state, &command_id, &conversation_id, &agent_id, &msg, None, None).await;
        return;
    };
    let Some(executable) = agent.executable.clone() else {
        let msg = format!("Executable not found for {agent_id}");
        fail_command(
            state,
            &command_id,
            &conversation_id,
            &agent_id,
            &msg,
            Some("process_exited".to_string()),
            None,
        )
        .await;
        return;
    };

    // ── 终端进入 Running ────────────────────────────────────────────────────
    {
        let mut map = state.terminal.agents.write().await;
        if let Some(term) = map.get_mut(&agent_id) {
            term.set_status(AgentStatus::Running);
        }
    }
    emit(state, "terminal-updated", serde_json::json!({}));

    // ── 模型 / 工作目录：对话级覆盖 ?? 全局偏好（方案 §6.6）────────────────
    let conv_snapshot = state.conversations.get(&conversation_id);
    let model = conv_snapshot
        .as_ref()
        .and_then(|c| c.model_override.clone())
        .or_else(|| state.model_prefs.get(&agent_id));
    let workdir = conv_snapshot
        .as_ref()
        .and_then(|c| c.workdir_override.clone())
        .or_else(|| state.workdir_prefs.get(&agent_id));

    // ── cwd 预检（与既有 invalid_workdir 语义一致，方案 §5.9）──────────────
    if let Some(dir) = workdir.as_deref() {
        let probe = dir.to_string();
        let dir_ok = tokio::task::spawn_blocking(move || std::path::Path::new(&probe).is_dir())
            .await
            .unwrap_or(false);
        if !dir_ok {
            let msg = format!("Workdir not available: {dir}");
            fail_command(
                state,
                &command_id,
                &conversation_id,
                &agent_id,
                &msg,
                Some("invalid_workdir".to_string()),
                Some(start.elapsed().as_secs_f64()),
            )
            .await;
            return;
        }
    }

    // ── Spawn（headless 一次性执行）────────────────────────────────────────
    let args = headless_args(&agent_id, &text, model.as_deref());
    let exec_clone = executable.clone();
    let workdir_clone = workdir.clone();

    let result = tokio::task::spawn_blocking(move || {
        let mut cmd = std::process::Command::new(&exec_clone);
        cmd.args(&args)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        // ★ 关键：只影响该子进程，绝不用 std::env::set_current_dir（进程级全局状态）。
        if let Some(dir) = workdir_clone.as_deref() {
            cmd.current_dir(dir);
        }
        #[cfg(windows)]
        {
            if let Ok(path) = std::env::var("PATH") {
                let home = dirs::home_dir().unwrap_or_default();
                let extra = format!(
                    "{}\\.local\\bin;{}\\scoop\\shims",
                    home.display(),
                    home.display()
                );
                cmd.env("PATH", format!("{};{}", extra, path));
            }
        }
        cmd.output()
    })
    .await;

    let elapsed = start.elapsed().as_secs_f64();

    match result {
        Ok(Ok(output)) => {
            let stdout = String::from_utf8_lossy(&output.stdout);
            let stderr = String::from_utf8_lossy(&output.stderr);

            if output.status.success() {
                let response_text = if stdout.trim().is_empty() {
                    "(no output)".to_string()
                } else {
                    stdout.trim_end().to_string()
                };
                {
                    let mut map = state.terminal.agents.write().await;
                    if let Some(term) = map.get_mut(&agent_id) {
                        for line in stdout.split('\n') {
                            if !line.is_empty() {
                                term.append_line(line, OutputType::Normal);
                            }
                        }
                        if stdout.trim().is_empty() {
                            term.append_line("(no output)", OutputType::System);
                        }
                        term.set_status(AgentStatus::Idle);
                    }
                }
                state
                    .command_store
                    .set_completed(&command_id, response_text.clone(), Some(elapsed))
                    .await;
                append_to_conversation(
                    state,
                    &conversation_id,
                    "assistant",
                    &response_text,
                    None,
                    Some(&command_id),
                )
                .await;
                state.conversations.set_latest_command(&conversation_id, None);
            } else {
                let err_line = format!("Exit code: {}", output.status.code().unwrap_or(-1));
                let message = if stderr.trim().is_empty() {
                    err_line.clone()
                } else {
                    format!("{err_line}\n{}", stderr.trim())
                };
                {
                    let mut map = state.terminal.agents.write().await;
                    if let Some(term) = map.get_mut(&agent_id) {
                        term.append_line(&err_line, OutputType::Error);
                        if !stderr.trim().is_empty() {
                            term.append_line(stderr.trim(), OutputType::Error);
                        }
                        term.set_status(AgentStatus::Idle);
                    }
                }
                state
                    .command_store
                    .set_failed(
                        &command_id,
                        message.clone(),
                        Some("process_exited".to_string()),
                        Some(elapsed),
                    )
                    .await;
                append_to_conversation(
                    state,
                    &conversation_id,
                    "error",
                    &message,
                    None,
                    Some(&command_id),
                )
                .await;
                state.conversations.set_latest_command(&conversation_id, None);
            }
        }
        Ok(Err(e)) => {
            let msg = format!("Failed to start process: {e}");
            fail_command(
                state,
                &command_id,
                &conversation_id,
                &agent_id,
                &msg,
                Some("process_exited".to_string()),
                Some(elapsed),
            )
            .await;
        }
        Err(e) => {
            let msg = format!("Task join error: {e}");
            fail_command(
                state,
                &command_id,
                &conversation_id,
                &agent_id,
                &msg,
                None,
                Some(elapsed),
            )
            .await;
        }
    }

    emit(state, "terminal-updated", serde_json::json!({}));
}
