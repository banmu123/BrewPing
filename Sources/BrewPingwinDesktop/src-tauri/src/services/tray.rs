use std::sync::Arc;
use tauri::{
    image::Image,
    menu::{MenuBuilder, MenuItem, MenuItemBuilder},
    tray::TrayIconBuilder,
    AppHandle, Emitter, Manager,
};

/// Handles for mutable tray menu items.
pub struct TrayHandles {
    pub status_item: Arc<MenuItem<tauri::Wry>>,
    pub port_item: Arc<MenuItem<tauri::Wry>>,
    pub device_item: Arc<MenuItem<tauri::Wry>>,
    pub ip_item: Arc<MenuItem<tauri::Wry>>,
    pub pairing_item: Arc<MenuItem<tauri::Wry>>,
}

/// 未揭示配对码时的占位文本（不点开就不该看到码）。
const PAIRING_PLACEHOLDER: &str = "配对码：—— 点击「显示配对码」";

fn create_icon_rgba() -> Vec<u8> {
    use super::tray_icon_data::TRAY_ICON_RGBA;
    TRAY_ICON_RGBA.to_vec()
}

/// 把运行时状态映射成托盘文案。
///
/// 与 macOS `MenuBarView.runtimeBadge` 的语义一致：
/// `starting` 单独区分出来，避免把"还没启动完"显示成"离线"。
fn runtime_label(app: &AppHandle) -> &'static str {
    use crate::RuntimeState;
    let Some(core) = app.try_state::<crate::DesktopCore>() else {
        return "未启动";
    };
    // 运行时状态用 std::sync::RwLock（同步读），这里不会跨 await 持有，安全。
    let state = core
        .runtime_state
        .read()
        .map(|s| *s)
        .unwrap_or(RuntimeState::Idle);
    match state {
        RuntimeState::Online => "在线",
        RuntimeState::Starting => "正在启动…",
        RuntimeState::Offline => "离线",
        RuntimeState::Idle => "未启动",
    }
}

/// Create and configure the system tray icon with context menu.
pub fn setup_system_tray(app: &AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    let status_item = MenuItemBuilder::with_id("status", "状态：启动中...")
        .enabled(false)
        .build(app)?;

    let device_item = MenuItemBuilder::with_id("device_info", "设备：-")
        .enabled(false)
        .build(app)?;

    let ip_item = MenuItemBuilder::with_id("ip_info", "IP：-")
        .enabled(false)
        .build(app)?;

    let port_item = MenuItemBuilder::with_id("port_info", "端口：-")
        .enabled(false)
        .build(app)?;

    let pairing_item = MenuItemBuilder::with_id("pairing_info", PAIRING_PLACEHOLDER)
        .enabled(false)
        .build(app)?;

    let separator1 = tauri::menu::PredefinedMenuItem::separator(app)?;
    let show_item = MenuItemBuilder::with_id("show", "显示主窗口").build(app)?;
    let show_pairing_item =
        MenuItemBuilder::with_id("show_pairing", "显示配对码").build(app)?;
    let refresh_item = MenuItemBuilder::with_id("refresh_agents", "刷新代理列表").build(app)?;
    let separator2 = tauri::menu::PredefinedMenuItem::separator(app)?;
    let quit_item = MenuItemBuilder::with_id("quit", "退出").build(app)?;

    let menu = MenuBuilder::new(app)
        .item(&status_item)
        .item(&device_item)
        .item(&ip_item)
        .item(&port_item)
        .item(&pairing_item)
        .item(&separator1)
        .item(&show_item)
        .item(&show_pairing_item)
        .item(&refresh_item)
        .item(&separator2)
        .item(&quit_item)
        .build()?;

    // Create icon from RGBA data (no external file dependency)
    let icon_rgba = create_icon_rgba();
    let icon = Image::new_owned(icon_rgba, 32, 32);

    let _tray = TrayIconBuilder::new()
        .icon(icon)
        .menu(&menu)
        .tooltip("BrewPing")
        .on_menu_event(|app, event| match event.id().as_ref() {
            "show" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
            // 与 macOS 菜单栏「Show Pairing Code」等价：
            // 揭示（或复用未过期的）配对码，并把主窗口拉出来展示二维码。
            "show_pairing" => {
                if let Some(core) = app.try_state::<crate::DesktopCore>() {
                    let code = core.state.pairing.issue_pairing_code();
                    let _ = update_tray_pairing(app, Some(&code));
                }
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
                // 通知前端自动展开配对面板。
                let _ = app.emit("pairing-revealed", ());
            }
            "refresh_agents" => {
                if let Some(core) = app.try_state::<crate::DesktopCore>() {
                    let agents_lock = core.state.agents.clone();
                    tauri::async_runtime::spawn(async move {
                        let discovered = crate::services::agent_discovery::discover();
                        *agents_lock.write().await = discovered;
                    });
                }
                let _ = app.emit("refresh-agents", ());
            }
            "quit" => {
                app.exit(0);
            }
            _ => {}
        })
        // NOTE: 不注册 on_tray_icon_event，避免右键点击抢焦点导致菜单闪退
        // "显示主窗口" 菜单项已提供该功能
        .build(app)?;

    // Store handles for later updates
    app.manage(TrayHandles {
        status_item: Arc::new(status_item),
        port_item: Arc::new(port_item),
        device_item: Arc::new(device_item),
        ip_item: Arc::new(ip_item),
        pairing_item: Arc::new(pairing_item),
    });

    Ok(())
}

/// Update tray menu status text.
pub fn update_tray_status(
    app: &AppHandle,
    status: &str,
    port: u16,
    device_name: &str,
    ip: &str,
) {
    if let Some(handles) = app.try_state::<TrayHandles>() {
        let _ = handles
            .status_item
            .set_text(format!("状态：{}", status));
        let _ = handles
            .port_item
            .set_text(format!("端口：{}", port));
        let _ = handles
            .device_item
            .set_text(format!("设备：{}", device_name));
        let _ = handles
            .ip_item
            .set_text(format!("IP：{}", ip));
    }
}

/// 按运行时状态刷新托盘的状态文案（保持托盘与主窗口指示一致）。
pub fn refresh_tray_runtime_state(app: &AppHandle) {
    let label = runtime_label(app);
    if let Some(handles) = app.try_state::<TrayHandles>() {
        let _ = handles.status_item.set_text(format!("状态：{}", label));
    }
}

/// Update the pairing-code menu row. `None` 表示尚未揭示 / 已失效。
pub fn update_tray_pairing(app: &AppHandle, code: Option<&str>) {
    if let Some(handles) = app.try_state::<TrayHandles>() {
        let text = match code {
            Some(code) if !code.is_empty() => format!("配对码：{}", code),
            _ => PAIRING_PLACEHOLDER.to_string(),
        };
        let _ = handles.pairing_item.set_text(text);
    }
}
