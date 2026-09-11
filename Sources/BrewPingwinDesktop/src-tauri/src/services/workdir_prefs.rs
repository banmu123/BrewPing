//! 用户通过 App（iPhone / Watch）选定的 **Agent 工作目录**持久化。
//!
//! 与 `model_prefs.rs` 同构：它是一个"用户偏好"，不修改各 Agent 自己的配置文件。
//! 选中的目录在启动 Agent 子进程时通过 `Command::current_dir()` 注入
//! （见 `http_server.rs` 的 `submit_command` 与 `lib.rs` 的 `send_command` 两处 spawn 点）。
//!
//! 落盘位置 `~/.brewping/workdirs.json`，与 `models.json` / `pairing.json` 同目录。
//! **刻意不复用 macOS 的 `config.json`**：那个文件归 macOS 端所有，
//! 这里只维护自己的一小块，避免两端同时写同一个文件时互相覆盖。

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

#[derive(Debug, Default, Serialize, Deserialize)]
struct Stored {
    /// agentId → workdir（已 canonicalize 且剥掉 `\\?\` 前缀的绝对路径）
    #[serde(rename = "workdirs", default)]
    workdirs: HashMap<String, String>,
}

/// 每台机器一份：agentId → 用户选定的工作目录。
pub struct WorkdirPrefs {
    path: PathBuf,
    inner: Mutex<HashMap<String, String>>,
}

impl WorkdirPrefs {
    /// 使用默认路径 `~/.brewping/workdirs.json`。
    pub fn new() -> Self {
        Self::with_path(default_path())
    }

    /// 指定持久化路径构造（测试用）。
    pub fn with_path(path: PathBuf) -> Self {
        let inner = load(&path);
        Self {
            path,
            inner: Mutex::new(inner),
        }
    }

    /// 读取某个 Agent 的工作目录；未设置过时为 `None`。
    pub fn get(&self, agent_id: &str) -> Option<String> {
        let inner = self.inner.lock().expect("workdir prefs poisoned");
        inner.get(agent_id).cloned()
    }

    /// 设置（`Some`）或清除（`None`）某个 Agent 的工作目录，并立刻落盘。
    pub fn set(&self, agent_id: &str, workdir: Option<&str>) {
        let snapshot = {
            let mut inner = self.inner.lock().expect("workdir prefs poisoned");
            match workdir {
                Some(dir) if !dir.is_empty() => {
                    inner.insert(agent_id.to_string(), dir.to_string());
                }
                _ => {
                    inner.remove(agent_id);
                }
            }
            inner.clone()
        };
        save(&self.path, &snapshot);
    }
}

impl Default for WorkdirPrefs {
    fn default() -> Self {
        Self::new()
    }
}

fn default_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".brewping")
        .join("workdirs.json")
}

fn load(path: &PathBuf) -> HashMap<String, String> {
    let Ok(data) = std::fs::read_to_string(path) else {
        return HashMap::new();
    };
    serde_json::from_str::<Stored>(&data)
        .map(|stored| stored.workdirs)
        .unwrap_or_default()
}

fn save(path: &PathBuf, workdirs: &HashMap<String, String>) {
    let stored = Stored {
        workdirs: workdirs.clone(),
    };
    let Ok(data) = serde_json::to_string_pretty(&stored) else { return };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::write(path, data);
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    fn temp_path(tag: &str) -> PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!("brewping-workdirs-test-{}-{}.json", tag, Uuid::new_v4().simple()));
        path
    }

    // TC-WP-01  set 后落盘，重新加载仍能读到
    #[test]
    fn set_persists_across_reload() {
        let path = temp_path("persist");
        let prefs = WorkdirPrefs::with_path(path.clone());
        assert!(prefs.get("claude-code").is_none());
        prefs.set("claude-code", Some("C:\\Users\\czk\\projects\\my-app"));
        assert_eq!(prefs.get("claude-code").as_deref(), Some("C:\\Users\\czk\\projects\\my-app"));

        let again = WorkdirPrefs::with_path(path.clone());
        assert_eq!(
            again.get("claude-code").as_deref(),
            Some("C:\\Users\\czk\\projects\\my-app"),
            "必须落盘可复用"
        );
        let _ = std::fs::remove_file(path);
    }

    // TC-WP-02  各 Agent 互不影响；None / 空串等于清除
    #[test]
    fn per_agent_isolation_and_clear() {
        let path = temp_path("isolate");
        let prefs = WorkdirPrefs::with_path(path.clone());
        prefs.set("claude-code", Some("C:\\a"));
        prefs.set("codex", Some("D:\\b"));
        assert_eq!(prefs.get("claude-code").as_deref(), Some("C:\\a"));
        assert_eq!(prefs.get("codex").as_deref(), Some("D:\\b"));

        prefs.set("claude-code", None);
        assert!(prefs.get("claude-code").is_none());
        assert_eq!(prefs.get("codex").as_deref(), Some("D:\\b"), "不应误伤其它 Agent");

        prefs.set("codex", Some(""));
        assert!(prefs.get("codex").is_none(), "空串等于清除");
        let _ = std::fs::remove_file(path);
    }

    // TC-WP-03  文件损坏 / 不存在时退化为空表，不 panic
    #[test]
    fn corrupted_file_is_tolerated() {
        let path = temp_path("broken");
        std::fs::write(&path, "{ this is not json").unwrap();
        let prefs = WorkdirPrefs::with_path(path.clone());
        assert!(prefs.get("claude-code").is_none());
        let _ = std::fs::remove_file(path);
    }

    // TC-WP-04  旧文件缺少 workdirs 键时不得清空已有内容（#[serde(default)] 回归保护）
    #[test]
    fn legacy_file_missing_key_is_tolerated() {
        let path = temp_path("legacy");
        // 形如"其它工具写了一半"或"未来新增字段回滚"的文件：顶层是合法 JSON 但没有 workdirs 键
        std::fs::write(&path, r#"{"somethingElse": {}}"#).unwrap();
        let prefs = WorkdirPrefs::with_path(path.clone());
        assert!(prefs.get("claude-code").is_none());

        // 设一个值后重新读回 —— 旧文件被升级而不是被清空
        prefs.set("claude-code", Some("C:\\x"));
        let again = WorkdirPrefs::with_path(path);
        assert_eq!(again.get("claude-code").as_deref(), Some("C:\\x"));
    }
}
