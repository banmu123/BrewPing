//! 用户通过 App（iPhone / Watch）选定的**默认模型**持久化。
//!
//! 与 macOS `AgentManager._defaultModels` 语义一致：它是一个"用户偏好"，
//! 不修改各 Agent 自己的配置文件 —— 我们只读那些文件（见 `agent_config`），
//! 选中的模型在启动 Agent 时以命令行参数传入。
//!
//! 落盘位置 `~/.brewping/models.json`，与 `pairing.json` / `approval.json` / `device.json` 同目录。
//! **刻意不复用 macOS 的 `config.json`**：那个文件归 macOS 端所有，
//! 这里只维护自己的一小块，避免两端同时写同一个文件时互相覆盖。

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

#[derive(Debug, Default, Serialize, Deserialize)]
struct Stored {
    /// agentId → modelId
    #[serde(rename = "defaultModels", default)]
    default_models: HashMap<String, String>,
}

/// 每台机器一份：agentId → 用户选定的 modelId。
pub struct ModelPrefs {
    path: PathBuf,
    inner: Mutex<HashMap<String, String>>,
}

impl ModelPrefs {
    /// 使用默认路径 `~/.brewping/models.json`。
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

    /// 读取某个 Agent 的默认模型；未设置过时为 `None`。
    pub fn get(&self, agent_id: &str) -> Option<String> {
        let inner = self.inner.lock().expect("model prefs poisoned");
        inner.get(agent_id).cloned()
    }

    /// 设置（`Some`）或清除（`None`）某个 Agent 的默认模型，并立刻落盘。
    pub fn set(&self, agent_id: &str, model_id: Option<&str>) {
        let snapshot = {
            let mut inner = self.inner.lock().expect("model prefs poisoned");
            match model_id {
                Some(id) if !id.is_empty() => {
                    inner.insert(agent_id.to_string(), id.to_string());
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

impl Default for ModelPrefs {
    fn default() -> Self {
        Self::new()
    }
}

fn default_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".brewping")
        .join("models.json")
}

fn load(path: &PathBuf) -> HashMap<String, String> {
    let Ok(data) = std::fs::read_to_string(path) else {
        return HashMap::new();
    };
    serde_json::from_str::<Stored>(&data)
        .map(|stored| stored.default_models)
        .unwrap_or_default()
}

fn save(path: &PathBuf, models: &HashMap<String, String>) {
    let stored = Stored {
        default_models: models.clone(),
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
        path.push(format!("brewping-models-test-{}-{}.json", tag, Uuid::new_v4().simple()));
        path
    }

    // TC-MP-01  set 后落盘，重新加载仍能读到
    #[test]
    fn set_persists_across_reload() {
        let path = temp_path("persist");
        let prefs = ModelPrefs::with_path(path.clone());
        assert!(prefs.get("opencode").is_none());
        prefs.set("opencode", Some("glm-5.2"));
        assert_eq!(prefs.get("opencode").as_deref(), Some("glm-5.2"));

        let again = ModelPrefs::with_path(path.clone());
        assert_eq!(again.get("opencode").as_deref(), Some("glm-5.2"), "必须落盘可复用");
        let _ = std::fs::remove_file(path);
    }

    // TC-MP-02  各 Agent 互不影响；传 None / 空串等于清除
    #[test]
    fn per_agent_isolation_and_clear() {
        let path = temp_path("isolate");
        let prefs = ModelPrefs::with_path(path.clone());
        prefs.set("opencode", Some("glm-5.2"));
        prefs.set("codex", Some("glm-5.3"));
        assert_eq!(prefs.get("opencode").as_deref(), Some("glm-5.2"));
        assert_eq!(prefs.get("codex").as_deref(), Some("glm-5.3"));

        prefs.set("opencode", None);
        assert!(prefs.get("opencode").is_none());
        assert_eq!(prefs.get("codex").as_deref(), Some("glm-5.3"), "不应误伤其它 Agent");

        prefs.set("codex", Some(""));
        assert!(prefs.get("codex").is_none(), "空串等于清除");
        let _ = std::fs::remove_file(path);
    }

    // TC-MP-03  文件损坏 / 不存在时退化为空表，不 panic
    #[test]
    fn corrupted_file_is_tolerated() {
        let path = temp_path("broken");
        std::fs::write(&path, "{ this is not json").unwrap();
        let prefs = ModelPrefs::with_path(path.clone());
        assert!(prefs.get("opencode").is_none());
        let _ = std::fs::remove_file(path);
    }
}
