//! 单实例守卫：同一个登录会话里**只允许跑一个 BrewPing**。
//!
//! # 为什么必须有这道闸
//!
//! 没有它的时候，重复双击图标会起第二个进程，而第二个进程照样会：
//! - 再起一遍 HTTP 服务 —— 8787 被占用后**静默回落到别的端口**；
//! - 再起一遍 mDNS 广播、再建一遍托盘图标。
//!
//! 结果是用户/手机端可能连到**旧的**那个实例（历史坑：「8787 被旧进程占 → curl 静默
//! 打旧进程」就是这么来的），而且托盘里出现两个一样的图标。
//!
//! # 机制
//!
//! 具名互斥体（`CreateMutexW`）：第一个进程创建成功并**持有句柄直到进程退出**；
//! 第二个进程创建同名互斥体时拿到 `ERROR_ALREADY_EXISTS`，于是把已有窗口拎到前台后
//! 自己直接退出。
//!
//! 用「会话内」命名空间（不写 `Global\` 前缀）——每个登录会话一个实例即可，
//! 不让别的用户的会话被牵连。
//!
//! 注意：`cargo test` 与真实应用用的是不同互斥体名（测试用随机后缀），
//! 这样「应用正在运行时跑测试」不会互相干扰。

/// 互斥体名。后缀是固定的随机串，避免与其它程序的同名互斥体相撞。
const MUTEX_NAME: &str = "BrewPing.SingleInstance.6f1c9d2a";

/// 主窗口标题，**必须**与 `tauri.conf.json` 的 `app.windows[0].title` 一致 ——
/// 第二个实例靠它把已有窗口找回来。
const MAIN_WINDOW_TITLE: &str = "BrewPing";

/// 拿到窗口后最多重试几次（每次 300ms）。
/// 让「第一个实例还在初始化、窗口尚未创建」时也能等到它出现。
const FOCUS_RETRIES: u32 = 5;

#[cfg(windows)]
mod imp {
    use windows_sys::Win32::Foundation::{GetLastError, ERROR_ALREADY_EXISTS};
    use windows_sys::Win32::System::Threading::CreateMutexW;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        FindWindowW, SetForegroundWindow, ShowWindow, SW_RESTORE,
    };

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    /// 尝试成为唯一实例。`true` = 本进程就是第一个。
    ///
    /// 失败（`CreateMutexW` 返回 0）时**放行**：宁可允许重复启动，
    /// 也不要因为一个 Win32 调用失败就把用户挡在应用外面。
    pub fn acquire(name: &str) -> bool {
        let name = wide(name);
        unsafe {
            // bInitialOwner = 0：只要「存在性」这一个语义，不取初始所有权。
            let handle = CreateMutexW(std::ptr::null(), 0, name.as_ptr());
            if handle == 0 {
                log::warn!("single-instance: CreateMutexW 失败，放行启动");
                return true;
            }
            // 句柄故意不关：它必须活到进程结束，才代表「本实例还活着」。
            // 进程退出时由内核自动回收。
            let already = GetLastError() == ERROR_ALREADY_EXISTS;
            if already {
                log::info!("single-instance: 已有实例在运行");
                false
            } else {
                true
            }
        }
    }

    /// 把已有实例的主窗口拎到前台。找不到就返回 false（调用方决定要不要重试）。
    pub fn focus_window(title: &str) -> bool {
        let title = wide(title);
        unsafe {
            let hwnd = FindWindowW(std::ptr::null(), title.as_ptr());
            if hwnd == 0 {
                return false;
            }
            // 先解除最小化再置前：只 SetForegroundWindow 对最小化窗口不生效。
            ShowWindow(hwnd, SW_RESTORE);
            SetForegroundWindow(hwnd);
            true
        }
    }
}

#[cfg(not(windows))]
mod imp {
    /// 非 Windows 不做限制：本 crate 只发布 Windows 安装包（NSIS/MSI），
    /// macOS 走独立的 SwiftPM 客户端。这里保持 no-op，避免引入跨平台文件锁的
    /// 崩溃残留问题。
    pub fn acquire(_name: &str) -> bool {
        true
    }

    pub fn focus_window(_title: &str) -> bool {
        false
    }
}

/// 本进程是否为唯一实例。`false` = 该退出了。
pub fn acquire() -> bool {
    imp::acquire(MUTEX_NAME)
}

/// 通知已有实例把窗口显示出来（带重试，等它把窗口建好）。
pub fn focus_existing() {
    for attempt in 0..FOCUS_RETRIES {
        if imp::focus_window(MAIN_WINDOW_TITLE) {
            return;
        }
        if attempt + 1 < FOCUS_RETRIES {
            std::thread::sleep(std::time::Duration::from_millis(300));
        }
    }
    log::warn!("single-instance: 没找到已有实例的窗口，仍然退出本进程");
}

#[cfg(all(test, windows))]
mod tests {
    use super::imp;

    /// 同名互斥体在同一进程里创建两次，第二次必须拿到 ALREADY_EXISTS。
    /// 用随机名，避免与真实运行中的应用（或其它测试）互踩。
    #[test]
    fn second_acquire_with_same_name_is_rejected() {
        let name = format!("BrewPing.SingleInstance.test.{}", uuid::Uuid::new_v4());
        assert!(imp::acquire(&name), "第一次应当拿到所有权");
        assert!(!imp::acquire(&name), "第二次必须被拒绝");
    }

    /// 不同名字互不影响（防止「一次误判把后来所有启动都挡掉」）。
    #[test]
    fn different_names_do_not_collide() {
        let a = format!("BrewPing.SingleInstance.test.{}", uuid::Uuid::new_v4());
        let b = format!("BrewPing.SingleInstance.test.{}", uuid::Uuid::new_v4());
        assert!(imp::acquire(&a));
        assert!(imp::acquire(&b));
    }

    /// 找不到窗口时必须安全返回，不能 panic（用户可能已把窗口关掉只留托盘）。
    #[test]
    fn focus_missing_window_is_safe() {
        let missing = format!("brewping-nonexistent-{}", uuid::Uuid::new_v4());
        assert!(!imp::focus_window(&missing));
    }
}
