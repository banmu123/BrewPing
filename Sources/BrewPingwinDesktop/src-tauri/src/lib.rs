#![allow(dead_code, unused_variables)]

mod services;

use services::agent_discovery::{AgentEntry, AgentEntryApi};
use services::http_server::{AppState, CommandStore};
use services::terminal_state::{
    AgentStatus, AgentTerminalState, OutputType, TerminalManager,
};
use std::sync::Arc;
use tauri::{Emitter, Manager};
use tokio::sync::RwLock;

const DEFAULT_PORT: u16 = 8787;

/// Desktop core state accessible from Tauri commands.
pub struct DesktopCore {
    pub state: AppState,
    pub http_port: Arc<RwLock<u16>>,
    pub mdns_running: Arc<RwLock<bool>>,
    pub server_handle: Arc<RwLock<Option<tokio::task::JoinHandle<()>>>>,
    pub lan_ip: Arc<RwLock<String>>,
    pub terminal: TerminalManager,
}

// ─── Tauri Commands ──────────────────────────────────────────────────────────

#[tauri::command]
async fn get_status(core: tauri::State<'_, DesktopCore>) -> Result<serde_json::Value, String> {
    let host = services::device_identity::get_device_name();
    let default_agent = core.state.default_agent.read().await.clone();
    let session = core.state.session.read().await.clone();
    let agents = core.state.agents.read().await.clone();
    let port = *core.http_port.read().await;
    let lan_ip = core.lan_ip.read().await.clone();
    let mdns = *core.mdns_running.read().await;
    let active_agent_id = core.terminal.active_agent_id.read().await.clone();

    let api_agents: Vec<AgentEntryApi> = agents
        .iter()
        .map(|a| {
            let mut api = AgentEntryApi::from(a);
            api.active = api.installed && a.id == default_agent;
            api
        })
        .collect();

    Ok(serde_json::json!({
        "host": host,
        "defaultAgent": default_agent,
        "session": session,
        "agents": api_agents,
        "port": port,
        "lanIp": lan_ip,
        "mdnsRunning": mdns,
        "platform": std::env::consts::OS,
        "version": "0.1.0",
        "deviceId": core.state.identity.device_id,
        "activeAgentId": active_agent_id,
    }))
}

#[tauri::command]
async fn get_agents(core: tauri::State<'_, DesktopCore>) -> Result<Vec<AgentEntryApi>, String> {
    let agents = core.state.agents.read().await.clone();
    let default_agent = core.state.default_agent.read().await.clone();
    let api_agents: Vec<AgentEntryApi> = agents
        .iter()
        .map(|a| {
            let mut api = AgentEntryApi::from(a);
            api.active = api.installed && a.id == default_agent;
            api
        })
        .collect();
    Ok(api_agents)
}

#[tauri::command]
async fn set_default_agent(
    core: tauri::State<'_, DesktopCore>,
    agent: String,
) -> Result<String, String> {
    let mut default = core.state.default_agent.write().await;
    *default = agent.clone();
    Ok(agent)
}

#[tauri::command]
async fn get_lan_ip(core: tauri::State<'_, DesktopCore>) -> Result<String, String> {
    let ip = core.lan_ip.read().await.clone();
    Ok(ip)
}

#[tauri::command]
async fn get_port(core: tauri::State<'_, DesktopCore>) -> Result<u16, String> {
    let port = *core.http_port.read().await;
    Ok(port)
}

/// Get the terminal state for all agents.
#[tauri::command]
async fn get_terminal_state(
    core: tauri::State<'_, DesktopCore>,
) -> Result<Vec<AgentTerminalState>, String> {
    let map = core.terminal.agents.read().await;
    let mut states: Vec<AgentTerminalState> = map.values().cloned().collect();
    // Sort by agent ID for stable order
    states.sort_by(|a, b| a.agent_id.cmp(&b.agent_id));
    Ok(states)
}

/// Get the currently active agent ID.
#[tauri::command]
async fn get_active_agent_id(core: tauri::State<'_, DesktopCore>) -> Result<String, String> {
    let id = core.terminal.active_agent_id.read().await.clone();
    Ok(id)
}

/// Switch the active terminal agent (matches macOS switchToAgent).
#[tauri::command]
async fn switch_active_agent(
    core: tauri::State<'_, DesktopCore>,
    agent_id: String,
    app: tauri::AppHandle,
) -> Result<(), String> {
    {
        let mut active = core.terminal.active_agent_id.write().await;
        if *active == agent_id {
            return Ok(());
        }
        *active = agent_id.clone();
    }

    // Also update the HTTP server's default agent
    {
        let mut default = core.state.default_agent.write().await;
        *default = agent_id.clone();
    }

    log::info!("Active agent switched to: {}", agent_id);
    let _ = app.emit("active-agent-changed", &agent_id);
    Ok(())
}

/// Send a command to the active agent (matches macOS sendInput).
#[tauri::command]
async fn send_command(
    core: tauri::State<'_, DesktopCore>,
    text: String,
    app: tauri::AppHandle,
) -> Result<(), String> {
    let agent_id = core.terminal.active_agent_id.read().await.clone();

    // Ensure terminal state exists
    {
        let mut map = core.terminal.agents.write().await;
        if !map.contains_key(&agent_id) {
            let agents = core.state.agents.read().await;
            let name = agents
                .iter()
                .find(|a| a.id == agent_id)
                .map(|a| a.name.clone())
                .unwrap_or_else(|| agent_id.clone());
            map.insert(
                agent_id.clone(),
                AgentTerminalState::new(agent_id.clone(), name),
            );
        }
    }

    // Show user input
    {
        let mut map = core.terminal.agents.write().await;
        if let Some(state) = map.get_mut(&agent_id) {
            state.append_line(&format!("> {}", text), OutputType::System);
        }
    }
    let _ = app.emit("terminal-updated", ());

    // Route based on agent type
    if agent_id == "opencode" {
        // Session agent: route through session management
        let session = core.state.session.read().await;
        if session.is_none() {
            let mut map = core.terminal.agents.write().await;
            if let Some(state) = map.get_mut(&agent_id) {
                state.append_line("Error: no active session — start a session first", OutputType::Error);
            }
            let _ = app.emit("terminal-updated", ());
            return Ok(());
        }
        drop(session);

        let command_id = format!("cmd_{}", &uuid::Uuid::new_v4().to_string()[..8]);
        let agent_name = {
            let agents = core.state.agents.read().await;
            agents
                .iter()
                .find(|a| a.id == agent_id)
                .map(|a| a.name.clone())
                .unwrap_or_else(|| "OpenCode".to_string())
        };

        {
            let mut map = core.terminal.agents.write().await;
            if let Some(state) = map.get_mut(&agent_id) {
                state.append_line(
                    &format!("Message sent to {}", agent_name),
                    OutputType::System,
                );
            }
        }
        let _ = app.emit("terminal-updated", ());
        return Ok(());
    }

    // Non-session agent: run CLI executable
    let agents = core.state.agents.read().await;
    let agent_entry = agents.iter().find(|a| a.id == agent_id).cloned();
    drop(agents);

    let Some(agent) = agent_entry else {
        let mut map = core.terminal.agents.write().await;
        if let Some(state) = map.get_mut(&agent_id) {
            state.append_line(
                &format!("Error: agent '{}' not available", agent_id),
                OutputType::Error,
            );
        }
        let _ = app.emit("terminal-updated", ());
        return Ok(());
    };

    let Some(ref executable) = agent.executable else {
        let mut map = core.terminal.agents.write().await;
        if let Some(state) = map.get_mut(&agent_id) {
            state.append_line(
                &format!("Error: executable not found for {}", agent_id),
                OutputType::Error,
            );
            state.set_status(AgentStatus::Error);
        }
        let _ = app.emit("terminal-updated", ());
        return Ok(());
    };

    // Set running
    {
        let mut map = core.terminal.agents.write().await;
        if let Some(state) = map.get_mut(&agent_id) {
            state.set_status(AgentStatus::Running);
        }
    }
    let _ = app.emit("terminal-updated", ());

    let terminal = core.terminal.clone();
    let agent_id_clone = agent_id.clone();
    let executable_clone = executable.clone();
    let text_clone = text.clone();
    let app_clone = app.clone();

    // Use spawn_blocking for synchronous process execution
    tokio::task::spawn_blocking(move || {
        let mut cmd = std::process::Command::new(&executable_clone);
        cmd.arg(&text_clone)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());

        // Add common PATH entries on Windows
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

        // We need to block on async operations inside spawn_blocking
        let rt = tokio::runtime::Handle::current();

        match cmd.output() {
            Ok(output) => {
                let stdout = String::from_utf8_lossy(&output.stdout);
                let stderr = String::from_utf8_lossy(&output.stderr);

                let mut map = rt.block_on(terminal.agents.write());
                if let Some(state) = map.get_mut(&agent_id_clone) {
                    if output.status.success() {
                        let lines: Vec<&str> =
                            stdout.split('\n').collect();
                        for line in &lines {
                            if !line.is_empty() {
                                state.append_line(line, OutputType::Normal);
                            }
                        }
                        if stdout.trim().is_empty() {
                            state.append_line("(no output)", OutputType::System);
                        }
                    } else {
                        state.append_line(
                            &format!("Exit code: {}", output.status.code().unwrap_or(-1)),
                            OutputType::Error,
                        );
                        if !stderr.trim().is_empty() {
                            state.append_line(stderr.trim(), OutputType::Error);
                        }
                    }
                    state.set_status(AgentStatus::Idle);
                }
            }
            Err(e) => {
                let mut map = rt.block_on(terminal.agents.write());
                if let Some(state) = map.get_mut(&agent_id_clone) {
                    state.append_line(
                        &format!("Error: failed to start process: {}", e),
                        OutputType::Error,
                    );
                    state.set_status(AgentStatus::Error);
                }
            }
        }
        let _ = app_clone.emit("terminal-updated", ());
    });

    Ok(())
}

/// Clear the terminal output for an agent.
#[tauri::command]
async fn clear_terminal(
    core: tauri::State<'_, DesktopCore>,
    agent_id: String,
) -> Result<(), String> {
    let mut map = core.terminal.agents.write().await;
    if let Some(state) = map.get_mut(&agent_id) {
        state.clear_output();
    }
    Ok(())
}

// ─── App Entry Point ─────────────────────────────────────────────────────────

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    env_logger::init();

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .setup(|app| {
            // Load device identity
            let identity = services::device_identity::load_or_create();
            let device_name = services::device_identity::get_device_name();

            // Detect LAN IP
            let lan_ip = services::lan_address::detect_primary_lan()
                .map(|info| info.ip.to_string())
                .unwrap_or_else(|| "0.0.0.0".to_string());

            log::info!(
                "Device: {} ({}) on {}",
                device_name,
                identity.device_id,
                lan_ip
            );

            // Discover agents
            let agents = services::agent_discovery::discover();
            log::info!(
                "Discovered {} agents",
                agents.iter().filter(|a| a.installed).count()
            );

            // Determine default agent
            let default_agent = agents
                .iter()
                .find(|a| a.installed && a.id == "opencode")
                .or_else(|| agents.iter().find(|a| a.installed))
                .map(|a| a.id.clone())
                .unwrap_or_else(|| "opencode".to_string());

            // Create shared state
            let terminal = TerminalManager::new();
            let command_store = CommandStore::new();

            let app_state = AppState {
                identity: identity.clone(),
                lan_ip: lan_ip.clone(),
                port: DEFAULT_PORT,
                agents: Arc::new(RwLock::new(agents.clone())),
                default_agent: Arc::new(RwLock::new(default_agent.clone())),
                session: Arc::new(RwLock::new(None)),
                terminal: terminal.clone(),
                command_store: command_store.clone(),
            };

            let core = DesktopCore {
                state: app_state.clone(),
                http_port: Arc::new(RwLock::new(DEFAULT_PORT)),
                mdns_running: Arc::new(RwLock::new(false)),
                server_handle: Arc::new(RwLock::new(None)),
                lan_ip: Arc::new(RwLock::new(lan_ip.clone())),
                terminal: terminal.clone(),
            };

            // Clone Arc handles BEFORE app.manage(core) consumes core
            let port_handle = core.http_port.clone();
            let server_handle = core.server_handle.clone();
            let mdns_flag = core.mdns_running.clone();

            app.manage(core);

            // Initialize terminal states from discovered agents
            let terminal_clone = terminal.clone();
            let agents_clone = agents.clone();
            tauri::async_runtime::spawn(async move {
                terminal_clone.init_from_agents(&agents_clone).await;
            });

            // Setup system tray FIRST so TrayHandles are registered before async task
            services::tray::setup_system_tray(app.handle())?;
            services::tray::update_tray_status(app.handle(), "正在启动...", DEFAULT_PORT, &device_name, &lan_ip);

            // Start HTTP server in background
            let state_for_server = app_state.clone();
            let identity_clone = identity.clone();
            let device_name_clone = device_name.clone();
            let lan_ip_clone = lan_ip.clone();
            let default_agent_clone = default_agent.clone();

            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let lan_for_server = if lan_ip_clone != "0.0.0.0" {
                    Some(lan_ip_clone.as_str())
                } else {
                    None
                };

                match services::http_server::start_server(
                    state_for_server.clone(),
                    DEFAULT_PORT,
                    lan_for_server,
                )
                .await
                {
                    Ok((bound_port, srv_handle)) => {
                        // Update port
                        {
                            let mut p = port_handle.write().await;
                            *p = bound_port;
                        }
                        {
                            let mut h = server_handle.write().await;
                            *h = Some(srv_handle);
                        }

                        // Start mDNS broadcasting
                        let mut mdns = services::mdns_broadcast::MdnsBroadcaster::new();
                        let lan_for_mdns = if lan_ip_clone != "0.0.0.0" {
                            lan_ip_clone.clone()
                        } else {
                            "127.0.0.1".to_string()
                        };

                        match mdns.start(
                            bound_port,
                            &identity_clone.device_id,
                            &device_name_clone,
                            &lan_for_mdns,
                            &default_agent_clone,
                        ) {
                            Ok(()) => {
                                let mut flag = mdns_flag.write().await;
                                *flag = true;
                                log::info!("mDNS broadcasting started");
                                services::tray::update_tray_status(
                                    &handle,
                                    "在线",
                                    bound_port,
                                    &device_name_clone,
                                    &lan_ip_clone,
                                );
                            }
                            Err(e) => {
                                log::error!("mDNS start failed: {}", e);
                                services::tray::update_tray_status(
                                    &handle,
                                    "mDNS失败",
                                    bound_port,
                                    &device_name_clone,
                                    &lan_ip_clone,
                                );
                            }
                        }

                        std::mem::forget(mdns);
                    }
                    Err(e) => {
                        log::error!("HTTP server failed: {}", e);
                        services::tray::update_tray_status(&handle, "启动失败", 0, &device_name_clone, "0.0.0.0");
                    }
                }
            });

            Ok(())
        })
        .on_window_event(|window, event| {
            // Hide to tray instead of closing
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                let _ = window.hide();
                api.prevent_close();
            }
        })
        .invoke_handler(tauri::generate_handler![
            get_status,
            get_agents,
            set_default_agent,
            get_lan_ip,
            get_port,
            get_terminal_state,
            get_active_agent_id,
            switch_active_agent,
            send_command,
            clear_terminal,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
