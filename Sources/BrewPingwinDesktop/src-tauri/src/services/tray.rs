use std::sync::Arc;
use tauri::{
    menu::{MenuBuilder, MenuItem, MenuItemBuilder},
    tray::{TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, Manager,
};

/// Handles for mutable tray menu items.
pub struct TrayHandles {
    pub status_item: Arc<MenuItem<tauri::Wry>>,
    pub port_item: Arc<MenuItem<tauri::Wry>>,
}

/// Create and configure the system tray icon with context menu.
pub fn setup_system_tray(app: &AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    let status_item = MenuItemBuilder::with_id("status", "状态：启动中...")
        .enabled(false)
        .build(app)?;

    let port_item = MenuItemBuilder::with_id("port_info", "端口：-")
        .enabled(false)
        .build(app)?;

    let separator1 = tauri::menu::PredefinedMenuItem::separator(app)?;
    let show_item = MenuItemBuilder::with_id("show", "显示主窗口").build(app)?;
    let refresh_item = MenuItemBuilder::with_id("refresh_agents", "刷新代理列表").build(app)?;
    let separator2 = tauri::menu::PredefinedMenuItem::separator(app)?;
    let quit_item = MenuItemBuilder::with_id("quit", "退出").build(app)?;

    let menu = MenuBuilder::new(app)
        .item(&status_item)
        .item(&port_item)
        .item(&separator1)
        .item(&show_item)
        .item(&refresh_item)
        .item(&separator2)
        .item(&quit_item)
        .build()?;

    // Use the default window icon (configured in tauri.conf.json)
    let icon = app
        .default_window_icon()
        .cloned()
        .expect("no default window icon configured in tauri.conf.json");

    let _tray = TrayIconBuilder::new()
        .icon(icon)
        .menu(&menu)
        .tooltip("BrewPing Desktop")
        .on_menu_event(|app, event| match event.id().as_ref() {
            "show" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
            "refresh_agents" => {
                let _ = app.emit("refresh-agents", ());
            }
            "quit" => {
                app.exit(0);
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { .. } = event {
                let app = tray.app_handle();
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
        })
        .build(app)?;

    // Store handles for later updates
    app.manage(TrayHandles {
        status_item: Arc::new(status_item),
        port_item: Arc::new(port_item),
    });

    Ok(())
}

/// Update tray menu status text.
pub fn update_tray_status(app: &AppHandle, status: &str, port: u16) {
    if let Some(handles) = app.try_state::<TrayHandles>() {
        let _ = handles
            .status_item
            .set_text(format!("状态：{}", status));
        let _ = handles
            .port_item
            .set_text(format!("端口：{}", port));
    }
}
