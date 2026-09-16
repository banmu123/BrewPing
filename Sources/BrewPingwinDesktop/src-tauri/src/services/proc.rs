//! 子进程启动的 Windows 统一约定：**不留控制台窗口**。
//!
//! 背景：本应用的 CLI（`claude` / `codex` / `pi` / `opencode`）在 Windows 上普遍是
//! `.cmd` 批处理包装（npm 全局 bin、scoop shims、`.local\bin`），`Command::new("claude")`
//! 实际会经由 `cmd.exe /c ...` 启动。若不给子进程加 `CREATE_NO_WINDOW`，
//! **每 spawn 一次就弹一个黑窗**——而这在一条启动链上会重复很多次：
//!
//! - `lib.rs` 的 `setup()` → `agent_discovery::discover()`：4 个 agent 各跑一次
//!   `get_version()`（`claude --version` …），每次 `locate_command()` 落空还会再跑
//!   `npm config get prefix`；
//! - 托盘菜单（`tray.rs`）、`/api/discovery/refresh`（`http_server.rs`）、
//!   设置页环境检测（`env_setup.rs`）会各自再触发一遍。
//!
//! 于是「打开应用」和「点开托盘」都会满屏 cmd 黑框。
//!
//! ⚠️ 这不是权限 / 授权问题：那些窗口不承载任何确认交互，只是 Windows 的
//! 「控制台子系统进程默认分配新控制台」行为。应用自身已由 `main.rs` 的
//! `windows_subsystem = "windows"` 免疫，**子进程必须逐个显式声明**。
//!
//! 规则：本 crate 内**任何** `std::process::Command` 在 `spawn()` / `output()` /
//! `status()` 之前都必须调用 [`hide_console`]。新增 spawn 点时不要漏。
//!
//! # 机理（踩过一次，别再来）
//!
//! `CREATE_NO_WINDOW` 的准确语义是「**不新建**控制台窗口」，不是「剥离控制台」：
//! - 打包后的应用是 GUI 子系统（`main.rs` 的 `windows_subsystem = "windows"`），
//!   进程**没有**控制台 → 子进程没有可继承的控制台、又不被新建 → **不弹窗** ✅
//! - 从终端里跑（`npm run tauri dev` / `cargo run`）时父进程**有**控制台 →
//!   子进程**继承**它，本来也不弹新窗；此时加不加标志肉眼无差别。
//!
//! 所以：**这个 bug 只在安装包/双击启动的 GUI 进程上复现**，在开发模式下看不出来；
//! 也无法用单元测试断言（`cargo test` 的宿主自身带控制台，子进程必然报「有控制台」）。
//! 验证方式只有一个：装包后启动应用，看是否还有黑框闪现。

use std::process::Command;

/// `CREATE_NO_WINDOW`：子进程不新建控制台窗口（Win32 进程创建标志）。
#[cfg(windows)]
pub const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// 抑制子进程的控制台窗口。所有 `Command` 在启动前调用。
///
/// 非 Windows 平台是空操作（本应用只发布 macOS / Windows）。
///
/// ```ignore
/// let mut cmd = Command::new("claude");
/// cmd.arg("--version");
/// hide_console(&mut cmd);
/// let out = cmd.output()?;
/// ```
pub fn hide_console(cmd: &mut Command) -> &mut Command {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    cmd
}

#[cfg(test)]
mod tests {
    use super::*;

    /// ★ 守住常量本身：Win32 文档值是 `0x0800_0000`。
    ///
    /// 这个常量是**唯一**在起作用的开关 —— 写错一个 `0`（例如 `0x0080_0000`）不会
    /// 编译报错、不会让任何测试变红，只会让黑窗悄悄回来。所以把字面值钉死。
    ///
    /// 为什么不直接断言「子进程没有控制台」：`CREATE_NO_WINDOW` 的语义是**不新建**
    /// 控制台窗口；子进程仍会**继承**父进程已有的控制台。因此从带控制台的宿主
    /// （`cargo test`）里 spawn 出来的子进程必然报「有控制台」，无法区分加没加标志。
    /// 真正生效的场景是打包后的 GUI 进程 —— 父进程是 `windows_subsystem = "windows"`
    /// （无控制台），子进程既不能继承、又不被新建，于是不弹窗。
    /// 该性质只能在**跑起来的 GUI 应用**上肉眼验证，不能靠单元测试覆盖。
    #[cfg(windows)]
    #[test]
    fn create_no_window_matches_win32_contract() {
        assert_eq!(CREATE_NO_WINDOW, 0x0800_0000);
    }

    /// `hide_console` 只关窗口，**不能**吞掉子进程的 stdout / stderr ——
    /// 一旦标志误伤管道，所有 CLI 输出采集（版本探测、agent 流式输出）会一起失灵。
    #[cfg(windows)]
    #[test]
    fn hide_console_keeps_stdio_intact() {
        let mut cmd = Command::new("cmd");
        cmd.args(["/C", "echo brewping-hidden-console"]);
        let out = hide_console(&mut cmd).output().expect("cmd 应能启动");
        assert!(
            String::from_utf8_lossy(&out.stdout).contains("brewping-hidden-console"),
            "stdout 被 hide_console 影响：{:?}",
            String::from_utf8_lossy(&out.stdout)
        );
        assert!(out.status.success());
    }

    /// stderr 同理可用（`2>&1` 经 cmd 转发）。
    #[cfg(windows)]
    #[test]
    fn hide_console_keeps_stderr_intact() {
        let mut cmd = Command::new("cmd");
        cmd.args(["/C", "echo oops 1>&2"]);
        let out = hide_console(&mut cmd).output().expect("cmd 应能启动");
        assert!(String::from_utf8_lossy(&out.stderr).contains("oops"));
    }

}
