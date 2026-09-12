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
    /// 用户选定的工作目录；`null` = 未指定（跟随进程当前目录）。
    /// 由 `http_server::handle_agents` / `handle_discovery_refresh` 与 `lib.rs`
    /// 的 Tauri command 从 `WorkdirPrefs` 填充，`From<&AgentEntry>` 保持 `None`。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workdir: Option<String>,
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
            workdir: None,
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
///
/// `pub(crate)`：设置页的环境检测 / 安装引导（`env_setup`）复用同一套定位规则，
/// 保证「检测到」与「执行时用同一个可执行文件」永远一致。
pub(crate) fn locate_command(command: &str) -> Option<String> {
    // Phase 1: Use `which` crate (handles PATH search + Windows .cmd/.exe extensions)
    if let Ok(path) = which::which(command) {
        return Some(path.to_string_lossy().to_string());
    }

    // Phase 2: Check npm global prefix (for tools installed via npm -g)
    if let Some(npm_path) = find_npm_global_command(command) {
        return Some(npm_path);
    }

    // Phase 3: NVM 管理的 node 目录（刚经 NVM 装完 node / npm -g 时，
    // 本进程的 PATH 还是旧的，但版本目录里已经有可执行文件了）
    if let Some(nvm_path) = find_in_nvm_dirs(command) {
        return Some(nvm_path);
    }

    // Phase 4: Check common install locations
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
///
/// `pub(crate)`：供 `env_setup` 的环境检测复用（同一定位、同一版本提取规则）。
pub(crate) fn get_version(path: &str, args: &[&str]) -> Option<String> {
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

// ─── NVM / PATH 辅助（设置页「环境与 CLI」区块共用）────────────────────────────

/// nvm-windows 的安装目录（NVM_HOME）：进程 env → 注册表（HKCU/HKLM）→ `nvm root` 输出。
///
/// 刚在本会话里装完 NVM 时，进程 env 与 PATH 都不会刷新，必须落回注册表探测；
/// `nvm root` 是最后兜底（要 spawn 一个进程，代价最高）。
pub(crate) fn nvm_home() -> Option<String> {
    if let Ok(home) = std::env::var("NVM_HOME") {
        if !home.trim().is_empty() {
            return Some(home.trim().to_string());
        }
    }
    #[cfg(windows)]
    {
        for (root, sub) in [
            (winreg::enums::HKEY_CURRENT_USER, "Environment"),
            (
                winreg::enums::HKEY_LOCAL_MACHINE,
                r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment",
            ),
        ] {
            if let Ok(key) = winreg::RegKey::predef(root).open_subkey(sub) {
                if let Ok::<String, _>(home) = key.get_value("NVM_HOME") {
                    if !home.trim().is_empty() {
                        return Some(home.trim().to_string());
                    }
                }
            }
        }
    }
    parse_nvm_root_output(&run_capture("nvm", &["root"]))
}

/// nvm-windows 的活动版本符号链接目录（NVM_SYMLINK，默认 `C:\Program Files\nodejs`）。
pub(crate) fn nvm_symlink() -> Option<String> {
    if let Ok(dir) = std::env::var("NVM_SYMLINK") {
        if !dir.trim().is_empty() {
            return Some(dir.trim().to_string());
        }
    }
    #[cfg(windows)]
    {
        for (root, sub) in [
            (winreg::enums::HKEY_CURRENT_USER, "Environment"),
            (
                winreg::enums::HKEY_LOCAL_MACHINE,
                r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment",
            ),
        ] {
            if let Ok(key) = winreg::RegKey::predef(root).open_subkey(sub) {
                if let Ok::<String, _>(dir) = key.get_value("NVM_SYMLINK") {
                    if !dir.trim().is_empty() {
                        return Some(dir.trim().to_string());
                    }
                }
            }
        }
    }
    None
}

/// 解析 `nvm root` 的输出（`Current Root: D:\programs\nvm`）。
fn parse_nvm_root_output(output: &str) -> Option<String> {
    for line in output.lines() {
        if let Some(rest) = line.trim().strip_prefix("Current Root:") {
            let dir = rest.trim();
            if !dir.is_empty() {
                return Some(dir.to_string());
            }
        }
    }
    None
}

/// nvm 管理的各 node 版本目录（`<NVM_HOME>\v*`），名称降序（新版本在前）。
pub(crate) fn nvm_version_dirs() -> Vec<String> {
    let Some(home) = nvm_home() else {
        return Vec::new();
    };
    let mut dirs: Vec<(String, String)> = std::fs::read_dir(&home)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().to_string();
            // nvm-windows 的版本目录固定 v 前缀（v22.14.0）
            if name.starts_with('v') && name[1..].chars().next().is_some_and(|c| c.is_ascii_digit()) {
                Some((name, entry.path().to_string_lossy().to_string()))
            } else {
                None
            }
        })
        .collect();
    dirs.sort_by(|a, b| b.0.cmp(&a.0));
    dirs.into_iter().map(|(_, path)| path).collect()
}

/// nvm 目录下查找某个命令（`.cmd` / `.exe` / 裸名）。
fn find_in_nvm_dirs(command: &str) -> Option<String> {
    let mut dirs = Vec::new();
    if let Some(symlink) = nvm_symlink() {
        dirs.push(symlink);
    }
    dirs.extend(nvm_version_dirs());
    if let Some(home) = nvm_home() {
        dirs.push(home);
    }
    for dir in dirs {
        for candidate in [
            format!(r"{dir}\{command}.cmd"),
            format!(r"{dir}\{command}.exe"),
            format!(r"{dir}\{command}"),
        ] {
            if std::path::Path::new(&candidate).exists() {
                return Some(candidate);
            }
        }
    }
    None
}

/// spawn 子进程时应注入的额外 PATH 目录（排重、过滤空串）。
///
/// 覆盖四类来源：`~/.local/bin`（Claude Code 原生安装）、scoop shims、
/// npm 全局目录（`%APPDATA%\npm`）、nvm（符号链接 + 各版本目录）。
/// 本进程 PATH 过期（刚装完 NVM/CLI 未重启）时，靠它保证「装完就能用」。
pub(crate) fn extra_path_dirs() -> Vec<String> {
    let mut dirs: Vec<String> = Vec::new();
    if let Some(home) = dirs::home_dir() {
        dirs.push(format!(r"{}\.local\bin", home.display()));
        dirs.push(format!(r"{}\scoop\shims", home.display()));
    }
    if let Ok(app_data) = std::env::var("APPDATA") {
        dirs.push(format!(r"{app_data}\npm"));
    }
    if let Some(symlink) = nvm_symlink() {
        dirs.push(symlink);
    }
    dirs.extend(nvm_version_dirs());
    if let Some(home) = nvm_home() {
        dirs.push(home);
    }

    let mut seen = std::collections::HashSet::new();
    dirs.into_iter()
        .filter(|d| !d.trim().is_empty() && seen.insert(d.clone()))
        .collect()
}

/// 目录里的静态定义（名称 + CLI 命令名），供 `env_setup` 组装安装规格。
pub(crate) fn catalog_definition(agent_id: &str) -> Option<(&'static str, &'static str)> {
    CATALOG
        .iter()
        .find(|def| def.id == agent_id)
        .map(|def| (def.name, def.command))
}

/// 捕获式运行一个命令（stdout+stderr 合并、trim），失败返回 None。
pub(crate) fn run_capture(program: &str, args: &[&str]) -> String {
    Command::new(program)
        .args(args)
        .output()
        .map(|out| {
            let mut text = String::from_utf8_lossy(&out.stdout).to_string();
            text.push_str(&String::from_utf8_lossy(&out.stderr));
            text.trim().to_string()
        })
        .unwrap_or_default()
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

    // TC-AD-07  `nvm root` 输出解析（nvm-windows 可装在自定义位置，如 D:\programs\nvm）
    #[test]
    fn parse_nvm_root_output_extracts_dir() {
        assert_eq!(
            parse_nvm_root_output("Current Root: D:\\programs\\nvm"),
            Some("D:\\programs\\nvm".to_string())
        );
        assert_eq!(
            parse_nvm_root_output("\r\nCurrent Root: C:\\Users\\czk\\AppData\\Roaming\\nvm\r\n\r\nNVM_SYMLINK - C:\\Program Files\\nodejs"),
            Some("C:\\Users\\czk\\AppData\\Roaming\\nvm".to_string()),
            "必须取 Current Root: 后的目录，不被后续行干扰"
        );
        assert_eq!(parse_nvm_root_output("nvm 1.2.2"), None);
        assert_eq!(parse_nvm_root_output(""), None);
    }
}
