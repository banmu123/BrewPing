//! 设置页「环境与 AI CLI」区块的后端：环境检测 + Node 版本清单 + 官方安装通道执行。
//!
//! 架构约束（EventSink 模式，见 `http_server.rs` 注释）：本模块**不依赖 tauri 类型**，
//! 安装进度经 `Option<&EventSink>` 以 `env-setup-log` / `env-setup-done` 事件广播给前端，
//! 测试可以传 `None` 或内存闭包，测试二进制不会链入 GUI 窗口栈。
//!
//! 安装方式以 2026-09 各工具官方文档为准：
//! - **Claude Code**：官方已转向原生安装器（PowerShell `irm https://claude.ai/install.ps1 | iex`，
//!   装到 `~\.local\bin`，**免 Node**）；npm 路线 `@anthropic-ai/claude-code` 自 v2.1.198 起
//!   要求 Node ≥ 22 且已标记弃用（仍可用，作为备选）。
//! - **OpenCode**：`npm install -g opencode-ai`（官方另有 bash 安装脚本，仅 macOS/Linux）。
//! - **Codex CLI**：`npm install -g @openai/codex`（engines node>=16，Windows 原生支持）。
//! - **Aider**：`python -m pip install aider-install && aider-install`（官方安装器，需 Python）。
//!
//! Node 的安装统一走 **NVM for Windows**（用户要求）：先装 NVM（winget → 官方静默安装包
//! 兜底），再 `nvm install <版本>` + `nvm use <版本>`。版本清单优先从 nodejs.org dist index
//! 拉取（按大版本聚合），离线时回落到 nvm 支持的 `latest` / `lts` 别名。

use crate::services::agent_discovery;
use crate::services::http_server::EventSink;
use regex::Regex;
use serde::Serialize;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

/// Node 兼容基线：Claude Code 的 npm 路线自 v2.1.198 起要求 Node ≥ 22，
/// 其余 CLI 门槛更低（codex ≥16、opencode 无声明），统一按最高门槛提示。
pub(crate) const MIN_NODE_MAJOR: u32 = 22;

const WINGET_NVM_ID: &str = "CoreyButler.NVMforWindows";
const NVM_SETUP_URL: &str =
    "https://github.com/coreybutler/nvm-windows/releases/latest/download/nvm-setup.exe";
const NODE_DIST_INDEX_URL: &str = "https://nodejs.org/dist/index.json";
/// 子进程隐藏窗口（npm/winget 等控制台程序不要闪黑框）。
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

// ─── 检测结果结构（serde 契约与前端 types.ts 一一对应，全部 camelCase）────────

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolStatus {
    pub installed: bool,
    pub version: Option<String>,
    pub path: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NodeToolStatus {
    pub installed: bool,
    pub version: Option<String>,
    pub path: Option<String>,
    pub major: Option<u32>,
    /// major >= MIN_NODE_MAJOR（Claude Code npm 路线的门槛）
    pub compatible: bool,
    /// "nvm"（路径含 nvm）或 "system"，仅作展示提示。
    pub source: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NvmToolStatus {
    pub installed: bool,
    pub version: Option<String>,
    pub path: Option<String>,
    /// NVM_HOME（安装目录，各 node 版本装在 `<root>\v*`）。
    pub root: Option<String>,
}

/// 一种官方安装方式。`blocked` 非空时 UI 应禁用安装按钮并展示原因：
/// "node" = 未装 Node；"node-version" = Node 版本低于 `min_node_major`；"python" = 未装 Python。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallMethodInfo {
    /// "native"（claude 原生安装器）/ "npm" / "pip"。
    pub id: String,
    pub needs_node: bool,
    pub min_node_major: u32,
    pub needs_python: bool,
    pub blocked: Option<String>,
    /// 原样展示的官方命令（用户可在日志里对照）。
    pub display: String,
    /// 官方推荐方式（UI 默认选中）。
    pub recommended: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentCliStatus {
    pub id: String,
    pub name: String,
    pub installed: bool,
    pub version: Option<String>,
    pub path: Option<String>,
    pub methods: Vec<InstallMethodInfo>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EnvironmentStatus {
    pub node: NodeToolStatus,
    pub npm: ToolStatus,
    pub nvm: NvmToolStatus,
    /// 仅 Aider 需要；Windows 商店的 python 占位符按未安装处理。
    pub python: ToolStatus,
    pub agents: Vec<AgentCliStatus>,
}

/// 可安装的 Node 版本（版本号可直接作为 `nvm install` 的参数；
/// 离线兜底时为 nvm-windows 支持的别名 "latest" / "lts"）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NodeVersionOption {
    /// 如 "22.14.0"，或别名 "latest" / "lts"。
    pub version: String,
    /// 大版本号；别名时为 null。
    pub major: Option<u32>,
    pub lts: bool,
    pub lts_name: Option<String>,
    /// UI 默认选中（最新 LTS）。
    pub recommended: bool,
}

// ─── 环境检测 ─────────────────────────────────────────────────────────────────

/// 全量环境检测（进程内 spawn 若干 `--version`，约 1-2s；调用方放 spawn_blocking）。
pub fn check_environment() -> EnvironmentStatus {
    let node = probe_node();
    let npm = probe("npm", &["--version"]);
    let python = probe_python();
    let nvm = {
        let mut status = NvmToolStatus {
            installed: false,
            version: None,
            path: None,
            root: agent_discovery::nvm_home(),
        };
        if let Some(path) = agent_discovery::locate_command("nvm") {
            status.installed = true;
            status.path = Some(path.clone());
            status.version = agent_discovery::get_version(&path, &["version"]);
        } else if let Some(root) = &status.root {
            // PATH 还没刷新（刚装完 NVM）：注册表里有 NVM_HOME 就算已安装
            let exe = Path::new(root).join("nvm.exe");
            if exe.exists() {
                status.installed = true;
                status.path = Some(exe.to_string_lossy().to_string());
            }
        }
        status
    };

    let agents = agent_discovery::discover()
        .iter()
        .map(|entry| AgentCliStatus {
            id: entry.id.clone(),
            name: entry.name.clone(),
            installed: entry.installed,
            version: entry.version.clone(),
            path: entry.executable.clone(),
            methods: install_methods_for(&entry.id, node.major, python.installed),
        })
        .collect();

    EnvironmentStatus {
        node,
        npm,
        nvm,
        python,
        agents,
    }
}

fn probe(command: &str, version_args: &[&str]) -> ToolStatus {
    match agent_discovery::locate_command(command) {
        Some(path) => ToolStatus {
            installed: true,
            version: agent_discovery::get_version(&path, version_args),
            path: Some(path),
        },
        None => ToolStatus {
            installed: false,
            version: None,
            path: None,
        },
    }
}

fn probe_node() -> NodeToolStatus {
    let basic = probe("node", &["--version"]);
    let major = basic.version.as_deref().and_then(node_major_from_version);
    let source = basic
        .path
        .as_deref()
        .map(|p| if p.to_lowercase().contains("nvm") { "nvm" } else { "system" })
        .map(str::to_string);
    let compatible = major.is_some_and(|m| m >= MIN_NODE_MAJOR);
    NodeToolStatus {
        installed: basic.installed,
        version: basic.version,
        path: basic.path,
        major,
        compatible,
        source,
    }
}

/// Windows 商店的 `python.exe` 是「引导安装」占位符：运行会弹商店，
/// 必须按未安装处理（真实 Python 不装在 WindowsApps 下）。
fn probe_python() -> ToolStatus {
    for name in ["python", "python3"] {
        if let Some(path) = agent_discovery::locate_command(name) {
            if path.to_lowercase().contains("windowsapps") {
                continue;
            }
            let version = agent_discovery::get_version(&path, &["--version"]);
            if version.is_some() {
                return ToolStatus {
                    installed: true,
                    version,
                    path: Some(path),
                };
            }
        }
    }
    ToolStatus {
        installed: false,
        version: None,
        path: None,
    }
}

/// 从 `node --version` 输出解析大版本号（"v22.14.0" → 22）。
fn node_major_from_version(version: &str) -> Option<u32> {
    let digits: String = version
        .trim()
        .trim_start_matches('v')
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect();
    digits.parse().ok()
}

// ─── 安装规格（官方通道）───────────────────────────────────────────────────────

/// 各 Agent 的官方安装方式清单。`blocked` 按**当前**环境即时计算。
fn install_methods_for(
    agent_id: &str,
    node_major: Option<u32>,
    python_installed: bool,
) -> Vec<InstallMethodInfo> {
    let raw: Vec<(&str, bool, u32, bool, &str, bool)> = match agent_id {
        "claude-code" => vec![
            (
                "native",
                false,
                0,
                false,
                "irm https://claude.ai/install.ps1 | iex",
                true,
            ),
            (
                "npm",
                true,
                22,
                false,
                "npm install -g @anthropic-ai/claude-code",
                false,
            ),
        ],
        "opencode" => vec![("npm", true, 16, false, "npm install -g opencode-ai", true)],
        "codex" => vec![("npm", true, 16, false, "npm install -g @openai/codex", true)],
        "aider" => vec![(
            "pip",
            false,
            0,
            true,
            "python -m pip install aider-install && aider-install",
            true,
        )],
        _ => Vec::new(),
    };
    raw.into_iter()
        .map(|(id, needs_node, min_node_major, needs_python, display, recommended)| {
            let blocked = blocked_reason(
                needs_node,
                min_node_major,
                node_major,
                needs_python,
                python_installed,
            );
            InstallMethodInfo {
                id: id.to_string(),
                needs_node,
                min_node_major,
                needs_python,
                blocked,
                display: display.to_string(),
                recommended,
            }
        })
        .collect()
}

/// 安装前置校验（纯函数，检测与执行两端共用同一套规则）。
fn blocked_reason(
    needs_node: bool,
    min_node_major: u32,
    node_major: Option<u32>,
    needs_python: bool,
    python_installed: bool,
) -> Option<String> {
    if needs_node {
        match node_major {
            None => return Some("node".to_string()),
            Some(major) if major < min_node_major => return Some("node-version".to_string()),
            _ => {}
        }
    }
    if needs_python && !python_installed {
        return Some("python".to_string());
    }
    None
}

fn npm_package(agent_id: &str) -> Option<&'static str> {
    match agent_id {
        "claude-code" => Some("@anthropic-ai/claude-code"),
        "opencode" => Some("opencode-ai"),
        "codex" => Some("@openai/codex"),
        _ => None,
    }
}

/// 一条待执行的安装命令。
#[derive(Debug, Clone)]
pub struct ProcSpec {
    pub program: String,
    pub args: Vec<String>,
}

fn cmd_spec(args: &[&str]) -> ProcSpec {
    ProcSpec {
        program: "cmd".to_string(),
        args: std::iter::once("/C".to_string())
            .chain(args.iter().map(|s| s.to_string()))
            .collect(),
    }
}

/// 组装某个 Agent 某种方式的安装命令序列（纯函数，可测试）。
pub(crate) fn build_install_plan(agent_id: &str, method_id: &str) -> Result<Vec<ProcSpec>, String> {
    match (agent_id, method_id) {
        ("claude-code", "native") => Ok(vec![ProcSpec {
            program: "powershell".to_string(),
            args: [
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                "irm https://claude.ai/install.ps1 | iex",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
        }]),
        (_, "npm") => {
            let pkg = npm_package(agent_id)
                .ok_or_else(|| format!("agent '{agent_id}' has no npm package"))?;
            Ok(vec![cmd_spec(&["npm", "install", "-g", pkg])])
        }
        ("aider", "pip") => Ok(vec![
            cmd_spec(&["python", "-m", "pip", "install", "aider-install"]),
            cmd_spec(&["aider-install"]),
        ]),
        _ => Err(format!("unsupported install method: {agent_id}/{method_id}")),
    }
}

// ─── NVM / Node 安装 ──────────────────────────────────────────────────────────

/// 校验并归一化用户输入的 Node 版本号（"v22.14.0" → "22.14.0"；放行 nvm 别名）。
pub fn validate_version_input(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim().trim_start_matches('v');
    if trimmed == "latest" || trimmed == "lts" {
        return Ok(trimmed.to_string());
    }
    let re = Regex::new(r"^\d+(\.\d+){0,2}$").expect("static regex");
    if re.is_match(trimmed) {
        Ok(trimmed.to_string())
    } else {
        Err(format!("无效的 Node 版本号：{raw}"))
    }
}

/// NVM 未安装时先走这里：winget 优先，官方静默安装包兜底。
pub fn install_nvm(sink: Option<&EventSink>) -> Result<serde_json::Value, String> {
    let task = "nvm";
    let result = install_nvm_inner(sink, task);
    let ok = result.is_ok();
    emit_done(sink, task, ok, result.as_ref().err().cloned());
    result
}

fn install_nvm_inner(sink: Option<&EventSink>, task: &str) -> Result<serde_json::Value, String> {
    if let Some(root) = locate_nvm() {
        return Ok(serde_json::json!({ "alreadyInstalled": true, "root": root }));
    }

    // 1) winget（Win10+ 一般都有；可能弹 UAC）
    let winget = agent_discovery::locate_command("winget");
    if let Some(winget) = winget {
        emit_log(
            sink,
            task,
            &format!("尝试通过 winget 安装 NVM（{WINGET_NVM_ID}）…"),
        );
        let plan = vec![ProcSpec {
            program: winget,
            args: [
                "install",
                "-e",
                "--id",
                WINGET_NVM_ID,
                "--accept-source-agreements",
                "--accept-package-agreements",
                "--disable-interactivity",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
        }];
        if let Err(e) = run_streamed(task, &plan, sink) {
            emit_log(sink, task, &format!("winget 安装失败（{e}），改用官方安装包…"));
        }
    } else {
        emit_log(sink, task, "未找到 winget，改用官方安装包…");
    }

    if let Some(root) = locate_nvm() {
        return Ok(serde_json::json!({ "installed": true, "root": root }));
    }

    // 2) 官方 nvm-setup.exe（NSIS 支持 /S 静默；机器级安装，会弹 UAC）
    let dest = std::env::temp_dir().join("brewping-nvm-setup.exe");
    emit_log(sink, task, &format!("下载 NVM 安装包：{NVM_SETUP_URL}"));
    download_to_file(NVM_SETUP_URL, &dest)?;
    emit_log(sink, task, "静默安装 NVM（Windows 可能弹出 UAC 授权窗口，请允许）…");
    let installer = dest.to_string_lossy().to_string();
    run_streamed(
        task,
        &[ProcSpec {
            program: installer,
            args: vec!["/S".to_string()],
        }],
        sink,
    )?;

    match locate_nvm() {
        Some(root) => Ok(serde_json::json!({ "installed": true, "root": root })),
        None => Err(
            "NVM 安装程序已执行，但未检测到 NVM_HOME。可能需要重启 BrewPing 让 PATH 生效；\
             也可以手动安装：https://github.com/coreybutler/nvm-windows"
                .to_string(),
        ),
    }
}

/// 定位 nvm.exe（PATH → NVM_HOME 注册表/env 目录）。
fn locate_nvm() -> Option<String> {
    if let Some(path) = agent_discovery::locate_command("nvm") {
        return Some(path);
    }
    let root = agent_discovery::nvm_home()?;
    let exe = Path::new(&root).join("nvm.exe");
    exe.exists().then(|| exe.to_string_lossy().to_string())
}

/// 经 NVM 安装并启用指定版本的 Node。返回实际安装的版本号。
pub fn install_node(version: &str, sink: Option<&EventSink>) -> Result<String, String> {
    let task = "node";
    let result = install_node_inner(version, sink, task);
    let ok = result.is_ok();
    emit_done(sink, task, ok, result.as_ref().err().cloned());
    result
}

fn install_node_inner(version: &str, sink: Option<&EventSink>, task: &str) -> Result<String, String> {
    let nvm_exe = locate_nvm()
        .ok_or_else(|| "NVM 未安装：请先安装 NVM，再通过它安装 Node".to_string())?;
    let version = validate_version_input(version)?;

    emit_log(sink, task, &format!("nvm install {version}（下载 Node，可能需要几分钟）…"));
    run_streamed(
        task,
        &[ProcSpec {
            program: nvm_exe.clone(),
            args: vec!["install".to_string(), version.to_string()],
        }],
        sink,
    )?;

    // nvm use 需要重建符号链接，在受保护目录时会触发 UAC；被拒绝时版本目录
    // 仍然可用（CLI 安装靠 extra_path_dirs 直接找到 node），所以失败只记日志。
    emit_log(sink, task, &format!("nvm use {version}（可能弹出 UAC 授权窗口）…"));
    if let Err(e) = run_streamed(
        task,
        &[ProcSpec {
            program: nvm_exe.clone(),
            args: vec!["use".to_string(), version.clone()],
        }],
        sink,
    ) {
        emit_log(sink, task, &format!("nvm use 未完全生效（{e}）；Node 已装好，CLI 安装不受影响"));
    }

    // 验证：优先 `nvm current`（对 latest/lts 别名也能给出真实版本），
    // 回落到版本目录直查；再跑一次 node --version 确认可执行。
    let actual = nvm_current(&nvm_exe)
        .or_else(|| match version_dir(&version) {
            Some(dir) => node_version_from_dir(&dir),
            None => None,
        })
        .ok_or_else(|| format!("Node {version} 安装后未检测到（nvm current 无输出且版本目录缺失）"))?;
    emit_log(sink, task, &format!("Node {actual} 安装完成 ✓"));
    Ok(actual)
}

/// `nvm current` 输出解析（"v22.14.0"）。
fn nvm_current(nvm_exe: &str) -> Option<String> {
    let out = agent_discovery::run_capture(nvm_exe, &["current"]);
    let first = out.lines().next()?.trim().trim_start_matches('v').to_string();
    (!first.is_empty()).then_some(first)
}

/// NVM_HOME 下某个版本的安装目录（v 前缀 / 裸名都试）。
fn version_dir(version: &str) -> Option<PathBuf> {
    let home = agent_discovery::nvm_home()?;
    for candidate in [format!("v{version}"), version.to_string()] {
        let dir = Path::new(&home).join(&candidate);
        if dir.is_dir() {
            return Some(dir);
        }
    }
    None
}

fn node_version_from_dir(dir: &Path) -> Option<String> {
    let node = dir.join("node.exe");
    agent_discovery::get_version(&node.to_string_lossy(), &["--version"])
        .map(|v| v.trim_start_matches('v').to_string())
}

// ─── Agent CLI 安装 ───────────────────────────────────────────────────────────

/// 执行某个 Agent 的官方安装，成功后重新检测并返回最新状态。
pub fn install_agent_cli(
    agent_id: &str,
    method_id: &str,
    sink: Option<&EventSink>,
) -> Result<AgentCliStatus, String> {
    let task = format!("cli:{agent_id}");
    let result = install_agent_cli_inner(agent_id, method_id, sink, &task);
    let ok = result.is_ok();
    emit_done(sink, &task, ok, result.as_ref().err().cloned());
    result
}

fn install_agent_cli_inner(
    agent_id: &str,
    method_id: &str,
    sink: Option<&EventSink>,
    task: &str,
) -> Result<AgentCliStatus, String> {
    let (name, command) = agent_discovery::catalog_definition(agent_id)
        .ok_or_else(|| format!("unknown agent: {agent_id}"))?;

    // 执行前的最后一道校验（UI 已按 blocked 字段禁用，这里双保险）
    let node = probe_node();
    let python = probe_python();
    let methods = install_methods_for(agent_id, node.major, python.installed);
    let method = methods
        .iter()
        .find(|m| m.id == method_id)
        .ok_or_else(|| format!("unknown install method: {method_id}"))?;
    if let Some(reason) = &method.blocked {
        return Err(match reason.as_str() {
            "node" => "Node.js 未安装：请先在上方通过 NVM 安装 Node".to_string(),
            "node-version" => format!(
                "Node 版本过旧（当前 {}，该方式需要 ≥ {}）",
                node.version.as_deref().unwrap_or("?"),
                method.min_node_major
            ),
            "python" => "Python 未安装：Aider 需要 Python 3.9+（python.org 安装）".to_string(),
            other => format!("前置条件不满足：{other}"),
        });
    }

    let plan = build_install_plan(agent_id, method_id)?;
    emit_log(sink, task, &format!("开始安装 {name}（{method_id}）…"));
    run_streamed(task, &plan, sink)?;

    // 重新检测（locate_command 已覆盖 nvm 版本目录 / npm 全局目录 / ~\.local\bin）
    match agent_discovery::locate_command(command) {
        Some(path) => {
            let version = agent_discovery::get_version(&path, &["--version"]);
            emit_log(
                sink,
                task,
                &format!("{name} 安装完成 ✓ {}", version.as_deref().unwrap_or("")),
            );
            Ok(AgentCliStatus {
                id: agent_id.to_string(),
                name: name.to_string(),
                installed: true,
                version,
                path: Some(path),
                methods,
            })
        }
        None => Err(format!(
            "安装命令已执行完成，但未检测到 {command}。请尝试「重新检测」；\
             若仍未识别，可能需要重启 BrewPing 让 PATH 生效"
        )),
    }
}

// ─── Node 版本清单 ────────────────────────────────────────────────────────────

/// 拉取可安装的 Node 版本（nodejs.org dist index → 按大版本聚合，离线回落别名）。
pub fn fetch_node_versions() -> Vec<NodeVersionOption> {
    match fetch_dist_index() {
        Some(entries) if !entries.is_empty() => build_version_options(&entries),
        _ => fallback_version_options(),
    }
}

#[derive(serde::Deserialize)]
struct DistEntry {
    version: String,
    #[serde(default)]
    lts: serde_json::Value,
}

fn http_agent(timeout: Duration) -> ureq::Agent {
    ureq::AgentBuilder::new().timeout(timeout).build()
}

fn fetch_dist_index() -> Option<Vec<DistEntry>> {
    let body = http_agent(Duration::from_secs(10))
        .get(NODE_DIST_INDEX_URL)
        .call()
        .ok()?
        .into_string()
        .ok()?;
    serde_json::from_str(&body).ok()
}

/// 按大版本聚合（每条取该大版本最新），新版本在前，推荐 = 最新 LTS。
fn build_version_options(entries: &[DistEntry]) -> Vec<NodeVersionOption> {
    // dist index 本身按版本降序；首个遇到的大版本即该线最新
    let mut seen: Vec<(u32, &DistEntry)> = Vec::new();
    for entry in entries {
        let Some(major) = node_major_from_version(&entry.version) else {
            continue;
        };
        if !seen.iter().any(|(m, _)| *m == major) {
            seen.push((major, entry));
        }
    }
    seen.sort_by(|a, b| b.0.cmp(&a.0));
    seen.iter()
        .filter(|(major, _)| *major >= 18)
        .take(10)
        .map(|(major, entry)| {
            let lts_name = entry.lts.as_str().map(str::to_string);
            NodeVersionOption {
                version: entry.version.trim_start_matches('v').to_string(),
                major: Some(*major),
                lts: lts_name.is_some(),
                lts_name,
                recommended: false,
            }
        })
        .collect::<Vec<_>>()
        .tap_mut(|options| {
            // 推荐项 = 大版本号最大的 LTS 线
            if let Some(idx) = options.iter().position(|o| o.lts) {
                options[idx].recommended = true;
            }
        })
}

/// 离线兜底：nvm-windows 支持的 `latest` / `lts` 别名（具体版本号联网后可再取）。
fn fallback_version_options() -> Vec<NodeVersionOption> {
    vec![
        NodeVersionOption {
            version: "lts".to_string(),
            major: None,
            lts: true,
            lts_name: Some("LTS".to_string()),
            recommended: true,
        },
        NodeVersionOption {
            version: "latest".to_string(),
            major: None,
            lts: false,
            lts_name: None,
            recommended: false,
        },
    ]
}

fn download_to_file(url: &str, dest: &Path) -> Result<u64, String> {
    let mut reader = http_agent(Duration::from_secs(180))
        .get(url)
        .call()
        .map_err(|e| format!("下载失败：{e}"))?
        .into_reader();
    let mut file = std::fs::File::create(dest)
        .map_err(|e| format!("无法创建临时文件 {}：{e}", dest.display()))?;
    std::io::copy(&mut reader, &mut file).map_err(|e| format!("下载中断：{e}"))
}

// ─── 流式执行器 ───────────────────────────────────────────────────────────────

/// 逐行执行安装命令并把输出以 `env-setup-log` 事件流给前端。
///
/// - PATH 注入 `extra_path_dirs()`：本进程 PATH 过期（刚装完 NVM/Node）时也能找到
///   npm / node / 新装的 CLI；
/// - stdout/stderr 并发读（stderr 管道写满会死锁）；
/// - 任一命令非零退出 → Err（带末尾日志），后续命令不再执行。
pub fn run_streamed(task: &str, plan: &[ProcSpec], sink: Option<&EventSink>) -> Result<(), String> {
    let mut recent: std::collections::VecDeque<String> = std::collections::VecDeque::new();
    for spec in plan {
        let display = format!("$ {} {}", spec.program, spec.args.join(" "));
        emit_log(sink, task, &display);
        recent.push_back(display.clone());
        if recent.len() > 40 {
            recent.pop_front();
        }

        let mut cmd = Command::new(&spec.program);
        cmd.args(&spec.args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        patch_path(&mut cmd);
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(CREATE_NO_WINDOW);
        }

        let mut child = cmd
            .spawn()
            .map_err(|e| format!("无法启动 {}：{e}", spec.program))?;
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();

        let (tx, rx) = std::sync::mpsc::channel::<String>();
        let tx_err = tx.clone();
        let err_handle = std::thread::spawn(move || {
            if let Some(pipe) = stderr {
                pump_lines(pipe, tx_err);
            }
        });
        if let Some(pipe) = stdout {
            pump_lines(pipe, tx);
        }
        let _ = err_handle.join();

        for line in rx {
            emit_log(sink, task, &line);
            recent.push_back(line);
            if recent.len() > 40 {
                recent.pop_front();
            }
        }

        let status = child
            .wait()
            .map_err(|e| format!("等待进程退出失败：{e}"))?;
        if !status.success() {
            let code = status.code().unwrap_or(-1);
            return Err(format!("命令失败（退出码 {code}）：\n{}", recent.iter().rev().take(12).rev().cloned().collect::<Vec<_>>().join("\n")));
        }
    }
    Ok(())
}

/// 逐行读管道并发送（行尾剥 \r：npm/winget 的进度条用 \r 刷新）。
fn pump_lines<R: std::io::Read>(pipe: R, tx: std::sync::mpsc::Sender<String>) {
    let reader = BufReader::new(pipe);
    for line in reader.lines() {
        match line {
            Ok(l) => {
                let l = l.trim_end_matches('\r');
                if !l.is_empty() && tx.send(l.to_string()).is_err() {
                    break;
                }
            }
            Err(_) => break,
        }
    }
}

/// 给子进程注入补全后的 PATH（extra 目录在前，原有 PATH 在后）。
fn patch_path(cmd: &mut Command) {
    if let Ok(existing) = std::env::var("PATH") {
        let sep = if cfg!(windows) { ";" } else { ":" };
        let extra = agent_discovery::extra_path_dirs().join(sep);
        cmd.env("PATH", format!("{extra}{sep}{existing}"));
    }
}

fn emit_log(sink: Option<&EventSink>, task: &str, line: &str) {
    if let Some(sink) = sink {
        sink(
            "env-setup-log",
            serde_json::json!({ "task": task, "line": line }),
        );
    }
}

fn emit_done(sink: Option<&EventSink>, task: &str, ok: bool, error: Option<String>) {
    if let Some(sink) = sink {
        sink(
            "env-setup-done",
            serde_json::json!({ "task": task, "ok": ok, "error": error }),
        );
    }
}

// ─── 会话状态（lib.rs DesktopCore 持有）───────────────────────────────────────

/// 本会话内的环境安装进度记忆。当前仅记录「经 NVM 装好的 Node 版本」，
/// 供 CLI 安装路径在进程 PATH 未刷新时也能找到 node/npm。
#[derive(Default)]
pub struct EnvSetupState {
    pub session_node_version: std::sync::Mutex<Option<String>>,
}

impl EnvSetupState {
    pub fn new() -> Self {
        Self::default()
    }
}

// 允许在迭代器上做收尾小动作的私有扩展（避免为两行代码引 itertools）。
trait TapMut: Sized {
    fn tap_mut<F: FnOnce(&mut Self)>(self, f: F) -> Self {
        let mut this = self;
        f(&mut this);
        this
    }
}
impl<T> TapMut for T {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    fn collector() -> (Arc<Mutex<Vec<String>>>, EventSink) {
        let lines = Arc::new(Mutex::new(Vec::new()));
        let sink_lines = lines.clone();
        let sink: EventSink = Arc::new(move |event, payload| {
            if event == "env-setup-log" {
                if let Some(line) = payload.get("line").and_then(|v| v.as_str()) {
                    sink_lines.lock().unwrap().push(line.to_string());
                }
            }
        });
        (lines, sink)
    }

    // TC-ES-01  版本号归一化：v 前缀剥离、别名放行、垃圾拒绝
    #[test]
    fn validate_version_input_normalizes() {
        assert_eq!(validate_version_input(" 22.14.0 "), Ok("22.14.0".to_string()));
        assert_eq!(validate_version_input("v24.1.0"), Ok("24.1.0".to_string()));
        assert_eq!(validate_version_input("22"), Ok("22".to_string()));
        assert_eq!(validate_version_input("latest"), Ok("latest".to_string()));
        assert_eq!(validate_version_input("lts"), Ok("lts".to_string()));
        assert!(validate_version_input("abc").is_err());
        assert!(validate_version_input("22.14.0-x").is_err());
        assert!(validate_version_input("").is_err());
    }

    // TC-ES-02  安装规格完整性：目录内每个 agent 都有方式，包名与官方一致
    #[test]
    fn install_plans_cover_catalog_with_official_commands() {
        for agent_id in ["claude-code", "opencode", "codex", "aider"] {
            assert!(
                agent_discovery::catalog_definition(agent_id).is_some(),
                "{agent_id} 必须在目录里"
            );
        }
        // claude-code 原生安装：powershell + 免 Node
        let native = build_install_plan("claude-code", "native").unwrap();
        assert_eq!(native.len(), 1);
        assert_eq!(native[0].program, "powershell");
        assert!(native[0].args.contains(&"irm https://claude.ai/install.ps1 | iex".to_string()));

        // npm 包名逐个核对
        let cases = [
            ("opencode", "opencode-ai"),
            ("codex", "@openai/codex"),
            ("claude-code", "@anthropic-ai/claude-code"),
        ];
        for (agent_id, pkg) in cases {
            let plan = build_install_plan(agent_id, "npm").unwrap();
            assert_eq!(plan[0].program, "cmd");
            assert!(plan[0].args.windows(2).any(|w| w[0] == "-g" && w[1] == pkg));
        }

        // aider：pip 安装器两步
        let pip = build_install_plan("aider", "pip").unwrap();
        assert_eq!(pip.len(), 2);
        assert!(pip[0].args.join(" ").contains("aider-install"));

        assert!(build_install_plan("opencode", "native").is_err());
        assert!(build_install_plan("unknown", "npm").is_err());
    }

    // TC-ES-03  前置校验（blocked）纯函数：各组合
    #[test]
    fn blocked_reason_matches_prerequisites() {
        // npm 方式：没 Node → node；Node 太旧 → node-version；够新 → 放行
        assert_eq!(blocked_reason(true, 22, None, false, true).as_deref(), Some("node"));
        assert_eq!(
            blocked_reason(true, 22, Some(18), false, true).as_deref(),
            Some("node-version")
        );
        assert_eq!(blocked_reason(true, 22, Some(22), false, true), None);
        // claude 原生安装不需要 Node
        assert_eq!(blocked_reason(false, 0, None, false, false), None);
        // aider 需要 Python
        assert_eq!(blocked_reason(false, 0, Some(22), true, false).as_deref(), Some("python"));
    }

    // TC-ES-04  node 大版本解析
    #[test]
    fn node_major_from_version_parses() {
        assert_eq!(node_major_from_version("v22.14.0"), Some(22));
        assert_eq!(node_major_from_version("22.14.0"), Some(22));
        assert_eq!(node_major_from_version("10.9.2"), Some(10));
        assert_eq!(node_major_from_version("garbage"), None);
    }

    // TC-ES-05  版本清单聚合：按大版本取最新、降序、推荐 = 最新 LTS
    #[test]
    fn build_version_options_groups_by_major() {
        let entries: Vec<DistEntry> = serde_json::from_str(
            r#"[
            {"version":"v25.0.0","date":"2025-10-01","lts":false},
            {"version":"v24.10.0","date":"2025-11-01","lts":"Krypton"},
            {"version":"v24.1.0","date":"2025-05-01","lts":false},
            {"version":"v22.14.0","date":"2025-02-01","lts":"Jod"},
            {"version":"v18.20.0","date":"2024-03-01","lts":"Hydrogen"}
        ]"#,
        )
        .unwrap();
        let options = build_version_options(&entries);
        let versions: Vec<&str> = options.iter().map(|o| o.version.as_str()).collect();
        assert_eq!(versions, vec!["25.0.0", "24.10.0", "22.14.0", "18.20.0"]);
        assert!(!options[0].lts);
        assert_eq!(options[1].lts_name.as_deref(), Some("Krypton"));
        // 推荐 = 最新 LTS 线的最新版
        assert!(options.iter().find(|o| o.version == "24.10.0").unwrap().recommended);
        assert!(!options[0].recommended);
        // 别名选项结构
        let fallback = fallback_version_options();
        assert_eq!(fallback[0].version, "lts");
        assert!(fallback[0].recommended);
    }

    // TC-ES-06  流式执行：成功路径捕获输出并经 sink 广播
    #[cfg(windows)]
    #[test]
    fn run_streamed_captures_output() {
        let (lines, sink) = collector();
        let plan = vec![ProcSpec {
            program: "cmd".to_string(),
            args: vec!["/C".to_string(), "echo brewping-stream-ok".to_string()],
        }];
        run_streamed("test", &plan, Some(&sink)).expect("echo 应当成功");
        let got = lines.lock().unwrap();
        assert!(
            got.iter().any(|l| l.contains("brewping-stream-ok")),
            "输出必须经 sink 广播，实际：{got:?}"
        );
        assert!(got.iter().any(|l| l.starts_with("$ cmd")), "应记录命令行本身");
    }

    // TC-ES-07  流式执行：非零退出返回 Err 且携带退出码
    #[cfg(windows)]
    #[test]
    fn run_streamed_reports_failure() {
        let plan = vec![ProcSpec {
            program: "cmd".to_string(),
            args: vec!["/C".to_string(), "exit 7".to_string()],
        }];
        let err = run_streamed("test", &plan, None).unwrap_err();
        assert!(err.contains("7"), "错误信息应包含退出码：{err}");
    }

    // TC-ES-08  版本目录定位与 CLI 状态投影（serde 契约冒烟）
    #[test]
    fn agent_status_serializes_with_expected_keys() {
        let status = AgentCliStatus {
            id: "opencode".into(),
            name: "OpenCode".into(),
            installed: false,
            version: None,
            path: None,
            methods: install_methods_for("opencode", None, false),
        };
        let v = serde_json::to_value(&status).unwrap();
        for key in ["id", "name", "installed", "version", "path", "methods"] {
            assert!(v.get(key).is_some(), "缺少字段 {key}");
        }
        let method = &v["methods"][0];
        assert_eq!(method["id"], "npm");
        assert_eq!(method["blocked"], "node", "没 Node 时 npm 方式必须被标记阻塞");
        assert!(method["display"].as_str().unwrap().contains("opencode-ai"));
        // blocked 用 camelCase 键
        assert!(v["methods"][0].get("minNodeMajor").is_some());
    }

    // TC-ES-09  真实环境检测（手工验证用：cargo test print_environment -- --ignored --nocapture）
    #[test]
    #[ignore]
    fn print_environment() {
        let env = check_environment();
        println!("node:   {:?}", env.node);
        println!("npm:    {:?}", env.npm);
        println!("nvm:    {:?}", env.nvm);
        println!("python: {:?}", env.python);
        for agent in &env.agents {
            println!(
                "agent {} installed={} version={:?} methods={}",
                agent.id,
                agent.installed,
                agent.version,
                agent.methods.iter().map(|m| format!("{}({:?})", m.id, m.blocked)).collect::<Vec<_>>().join(", ")
            );
        }
        println!("extra PATH dirs: {:?}", agent_discovery::extra_path_dirs());
    }
}
