use serde::{Deserialize, Serialize};
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
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentEntry {
    pub id: String,
    pub name: String,
    pub installed: bool,
    pub active: bool,
    pub executable: Option<String>,
    pub version: Option<String>,
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
            // Find end of version (space, newline, or non-version char after initial digits/dots)
            let end = rest
                .find(|c: char| !c.is_ascii_digit() && c != '.' && c != '-' && c != '+')
                .unwrap_or(rest.len());
            if end > 0 {
                return rest[..end].to_string();
            }
        }
    }
    first_line.to_string()
}
