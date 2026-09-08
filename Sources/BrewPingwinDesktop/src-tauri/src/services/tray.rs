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
}

/// Generate a 32x32 RGBA coffee cup icon.
fn create_icon_rgba() -> Vec<u8> {
    let size = 32;
    let mut rgba = vec![0u8; size * size * 4];
    for y in 0..size {
        for x in 0..size {
            let idx = (y * size + x) * 4;
            let (r, g, b, a) = pixel_color(x, y, size);
            rgba[idx] = r;
            rgba[idx + 1] = g;
            rgba[idx + 2] = b;
            rgba[idx + 3] = a;
        }
    }
    rgba
}

fn pixel_color(x: usize, y: usize, _size: usize) -> (u8, u8, u8, u8) {
    // Cup body: x=8..22, y=10..24
    if x >= 8 && x <= 22 && y >= 10 && y <= 24 {
        if y == 10 || y == 24 || x == 8 || x == 22 {
            return (139, 94, 60, 255); // dark brown border
        }
        return (180, 130, 80, 255); // light brown fill
    }
    // Handle: x=23..25, y=14..20
    if x >= 23 && x <= 25 && y >= 14 && y <= 20 {
        if (y == 14 || y == 20) && x <= 24 {
            return (139, 94, 60, 255);
        }
        if x == 25 && y > 14 && y < 20 {
            return (139, 94, 60, 255);
        }
    }
    // Steam wisps
    if y >= 3 && y <= 8 {
        if (x == 13 && y % 3 == 1) || (x == 17 && y % 3 == 2) {
            return (180, 180, 180, 150);
        }
    }
    (0, 0, 0, 0) // transparent
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

    let separator1 = tauri::menu::PredefinedMenuItem::separator(app)?;
    let show_item = MenuItemBuilder::with_id("show", "显示主窗口").build(app)?;
    let refresh_item = MenuItemBuilder::with_id("refresh_agents", "刷新代理列表").build(app)?;
    let separator2 = tauri::menu::PredefinedMenuItem::separator(app)?;
    let quit_item = MenuItemBuilder::with_id("quit", "退出").build(app)?;

    let menu = MenuBuilder::new(app)
        .item(&status_item)
        .item(&device_item)
        .item(&ip_item)
        .item(&port_item)
        .item(&separator1)
        .item(&show_item)
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
        // NOTE: 不注册 on_tray_icon_event，避免右键点击抢焦点导致菜单闪退
        // "显示主窗口" 菜单项已提供该功能
        .build(app)?;

    // Store handles for later updates
    app.manage(TrayHandles {
        status_item: Arc::new(status_item),
        port_item: Arc::new(port_item),
        device_item: Arc::new(device_item),
        ip_item: Arc::new(ip_item),
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
