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

#[cfg(test)]
mod tests {
    use super::*;

    // TC-DI-01  主机名必须非空（用于 /api/status 与 mDNS 广播）
    #[test]
    fn device_name_is_non_empty() {
        let name = get_device_name();
        assert!(!name.trim().is_empty(), "host 名称不能为空");
    }

    // TC-DI-02  身份格式：bp_win_ + 8 位小写十六进制
    #[test]
    fn identity_id_format_matches_protocol() {
        let id = load_or_create().device_id;
        assert!(id.starts_with("bp_win_"), "设备 ID 前缀必须是 bp_win_，实际 {id}");
        let suffix = &id["bp_win_".len()..];
        assert_eq!(suffix.len(), 8, "ID 后缀必须是 8 位");
        assert!(
            suffix.chars().all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c)),
            "ID 后缀必须是小写十六进制，实际 {suffix}"
        );
    }

    // TC-DI-03  持久化幂等：重复加载必须返回同一身份
    #[test]
    fn identity_is_stable_across_loads() {
        let a = load_or_create();
        let b = load_or_create();
        assert_eq!(a.device_id, b.device_id, "设备身份必须持久化且稳定");
        assert_eq!(a.created_at, b.created_at);
    }

    // TC-DI-04  created_at 必须是合法的 RFC3339 时间戳
    #[test]
    fn created_at_is_rfc3339() {
        let identity = load_or_create();
        assert!(
            chrono::DateTime::parse_from_rfc3339(&identity.created_at).is_ok(),
            "created_at 不是合法 RFC3339: {}",
            identity.created_at
        );
    }
}
