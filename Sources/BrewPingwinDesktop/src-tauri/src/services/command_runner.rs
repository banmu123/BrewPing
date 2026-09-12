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

/// 流式增量推送（前端据此"边接收边渲染"）。
///
/// `text` 传的是**累积全文**而不是单个分片：事件丢一帧也能被下一帧自愈，
/// 前端只做整体替换，不需要自己拼接、也不怕乱序。
/// `done` 标记这条命令的输出流已结束（随后会落一条最终转录）。
pub fn emit_stream_delta(
    state: &AppState,
    conv_id: &str,
    command_id: &str,
    text: &str,
    done: bool,
) {
    emit(
        state,
        "conversation-delta",
        serde_json::json!({
            "conversationId": conv_id,
            "commandId": command_id,
            "text": text,
            "done": done,
        }),
    );
}

/// 子进程输出事件（由阻塞读线程投递给异步侧）。
pub enum ProcEvent {
    /// stdout 的一个数据块（不保证在换行处切分）。
    Out(String),
    /// stderr 的一个数据块。
    Err(String),
    /// 进程已退出，携带退出码（0 = 成功）。
    Exited(i32),
    /// spawn / wait 本身失败。
    SpawnFailed(String),
}

/// 把一个子进程管道读到底，逐块投递（在阻塞线程里跑，绝不做 await）。
pub fn pump_pipe<R: std::io::Read>(
    mut pipe: R,
    tx: tokio::sync::mpsc::UnboundedSender<ProcEvent>,
    wrap: fn(String) -> ProcEvent,
) {
    let mut buf = [0u8; 4096];
    loop {
        match pipe.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                let chunk = String::from_utf8_lossy(&buf[..n]).to_string();
                if tx.send(wrap(chunk)).is_err() {
                    break; // 接收端已丢弃（命令被放弃）
                }
            }
            Err(_) => break,
        }
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
    // 清指针必须再广播一次：否则前端拿到的快照还带着旧 commandId，
    // 界面会一直卡在"正在思考…"（isBusy 恒真）。
    emit(state, "conversations-changed", serde_json::json!({ "id": conv_id }));
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
    // opencode 的 `--model` 要求 `provider/model` 复合格式；同名模型可来自
    // 多个 provider，用偏好里配对记录的 providerId 拼出完整限定名。
    // 其它 agent（claude/codex/aider）的 --model 只认裸 model id，原样传。
    let model_arg = match (state.model_prefs.get_provider(&agent_id), model) {
        (Some(provider), Some(id)) if agent_id == "opencode" && !id.contains('/') => {
            Some(format!("{provider}/{id}"))
        }
        (_, id) => id,
    };
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

    // ── Spawn（headless 一次性执行；stdout / stderr 边读边推增量）───────────
    //
    // 以前用 `Command::output()`：阻塞到进程退出才拿到第一个字节，前端只能
    // "一次性整段出现"。改成 spawn + 分块读 + mpsc 投递，才有真正的流式。
    let args = headless_args(&agent_id, &text, model_arg.as_deref());
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<ProcEvent>();
    let tx_blocking = tx.clone();
    let exec_clone = executable.clone();
    let workdir_clone = workdir.clone();

    tokio::task::spawn_blocking(move || {
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
                // extra_path_dirs 覆盖 ~/.local/bin（claude 原生安装）、scoop shims、
                // npm 全局目录与 nvm 各版本目录——本进程 PATH 过期（刚装完
                // NVM/CLI 未重启）时也能找到新装的 CLI
                let extra = crate::services::agent_discovery::extra_path_dirs().join(";");
                cmd.env("PATH", format!("{};{}", extra, path));
            }
        }

        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                let _ = tx_blocking.send(ProcEvent::SpawnFailed(format!(
                    "Failed to start process: {e}"
                )));
                return;
            }
        };

        let stdout = child.stdout.take();
        let stderr = child.stderr.take();

        // stderr 必须与 stdout 并发读：串行读会在 stderr 管道写满（4KB）时死锁。
        let tx_err = tx_blocking.clone();
        let err_handle = std::thread::spawn(move || {
            if let Some(pipe) = stderr {
                pump_pipe(pipe, tx_err, ProcEvent::Err);
            }
        });
        if let Some(pipe) = stdout {
            pump_pipe(pipe, tx_blocking.clone(), ProcEvent::Out);
        }
        let _ = err_handle.join();

        match child.wait() {
            Ok(status) => {
                let _ = tx_blocking.send(ProcEvent::Exited(status.code().unwrap_or(-1)));
            }
            Err(e) => {
                let _ = tx_blocking.send(ProcEvent::SpawnFailed(format!(
                    "Failed to wait process: {e}"
                )));
            }
        }
    });
    // 原始 sender 必须丢弃，否则 rx.recv() 永远不会返回 None。
    drop(tx);

    // ── 增量消费：终端逐行回显 + 推给前端 ────────────────────────────────────
    let mut stdout_text = String::new();
    let mut stderr_text = String::new();
    let mut exit_code: Option<i32> = None;
    let mut spawn_error: Option<String> = None;
    // 行缓冲：数据块不保证在换行处切分，未凑齐一行的部分留到下一块。
    let mut line_buf = String::new();
    // 节流：CLI 可能一秒吐出几百块，全量广播会把 webview 冲垮；
    // 末帧无论如何都会补发一次，不会丢内容。
    let mut last_emit: Option<std::time::Instant> = None;

    while let Some(ev) = rx.recv().await {
        match ev {
            ProcEvent::Out(chunk) => {
                stdout_text.push_str(&chunk);
                line_buf.push_str(&chunk);

                let mut lines: Vec<String> =
                    line_buf.split('\n').map(|s| s.to_string()).collect();
                line_buf = lines.pop().unwrap_or_default();
                let complete: Vec<String> = lines
                    .into_iter()
                    .map(|l| l.trim_end().to_string())
                    .filter(|l| !l.is_empty())
                    .collect();
                if !complete.is_empty() {
                    let mut map = state.terminal.agents.write().await;
                    if let Some(term) = map.get_mut(&agent_id) {
                        for line in complete {
                            term.append_line(&line, OutputType::Normal);
                        }
                    }
                    emit(state, "terminal-updated", serde_json::json!({}));
                }

                let due = last_emit
                    .map(|t| t.elapsed() >= std::time::Duration::from_millis(50))
                    .unwrap_or(true);
                if due {
                    emit_stream_delta(
                        state,
                        &conversation_id,
                        &command_id,
                        &stdout_text,
                        false,
                    );
                    last_emit = Some(std::time::Instant::now());
                }
            }
            ProcEvent::Err(chunk) => stderr_text.push_str(&chunk),
            ProcEvent::Exited(code) => exit_code = Some(code),
            ProcEvent::SpawnFailed(msg) => spawn_error = Some(msg),
        }
    }

    // 收尾：把最后一行回显补进终端，再补发末帧增量。
    let tail = line_buf.trim_end().to_string();
    if !tail.is_empty() {
        let mut map = state.terminal.agents.write().await;
        if let Some(term) = map.get_mut(&agent_id) {
            term.append_line(&tail, OutputType::Normal);
        }
        emit(state, "terminal-updated", serde_json::json!({}));
    }
    // 末帧必发（可能刚被节流跳过），前端据此收尾。
    emit_stream_delta(state, &conversation_id, &command_id, &stdout_text, true);

    let elapsed = start.elapsed().as_secs_f64();

    // ── 终态落库（转录里仍然只有一条 assistant / error 条目，增量不写盘）────
    match spawn_error {
        Some(msg) => {
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
        None if exit_code == Some(0) => {
            let response_text = if stdout_text.trim().is_empty() {
                "(no output)".to_string()
            } else {
                stdout_text.trim_end().to_string()
            };
            {
                let mut map = state.terminal.agents.write().await;
                if let Some(term) = map.get_mut(&agent_id) {
                    if stdout_text.trim().is_empty() {
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
            // 清指针后补广播（同 fail_command）：前端据此解除 busy。
            emit(
                state,
                "conversations-changed",
                serde_json::json!({ "id": conversation_id }),
            );
        }
        None => {
            let err_line = format!("Exit code: {}", exit_code.unwrap_or(-1));
            let message = if stderr_text.trim().is_empty() {
                err_line.clone()
            } else {
                format!("{err_line}\n{}", stderr_text.trim())
            };
            {
                let mut map = state.terminal.agents.write().await;
                if let Some(term) = map.get_mut(&agent_id) {
                    term.append_line(&err_line, OutputType::Error);
                    if !stderr_text.trim().is_empty() {
                        term.append_line(stderr_text.trim(), OutputType::Error);
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
            emit(
                state,
                "conversations-changed",
                serde_json::json!({ "id": conversation_id }),
            );
        }
    }

    emit(state, "terminal-updated", serde_json::json!({}));
}
