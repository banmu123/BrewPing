use serde::Serialize;
use std::process::Command;

/// Agent definition from the static catalog.
#[derive(Debug, Clone)]
pub struct AgentDefinition {
    pub id: &'static str,
    pub name: &'static str,
    pub command: &'static str,
    pub version_args: &'static [&'static str],
}

/// Discovered agent with runtime information.
/// Internal representation keeps the executable path for terminal execution.
#[derive(Debug, Clone)]
pub struct AgentEntry {
    pub id: String,
    pub name: String,
    pub installed: bool,
    pub active: bool,
    pub executable: Option<String>,
    pub version: Option<String>,
}

/// Serializable version for API responses (matches macOS/iOS AgentEntry schema).
#[derive(Debug, Clone, Serialize)]
pub struct AgentEntryApi {
    pub id: String,
    pub name: String,
    pub installed: bool,
    pub active: bool,
    pub executable: bool,
    pub version: Option<String>,
}

impl From<&AgentEntry> for AgentEntryApi {
    fn from(entry: &AgentEntry) -> Self {
        Self {
            id: entry.id.clone(),
            name: entry.name.clone(),
            installed: entry.installed,
            active: entry.active,
            executable: entry.installed,
            version: entry.version.clone(),
        }
    }
}

/// Static agent catalog matching macOS Desktop.
const CATALOG: &[AgentDefinition] = &[
    AgentDefinition {
        id: "opencode",
        name: "OpenCode",
        command: "opencode",
        version_args: &["--version"],
    },
    AgentDefinition {
        id: "claude-code",
        name: "Claude Code",
        command: "claude",
        version_args: &["--version"],
    },
    AgentDefinition {
        id: "codex",
        name: "Codex CLI",
        command: "codex",
        version_args: &["--version"],
    },
    AgentDefinition {
        id: "aider",
        name: "Aider",
        command: "aider",
        version_args: &["--version"],
    },
];

/// Discover all agents in the catalog.
pub fn discover() -> Vec<AgentEntry> {
    CATALOG.iter().map(|def| discover_one(def)).collect()
}

/// Discover a single agent: locate executable and get version.
fn discover_one(def: &AgentDefinition) -> AgentEntry {
    let (installed, executable, version) = match locate_command(def.command) {
        Some(path) => {
            let ver = get_version(&path, def.version_args);
            (true, Some(path), ver)
        }
        None => (false, None, None),
    };
    AgentEntry {
        id: def.id.to_string(),
        name: def.name.to_string(),
        installed,
        active: installed,
        executable,
        version,
    }
}

/// Locate a command on the system PATH.
///
/// On Windows, also checks npm global bin directory for .cmd files.
fn locate_command(command: &str) -> Option<String> {
    // Phase 1: Use `which` crate (handles PATH search + Windows .cmd/.exe extensions)
    if let Ok(path) = which::which(command) {
        return Some(path.to_string_lossy().to_string());
    }

    // Phase 2: Check npm global prefix (for tools installed via npm -g)
    if let Some(npm_path) = find_npm_global_command(command) {
        return Some(npm_path);
    }

    // Phase 3: Check common install locations
    if let Some(local_path) = check_common_locations(command) {
        return Some(local_path);
    }

    None
}

/// Find a command in npm's global bin directory.
fn find_npm_global_command(command: &str) -> Option<String> {
    let output = Command::new("npm")
        .args(["config", "get", "prefix"])
        .output()
        .ok()?;
    let prefix = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if prefix.is_empty() {
        return None;
    }

    let candidates: Vec<String> = if cfg!(windows) {
        vec![
            format!("{}\\{}\\{}.cmd", prefix, "node_modules\\.bin", command),
            format!("{}\\{}\\{}.exe", prefix, "node_modules\\.bin", command),
            format!("{}\\{}", prefix, command),
        ]
    } else {
        vec![
            format!("{}/bin/{}", prefix, command),
        ]
    };

    for candidate in &candidates {
        if std::path::Path::new(candidate).exists() {
            return Some(candidate.clone());
        }
    }
    None
}

/// Check common installation locations.
fn check_common_locations(command: &str) -> Option<String> {
    let home = dirs::home_dir()?;
    let candidates: Vec<String> = if cfg!(windows) {
        let local_app = std::env::var("LOCALAPPDATA").ok()?;
        let app_data = std::env::var("APPDATA").ok()?;
        vec![
            format!("{}\\Programs\\{}\\{}.exe", local_app, command, command),
            format!("{}\\npm\\{}.cmd", app_data, command),
            format!("{}\\.local\\bin\\{}.exe", home.display(), command),
            format!("{}\\scoop\\shims\\{}.exe", home.display(), command),
        ]
    } else {
        vec![
            format!("{}/.local/bin/{}", home.display(), command),
            format!("/usr/local/bin/{}", command),
            format!("/opt/homebrew/bin/{}", command),
        ]
    };

    for candidate in &candidates {
        if std::path::Path::new(candidate).exists() {
            return Some(candidate.clone());
        }
    }
    None
}

/// Get version string from a command.
fn get_version(path: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(path).args(args).output().ok()?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let raw = if !stdout.trim().is_empty() {
        stdout.trim()
    } else {
        stderr.trim()
    };
    if raw.is_empty() {
        return None;
    }
    Some(extract_version(raw))
}

/// Extract a clean version string from raw command output.
fn extract_version(raw: &str) -> String {
    // Take the first line
    let first_line = raw.lines().next().unwrap_or(raw);
    // Try to find a version pattern like X.Y.Z
    let chars = first_line.char_indices().collect::<Vec<_>>();
    for (i, c) in chars.iter() {
        if c.is_ascii_digit() {
            let rest = &first_line[*i..];
            // 版本体 = 数字与点；一旦出现 `-` / `+`（pre-release / build metadata），
            // 其后允许字母数字，直到空格、换行或其它分隔符为止。
            // 例：`1.2.3-beta.1` → 全量保留；`1.2.3+build5 (sha abc)` → 到空格为止。
            let mut end = 0usize;
            let mut in_suffix = false;
            for (idx, ch) in rest.char_indices() {
                let allowed = if ch.is_ascii_digit() || ch == '.' {
                    true
                } else if ch == '-' || ch == '+' {
                    in_suffix = true;
                    true
                } else if in_suffix && ch.is_ascii_alphanumeric() {
                    true
                } else {
                    false
                };
                if !allowed {
                    break;
                }
                end = idx + ch.len_utf8();
            }
            if end > 0 {
                return rest[..end].to_string();
            }
        }
    }
    first_line.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    // TC-AD-01  版本号提取：常见 semver 形态
    #[test]
    fn extract_version_parses_semver() {
        assert_eq!(extract_version("1.2.3"), "1.2.3");
        assert_eq!(extract_version("opencode 1.2.3"), "1.2.3");
        assert_eq!(extract_version("v0.10.4"), "0.10.4");
        assert_eq!(extract_version("1.2.3-beta.1"), "1.2.3-beta.1");
        assert_eq!(extract_version("1.2.3+build5 (sha abc)"), "1.2.3+build5");
        assert_eq!(extract_version("1.2.3\nsecond line"), "1.2.3");
    }

    // TC-AD-02  边界：无数字 / 空串 / 多行，回退到首行
    #[test]
    fn extract_version_falls_back_to_first_line() {
        assert_eq!(extract_version("no digits here"), "no digits here");
        assert_eq!(extract_version("a\nb"), "a");
        assert_eq!(extract_version(""), "");
    }

    // TC-AD-03  目录完整性：id 唯一且全部映射
    #[test]
    fn discover_returns_full_catalog_with_unique_ids() {
        let agents = discover();
        assert_eq!(agents.len(), CATALOG.len());
        let mut ids: Vec<&str> = agents.iter().map(|a| a.id.as_str()).collect();
        ids.sort();
        let mut dedup = ids.clone();
        dedup.dedup();
        assert_eq!(ids.len(), dedup.len(), "agent id 必须唯一");
        assert!(agents.iter().any(|a| a.id == "opencode"));
        assert!(agents.iter().any(|a| a.id == "claude-code"));
        assert!(agents.iter().any(|a| a.id == "codex"));
        assert!(agents.iter().any(|a| a.id == "aider"));
    }

    // TC-AD-04  一致性：installed 与 executable 必须同时成立或同时缺失
    #[test]
    fn installed_implies_executable_path() {
        for a in discover() {
            if a.installed {
                assert!(a.executable.is_some(), "{} installed 但 executable 为空", a.id);
            } else {
                assert!(a.executable.is_none(), "{} 未安装却带 executable 路径", a.id);
            }
        }
    }

    // TC-AD-05  API 投影：executable 必须是布尔且等于 installed（对齐移动端契约）
    #[test]
    fn api_projection_reports_executable_as_bool() {
        let installed = AgentEntry {
            id: "opencode".into(),
            name: "OpenCode".into(),
            installed: true,
            active: true,
            executable: Some("C:/npm/opencode.cmd".into()),
            version: Some("1.0.0".into()),
        };
        let api = AgentEntryApi::from(&installed);
        assert!(api.executable);
        assert_eq!(api.version.as_deref(), Some("1.0.0"));

        let missing = AgentEntry {
            id: "aider".into(),
            name: "Aider".into(),
            installed: false,
            executable: None,
            version: None,
            ..installed.clone()
        };
        let api = AgentEntryApi::from(&missing);
        assert!(!api.executable, "未安装时 executable 必须为 false");
        assert!(api.version.is_none());
    }

    // TC-AD-06  序列化契约：字段名必须与前端 types.ts 完全一致
    #[test]
    fn api_entry_serializes_with_expected_keys() {
        let api = AgentEntryApi::from(&AgentEntry {
            id: "codex".into(),
            name: "Codex CLI".into(),
            installed: true,
            active: false,
            executable: Some("codex".into()),
            version: Some("2.0.0".into()),
        });
        let v = serde_json::to_value(&api).unwrap();
        for key in ["id", "name", "installed", "active", "executable", "version"] {
            assert!(v.get(key).is_some(), "缺少字段 {key}");
        }
        assert!(v["executable"].is_boolean(), "executable 必须是布尔，不能是路径字符串");
    }
}
