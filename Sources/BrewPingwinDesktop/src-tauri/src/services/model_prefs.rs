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
    /// agentId → providerId（可选；不同 provider 会暴露相同 modelId，
    /// 不记 provider 就无法区分"同名模型来自哪家"，也无法给 opencode
    /// 拼出它要求的 `--model provider/model` 复合格式）。
    #[serde(rename = "defaultProviders", default)]
    default_providers: HashMap<String, String>,
}

/// 每台机器一份：agentId → 用户选定的 modelId（+ 可选 providerId）。
pub struct ModelPrefs {
    path: PathBuf,
    /// (modelId 表, providerId 表)
    inner: Mutex<(HashMap<String, String>, HashMap<String, String>)>,
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
        inner.0.get(agent_id).cloned()
    }

    /// 读取某个 Agent 记住的 providerId；未设置过时为 `None`。
    pub fn get_provider(&self, agent_id: &str) -> Option<String> {
        let inner = self.inner.lock().expect("model prefs poisoned");
        inner.1.get(agent_id).cloned()
    }

    /// 设置（`Some`）或清除（`None`）某个 Agent 的默认模型，并立刻落盘。
    ///
    /// `provider_id` 与 `model_id` 配对记录；清除模型时 provider 一并清除。
    pub fn set(&self, agent_id: &str, model_id: Option<&str>, provider_id: Option<&str>) {
        let snapshot = {
            let mut inner = self.inner.lock().expect("model prefs poisoned");
            match model_id {
                Some(id) if !id.is_empty() => {
                    inner.0.insert(agent_id.to_string(), id.to_string());
                    match provider_id {
                        Some(p) if !p.is_empty() => {
                            inner.1.insert(agent_id.to_string(), p.to_string());
                        }
                        _ => {
                            inner.1.remove(agent_id);
                        }
                    }
                }
                _ => {
                    inner.0.remove(agent_id);
                    inner.1.remove(agent_id);
                }
            }
            Stored {
                default_models: inner.0.clone(),
                default_providers: inner.1.clone(),
            }
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

fn load(path: &PathBuf) -> (HashMap<String, String>, HashMap<String, String>) {
    let Ok(data) = std::fs::read_to_string(path) else {
        return (HashMap::new(), HashMap::new());
    };
    serde_json::from_str::<Stored>(&data)
        .map(|stored| (stored.default_models, stored.default_providers))
        .unwrap_or_default()
}

fn save(path: &PathBuf, stored: &Stored) {
    let Ok(data) = serde_json::to_string_pretty(stored) else { return };
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
        prefs.set("opencode", Some("glm-5.2"), None);
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
        prefs.set("opencode", Some("glm-5.2"), None);
        prefs.set("codex", Some("glm-5.3"), None);
        assert_eq!(prefs.get("opencode").as_deref(), Some("glm-5.2"));
        assert_eq!(prefs.get("codex").as_deref(), Some("glm-5.3"));

        prefs.set("opencode", None, None);
        assert!(prefs.get("opencode").is_none());
        assert_eq!(prefs.get("codex").as_deref(), Some("glm-5.3"), "不应误伤其它 Agent");

        prefs.set("codex", Some(""), None);
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

    // TC-MP-04  providerId 与 modelId 配对记录、配对清除（同名模型跨 provider 场景）
    #[test]
    fn provider_persists_and_clears_with_model() {
        let path = temp_path("provider");
        let prefs = ModelPrefs::with_path(path.clone());
        prefs.set("opencode", Some("mimo-v2.5-pro"), Some("xiaomi-mimo-cn"));
        assert_eq!(prefs.get("opencode").as_deref(), Some("mimo-v2.5-pro"));
        assert_eq!(prefs.get_provider("opencode").as_deref(), Some("xiaomi-mimo-cn"));

        // 重载后两者都在
        let again = ModelPrefs::with_path(path.clone());
        assert_eq!(again.get_provider("opencode").as_deref(), Some("xiaomi-mimo-cn"));

        // 换模型时旧 provider 被替换
        again.set("opencode", Some("mimo-v2.5-pro"), Some("opencode-go"));
        assert_eq!(again.get_provider("opencode").as_deref(), Some("opencode-go"));

        // 清模型时 provider 一并清除
        again.set("opencode", None, None);
        assert!(again.get("opencode").is_none());
        assert!(again.get_provider("opencode").is_none());
        let _ = std::fs::remove_file(path);
    }

    // TC-MP-05  旧版文件（只有 defaultModels）能正常加载，provider 表为空
    #[test]
    fn legacy_file_without_providers_loads() {
        let path = temp_path("legacy");
        std::fs::write(&path, r#"{"defaultModels":{"opencode":"glm-5.2"}}"#).unwrap();
        let prefs = ModelPrefs::with_path(path.clone());
        assert_eq!(prefs.get("opencode").as_deref(), Some("glm-5.2"));
        assert!(prefs.get_provider("opencode").is_none());
        let _ = std::fs::remove_file(path);
    }
}
