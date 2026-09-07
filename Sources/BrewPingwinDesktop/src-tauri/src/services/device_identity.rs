use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceIdentity {
    pub device_id: String,
    pub created_at: String,
}

/// Load or create device identity from `~/.brewping/device.json`.
/// ID format: `bp_win_` + 8 lowercase hex chars from UUID.
pub fn load_or_create() -> DeviceIdentity {
    let path = device_path();
    if let Ok(data) = std::fs::read_to_string(&path) {
        if let Ok(identity) = serde_json::from_str::<DeviceIdentity>(&data) {
            return identity;
        }
    }
    let uuid_part: String = Uuid::new_v4()
        .to_string()
        .chars()
        .take(8)
        .collect::<String>()
        .to_lowercase();
    let identity = DeviceIdentity {
        device_id: format!("bp_win_{}", uuid_part),
        created_at: chrono::Utc::now().to_rfc3339(),
    };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::write(&path, serde_json::to_string_pretty(&identity).unwrap());
    identity
}

fn device_path() -> PathBuf {
    let brewping_dir = dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".brewping");
    brewping_dir.join("device.json")
}

/// Get the host name of this machine.
pub fn get_device_name() -> String {
    hostname::get()
        .map(|h| h.to_string_lossy().to_string())
        .unwrap_or_else(|_| "BrewPing Desktop".to_string())
}
