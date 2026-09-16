use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceIdentity {
    pub device_id: String,
    pub created_at: String,
}

/// Load or create device identity from `~/.brewping/device.json`.
/// ID format: `bp_win_` + 8 lowercase hex chars from UUID.
pub fn load_or_create() -> DeviceIdentity {
    load_or_create_at(&device_path())
}

/// 与 `load_or_create` 同语义，但身份文件路径可注入。
///
/// 存在的理由：身份文件是**全局状态**。多个测试用例并发调用时，若都读写用户真实的
/// `~/.brewping/device.json`，会形成「都读不到 → 各自生成 → 互相覆盖」的竞态，
/// 让「身份必须稳定」的断言依赖执行顺序（CI 上已实际失败：同一次运行里两次加载拿到
/// bp_win_58b17daf / bp_win_16fc6c3b 两个不同 ID）。测试用临时路径即可完全隔离。
pub fn load_or_create_at(path: &Path) -> DeviceIdentity {
    if let Some(existing) = read_identity(path) {
        return existing;
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
    let json = match serde_json::to_string_pretty(&identity) {
        Ok(json) => json,
        // 这个结构不可能序列化失败；万一失败，宁可不落盘，也不写一个空文件出去
        // （空文件会被下一次加载当成「损坏」，导致身份每次启动都变）。
        Err(_) => return identity,
    };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    // 🚨 并发首启（多测试线程 / 多进程同时起）必须收敛到同一个身份，不能互相覆盖。
    // 做法：先写临时文件，再用「硬链接」把它原子地落位 —— 链接在目标已存在时会失败
    // （不覆盖），于是后来的写入者会读到先写入者的身份。
    //
    // 这里刻意不用「create_new 创建后直接写内容」：那会留下一个「文件已存在但内容
    // 还没写完」的窗口，并发读者会把它当成损坏文件，反而触发覆盖（自相矛盾）。
    // 也不能直接 write：那是无条件覆盖，并发写入者会互相翻转身份（对手机端的表现
    // 是电脑反复变成一台新设备）。
    let tmp = path.with_extension(format!("tmp-{}", Uuid::new_v4().simple()));
    if std::fs::write(&tmp, &json).is_ok() {
        let linked = std::fs::hard_link(&tmp, path).is_ok();
        let _ = std::fs::remove_file(&tmp);
        if linked {
            return identity;
        }
        // 链接失败：目标已存在（被别人抢先）→ 以既有身份为准。
        if let Some(existing) = read_identity(path) {
            return existing;
        }
    }

    // 走到这里只有两种情形：① 目标存在但解析不了（损坏）② 临时文件写不了 /
    // 文件系统不支持硬链接。都直接覆盖写一次 —— 与改动前行为一致，避免一个损坏
    // 文件把设备身份永久卡死。
    let _ = std::fs::write(path, json);
    identity
}

/// 读取并解析身份文件；缺失 / 不可读 / 内容损坏时返回 None。
fn read_identity(path: &Path) -> Option<DeviceIdentity> {
    let data = std::fs::read_to_string(path).ok()?;
    serde_json::from_str::<DeviceIdentity>(&data).ok()
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
        .unwrap_or_else(|_| "BrewPing".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 每个用例一个独立临时身份文件。
    ///
    /// 身份文件是全局状态：多个用例并发读写同一个真实路径（用户主目录）时会
    /// 互相覆盖，于是「身份稳定」变成依赖执行顺序的假失败（CI 上实际发生过）。
    fn temp_identity_path(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("brewping-di-{}-{}", tag, Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("device.json")
    }

    // TC-DI-01  主机名必须非空（用于 /api/status 与 mDNS 广播）
    #[test]
    fn device_name_is_non_empty() {
        let name = get_device_name();
        assert!(!name.trim().is_empty(), "host 名称不能为空");
    }

    // TC-DI-02  身份格式：bp_win_ + 8 位小写十六进制
    #[test]
    fn identity_id_format_matches_protocol() {
        let id = load_or_create_at(&temp_identity_path("fmt")).device_id;
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
        let path = temp_identity_path("stable");
        let a = load_or_create_at(&path);
        // 先确认确实落盘了：否则下面的失败无法区分是「写盘失败」还是「竞态」
        assert!(path.exists(), "首次加载应把身份落盘：{}", path.display());
        let b = load_or_create_at(&path);
        assert_eq!(a.device_id, b.device_id, "设备身份必须持久化且稳定");
        assert_eq!(a.created_at, b.created_at);
    }

    // TC-DI-04  created_at 必须是合法的 RFC3339 时间戳
    #[test]
    fn created_at_is_rfc3339() {
        let identity = load_or_create_at(&temp_identity_path("ts"));
        assert!(
            chrono::DateTime::parse_from_rfc3339(&identity.created_at).is_ok(),
            "created_at 不是合法 RFC3339: {}",
            identity.created_at
        );
    }

    // TC-DI-05  并发首启：多个写入者争抢时身份必须收敛到同一个（先写入者胜）
    #[test]
    fn identity_is_stable_under_concurrent_creation() {
        let path = temp_identity_path("race");
        let handles: Vec<_> = (0..8)
            .map(|_| {
                let p = path.clone();
                std::thread::spawn(move || load_or_create_at(&p).device_id)
            })
            .collect();
        let ids: Vec<String> = handles.into_iter().map(|h| h.join().unwrap()).collect();
        let first = &ids[0];
        assert!(
            ids.iter().all(|id| id == first),
            "并发加载必须收敛到同一身份（先写入者胜），实际拿到 {ids:?}"
        );
        assert_eq!(
            load_or_create_at(&path).device_id,
            *first,
            "并发写入后，重新加载仍应是同一身份"
        );
    }

    // TC-DI-06  损坏的身份文件必须自愈（覆盖成新的合法身份），而不是让身份永久卡死
    #[test]
    fn corrupt_identity_file_is_healed() {
        let path = temp_identity_path("corrupt");
        std::fs::write(&path, b"{ not valid json").unwrap();
        let id = load_or_create_at(&path).device_id;
        assert!(id.starts_with("bp_win_"), "损坏文件应自愈出新身份，实际 {id}");
        assert_eq!(
            load_or_create_at(&path).device_id,
            id,
            "自愈后的身份应能再次稳定加载"
        );
    }
}
