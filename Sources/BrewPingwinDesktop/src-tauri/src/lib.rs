#![allow(dead_code, unused_variables)]

mod services;

use services::agent_discovery::AgentEntry;
use services::http_server::AppState;
use std::sync::Arc;
use tauri::Manager;
use tokio::sync::RwLock;

const DEFAULT_PORT: u16 = 8787;

/// Desktop core state accessible from Tauri commands.
pub struct DesktopCore {
    pub state: AppState,
    pub http_port: Arc<RwLock<u16>>,
    pub mdns_running: Arc<RwLock<bool>>,
    pub server_handle: Arc<RwLock<Option<tokio::task::JoinHandle<()>>>>,
    pub lan_ip: Arc<RwLock<String>>,
}

// Tauri commands exposed to the frontend
#[tauri::command]
async fn get_status(core: tauri::State<'_, DesktopCore>) -> Result<serde_json::Value, String> {
    let host = services::device_identity::get_device_name();
    let default_agent = core.state.default_agent.read().await.clone();
    let session = core.state.session.read().await.clone();
    let agents = core.state.agents.read().await.clone();
    let port = *core.http_port.read().await;
    let lan_ip = core.lan_ip.read().await.clone();
    let mdns = *core.mdns_running.read().await;

    Ok(serde_json::json!({
        "host": host,
        "defaultAgent": default_agent,
        "session": session,
        "agents": agents,
        "port": port,
        "lanIp": lan_ip,
        "mdnsRunning": mdns,
        "platform": std::env::consts::OS,
        "version": "0.1.0",
        "deviceId": core.state.identity.device_id,
    }))
}

#[tauri::command]
async fn get_agents(core: tauri::State<'_, DesktopCore>) -> Result<Vec<AgentEntry>, String> {
    let agents = core.state.agents.read().await.clone();
    Ok(agents)
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
            log::info!("Discovered {} agents", agents.iter().filter(|a| a.installed).count());

            // Determine default agent
            let default_agent = agents
                .iter()
                .find(|a| a.installed && a.id == "opencode")
                .or_else(|| agents.iter().find(|a| a.installed))
                .map(|a| a.id.clone())
                .unwrap_or_else(|| "opencode".to_string());

            // Create shared state
            let app_state = AppState {
                identity: identity.clone(),
                lan_ip: lan_ip.clone(),
                port: DEFAULT_PORT,
                agents: Arc::new(RwLock::new(agents)),
                default_agent: Arc::new(RwLock::new(default_agent.clone())),
                session: Arc::new(RwLock::new(None)),
            };

            let core = DesktopCore {
                state: app_state.clone(),
                http_port: Arc::new(RwLock::new(DEFAULT_PORT)),
                mdns_running: Arc::new(RwLock::new(false)),
                server_handle: Arc::new(RwLock::new(None)),
                lan_ip: Arc::new(RwLock::new(lan_ip.clone())),
            };

            // Start HTTP server in background
            let state_for_server = app_state.clone();
            let port_handle = core.http_port.clone();
            let server_handle = core.server_handle.clone();
            let mdns_flag = core.mdns_running.clone();
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
                            // Use a placeholder if no LAN detected
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

                                // Update tray
                                services::tray::update_tray_status(&handle, "在线", bound_port);
                            }
                            Err(e) => {
                                log::error!("mDNS start failed: {}", e);
                            }
                        }

                        // Keep mdns alive by leaking it (it will be cleaned up on process exit)
                        // In production, store it in shared state for proper cleanup
                        std::mem::forget(mdns);
                    }
                    Err(e) => {
                        log::error!("HTTP server failed: {}", e);
                        services::tray::update_tray_status(&handle, "启动失败", 0);
                    }
                }
            });

            app.manage(core);

            // Setup system tray
            services::tray::setup_system_tray(app.handle())?;

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_status,
            get_agents,
            set_default_agent,
            get_lan_ip,
            get_port,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
