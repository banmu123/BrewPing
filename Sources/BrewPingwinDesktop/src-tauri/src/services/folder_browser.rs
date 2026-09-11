//! 目录浏览服务（Windows 端）。
//!
//! 对应 Lody `local-project-control-service.ts` 的 `listBrowseRoots()` / `browseDirectory()`。
//! 纯逻辑、无 HTTP、无 Tauri 依赖 —— HTTP handler 与 Tauri command 都薄薄地调它，
//! 保证只有一份实现。
//!
//! 与 macOS/Linux 的三处关键差异：
//!   1. 根是**盘符**（不能 A–Z 探测，见 `list_drives` 注释）；
//!   2. 隐藏是 **FILE_ATTRIBUTE_HIDDEN 属性位**，不是 dotfile；
//!   3. realpath 必须剥离 `\\?\` verbatim 前缀（dunce）。

use serde::Serialize;
use std::path::{Path, PathBuf};

/// 单页默认条目数（对齐 Lody DEFAULT_LOCAL_PROJECT_BROWSE_DIR_LIMIT）。
pub const DEFAULT_LIMIT: usize = 200;
/// 单页硬上限（对齐 Lody HARD_LOCAL_PROJECT_BROWSE_DIR_LIMIT）。
pub const HARD_LIMIT: usize = 1000;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowseRoots {
    /// `std::env::consts::OS` → Windows 上是 `"windows"`。
    /// 注意 Lody 用 Node 的 `process.platform` → `"win32"`，两端取值不同，
    /// 客户端不得硬编码（方案 §3.1）。
    pub platform: &'static str,
    pub path_separator: &'static str,
    pub home_dir: String,
    /// 仅 Windows 有；其它平台为空数组。
    pub drives: Vec<String>,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct BrowseHints {
    pub git: bool,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BrowseEntry {
    pub name: String,
    /// 已 realpath 且已剥 `\\?\` 前缀。
    pub absolute_path: String,
    pub is_symlink: bool,
    pub hidden: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hints: Option<BrowseHints>,
    /// 目前只有一种取值："unreadable"。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<&'static str>,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BrowseResult {
    pub path: String,
    /// `C:\` 的 parent 为 None（Windows 上 `Path::parent("C:\\")` 即返回 None）。
    pub parent_path: Option<String>,
    pub entries: Vec<BrowseEntry>,
    pub truncated: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BrowseError {
    PathInvalid,
    UncNotAllowed,
    OutsideAllowlist,
    PermissionDenied,
    ExecutionFailed,
}

impl BrowseError {
    pub fn code(self) -> &'static str {
        match self {
            Self::PathInvalid => "path-invalid",
            Self::UncNotAllowed => "unc-not-allowed",
            Self::OutsideAllowlist => "path-outside-allowlist",
            Self::PermissionDenied => "permission-denied",
            Self::ExecutionFailed => "execution-failed",
        }
    }

    pub fn status(self) -> u16 {
        match self {
            Self::OutsideAllowlist | Self::PermissionDenied => 403,
            Self::UncNotAllowed | Self::PathInvalid => 400,
            Self::ExecutionFailed => 500,
        }
    }
}

// ─── 根列表 ──────────────────────────────────────────────────────────────────

pub fn list_roots() -> BrowseRoots {
    let home = dirs::home_dir()
        .map(|p| simplified(&p))
        .unwrap_or_default();
    BrowseRoots {
        platform: std::env::consts::OS, // Windows → "windows"
        path_separator: std::path::MAIN_SEPARATOR_STR,
        home_dir: home,
        drives: list_drives(),
    }
}

#[cfg(windows)]
fn list_drives() -> Vec<String> {
    // DRIVE_* 常量在 windows-sys 0.52 里位于 WindowsProgramming 模块（不是 Storage::FileSystem）
    use windows_sys::Win32::Storage::FileSystem::{GetDriveTypeW, GetLogicalDrives};
    use windows_sys::Win32::System::WindowsProgramming::{
        DRIVE_FIXED, DRIVE_REMOVABLE, DRIVE_REMOTE,
    };

    // ★ 必须用 GetLogicalDrives 位掩码。禁止 A–Z 逐个 Path::exists() 探测：
    //   空光驱 / 断开的网络映射盘会让 exists() 阻塞数秒，26 次能直接打到超时。
    let mask = unsafe { GetLogicalDrives() };
    let mut out = Vec::new();
    for i in 0..26u32 {
        if mask & (1 << i) == 0 {
            continue;
        }
        let root = format!("{}:\\", (b'A' + i as u8) as char);
        let wide: Vec<u16> = root.encode_utf16().chain(std::iter::once(0)).collect();
        let kind = unsafe { GetDriveTypeW(wide.as_ptr()) };
        if matches!(kind, DRIVE_FIXED | DRIVE_REMOVABLE | DRIVE_REMOTE) {
            out.push(root);
        }
    }
    out
}

#[cfg(not(windows))]
fn list_drives() -> Vec<String> {
    Vec::new()
}

// ─── 目录浏览 ────────────────────────────────────────────────────────────────

pub fn browse_directory(
    absolute_path: Option<&str>,
    show_hidden: bool,
    limit: Option<usize>,
    cursor: Option<&str>,
) -> Result<BrowseResult, BrowseError> {
    // 步骤 1：缺省回退 home（Lody: resolveLocalProjectBrowsePath()）。
    let requested: PathBuf = match absolute_path.map(str::trim) {
        Some(p) if !p.is_empty() => PathBuf::from(p),
        _ => dirs::home_dir().ok_or(BrowseError::PathInvalid)?,
    };

    // 步骤 1.5（Windows 特有）：UNC 必须在 realpath **之前**拒绝。
    //   \\attacker\share 会触发 SMB 认证 → 主机名与 NTLM 哈希外泄。
    //   注意 \\?\ 是合法的 verbatim 前缀，不算 UNC。
    let raw = requested.to_string_lossy();
    if raw.starts_with("\\\\") && !raw.starts_with("\\\\?\\") {
        return Err(BrowseError::UncNotAllowed);
    }

    // 步骤 2：realpath + 目录校验。dunce 会剥离 \\?\ 前缀。
    let real = dunce::canonicalize(&requested).map_err(|_| BrowseError::PathInvalid)?;
    let meta = std::fs::metadata(&real).map_err(|_| BrowseError::PathInvalid)?;
    if !meta.is_dir() {
        return Err(BrowseError::PathInvalid);
    }

    // 步骤 2.5：白名单必须作用在 realpath 之后 ——
    //   允许根目录内的 junction 可指向任意位置，朴素前缀检查会被绕过。
    if !is_within_allowlist(&real) {
        return Err(BrowseError::OutsideAllowlist);
    }

    // 步骤 3：limit clamp + offset。宽容策略：非法值降级为缺省，不报错。
    let limit = limit.unwrap_or(DEFAULT_LIMIT).clamp(1, HARD_LIMIT);
    let offset: usize = cursor.and_then(|c| c.trim().parse().ok()).unwrap_or(0);

    // 步骤 5：readdir
    let reader = std::fs::read_dir(&real).map_err(|e| {
        if e.kind() == std::io::ErrorKind::PermissionDenied {
            BrowseError::PermissionDenied
        } else {
            BrowseError::ExecutionFailed
        }
    })?;

    let mut candidates: Vec<(String, PathBuf, bool)> = Vec::new(); // (name, realpath, is_symlink)

    for entry in reader {
        let Ok(entry) = entry else { continue };
        let name = entry.file_name().to_string_lossy().to_string();

        // 步骤 6a：跳过空 / . / ..
        if name.is_empty() || name == "." || name == ".." {
            continue;
        }

        // 步骤 6b：隐藏 = dotfile ∨ FILE_ATTRIBUTE_HIDDEN（两者都要认）。
        //   只判 dotfile 会漏掉 AppData、$RECYCLE.BIN 等绝大多数 Windows 隐藏目录。
        let hidden = name.starts_with('.') || is_hidden(&entry);
        if hidden && !show_hidden {
            continue;
        }

        // DirEntry::metadata() 不跟随 symlink，且无需额外系统调用。
        let Ok(md) = entry.metadata() else { continue };
        let is_link = md.file_type().is_symlink();

        // 步骤 6c：软链/junction 按 realpath 判定，失败（悬空链）静默跳过。
        let target = if is_link {
            match dunce::canonicalize(entry.path()) {
                Ok(p) => p,
                Err(_) => continue,
            }
        } else {
            entry.path()
        };

        // 步骤 6d：realpath 后不是目录 → 跳过（文件被过滤，空目录保留）。
        let Ok(tmd) = std::fs::metadata(&target) else { continue };
        if !tmd.is_dir() {
            continue;
        }

        candidates.push((name, target, is_link));
    }

    // 步骤 7：稳定排序。Windows 文件系统大小写不敏感，用不敏感比较更符合资源管理器直觉
    //   （与 Lody 的 localeCompare 不完全一致，这是有意的偏离）。
    candidates.sort_by(|l, r| l.0.to_lowercase().cmp(&r.0.to_lowercase()));

    // 步骤 8：分页
    let total = candidates.len();
    let start = offset.min(total);
    let end = (offset + limit).min(total);
    let page = &candidates[start..end];

    // 步骤 9：逐项组装
    let entries: Vec<BrowseEntry> = page
        .iter()
        .map(|(name, path, is_link)| {
            let absolute = simplified(path);
            BrowseEntry {
                name: name.clone(),
                absolute_path: absolute.clone(),
                is_symlink: *is_link,
                hidden: name.starts_with('.') || path_is_hidden(path),
                // .git 可能是**文件**（worktree / submodule），所以用 exists() 而非 is_dir()。
                hints: Some(BrowseHints {
                    git: Path::new(&absolute).join(".git").exists(),
                }),
                // ★ 只探测"能否列出该目录"，绝不读取文件内容 ——
                //   OneDrive 占位文件一旦被读就触发全量下载。
                error: if can_read_dir(path) { None } else { Some("unreadable") },
            }
        })
        .collect();

    // 步骤 10：游标就是 offset 的字符串形式，服务端无状态。
    let truncated = end < total;
    Ok(BrowseResult {
        path: simplified(&real),
        parent_path: parent_of(&real),
        entries,
        truncated,
        next_cursor: if truncated { Some(end.to_string()) } else { None },
    })
}

/// 校验一个候选 workdir：realpath + 是目录 + 非 UNC + 通过白名单。
/// 成功时返回剥掉 `\\?\` 的规范化路径（供存盘与展示）。
pub fn validate_workdir(path: &str) -> Result<String, BrowseError> {
    let trimmed = path.trim();
    if trimmed.starts_with("\\\\") && !trimmed.starts_with("\\\\?\\") {
        return Err(BrowseError::UncNotAllowed);
    }
    let requested = PathBuf::from(trimmed);
    let real = dunce::canonicalize(&requested).map_err(|_| BrowseError::PathInvalid)?;
    let meta = std::fs::metadata(&real).map_err(|_| BrowseError::PathInvalid)?;
    if !meta.is_dir() {
        return Err(BrowseError::PathInvalid);
    }
    if !is_within_allowlist(&real) {
        return Err(BrowseError::OutsideAllowlist);
    }
    Ok(simplified(&real))
}

/// 剥掉 Windows 的 `\\?\` verbatim 前缀，得到可展示、可回传前端的路径。
/// 非 Windows 平台上是恒等变换。
pub fn simplified(path: &Path) -> String {
    dunce::simplified(path).to_string_lossy().to_string()
}

/// `C:\` 的父目录必须是 `None`（Windows 上 `Path::parent` 天然如此，此处加显式保护）。
fn parent_of(dir: &Path) -> Option<String> {
    let parent = dir.parent()?;
    // 防御：某些输入下 parent 可能等于自身或退化成 drive-relative（"C:"），统一丢弃。
    if parent.as_os_str().is_empty() || parent == dir {
        return None;
    }
    let s = simplified(parent);
    // "C:" 这种无根形式对前端无意义，视为无父目录。
    if s.len() == 2 && s.ends_with(':') {
        return None;
    }
    Some(s)
}

#[cfg(windows)]
fn is_hidden(entry: &std::fs::DirEntry) -> bool {
    use std::os::windows::fs::MetadataExt;
    const FILE_ATTRIBUTE_HIDDEN: u32 = 0x2;
    entry
        .metadata()
        .map(|m| m.file_attributes() & FILE_ATTRIBUTE_HIDDEN != 0)
        .unwrap_or(false)
}

#[cfg(not(windows))]
fn is_hidden(_entry: &std::fs::DirEntry) -> bool {
    false
}

/// 已在候选列表中的路径，用属性位判隐藏（避免二次 stat 失败时误判）。
fn path_is_hidden(path: &Path) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_HIDDEN: u32 = 0x2;
        return std::fs::metadata(path)
            .map(|m| m.file_attributes() & FILE_ATTRIBUTE_HIDDEN != 0)
            .unwrap_or(false);
    }
    #[cfg(not(windows))]
    {
        let _ = path;
        false
    }
}

/// 只探测能否列出目录，**绝不读取任何文件内容**。
/// DirEntry 迭代器在此立即 drop，不消费任何条目 —— OneDrive 占位文件不会被下载。
fn can_read_dir(path: &Path) -> bool {
    std::fs::read_dir(path).is_ok()
}

/// 白名单判定：**必须**在 realpath 之后调用，且大小写归一化（NTFS 大小写不敏感）。
/// 规则：比较时归一化，存盘时保原样（丢大小写会让展示很难看）。
pub fn is_within_allowlist(real: &Path) -> bool {
    let Some(roots) = allowlist_roots() else {
        return true; // 未配置白名单 = 不限制（保持本机体验；跨机部署时应收紧）
    };
    let target = real.to_string_lossy().to_ascii_lowercase();
    roots.iter().any(|root| {
        let root = root.to_string_lossy().to_ascii_lowercase();
        let trimmed = root.trim_end_matches('\\');
        target == trimmed || target.starts_with(&format!("{}\\", trimmed))
    })
}

/// 白名单根集合。默认：home + 全部可枚举盘符（可在后续版本改为配置项 / 由 UI 管理）。
fn allowlist_roots() -> Option<Vec<PathBuf>> {
    let mut roots: Vec<PathBuf> = Vec::new();
    if let Some(home) = dirs::home_dir() {
        roots.push(home);
    }
    for drive in list_drives() {
        roots.push(PathBuf::from(drive));
    }
    if roots.is_empty() { None } else { Some(roots) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    fn temp_root(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("brewping-fb-{}-{}", tag, Uuid::new_v4().simple()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    // TC-FB-01  platform 必须是 "windows"（锁定，防止被改成 win32）
    #[test]
    fn roots_platform_is_windows() {
        let roots = list_roots();
        assert_eq!(roots.platform, "windows");
        assert_eq!(roots.path_separator, "\\");
        assert!(!roots.home_dir.is_empty(), "home 不应为空");
    }

    // TC-FB-02  盘符列表：每项以 :\ 结尾、无重复、非空
    #[test]
    fn drives_are_well_formed() {
        let drives = list_drives();
        assert!(!drives.is_empty(), "至少应有 C:");
        let mut seen = std::collections::HashSet::new();
        for d in &drives {
            assert!(d.ends_with(":\\"), "盘符应形如 C:\\，实际 {}", d);
            assert!(seen.insert(d.clone()), "盘符不应重复");
        }
    }

    // TC-FB-03  browse_directory(None, ...) 回退 home
    #[test]
    fn browse_defaults_to_home() {
        let result = browse_directory(None, false, None, None).expect("home 应可浏览");
        let home = dirs::home_dir().unwrap();
        let expected = dunce::canonicalize(&home).unwrap();
        assert_eq!(
            Path::new(&result.path).to_string_lossy().to_ascii_lowercase(),
            Path::new(&expected).to_string_lossy().to_ascii_lowercase()
        );
    }

    // TC-FB-04 / TC-FB-05  文件与不存在的路径 → PathInvalid
    #[test]
    fn file_and_missing_path_are_invalid() {
        let file = std::env::temp_dir().join(format!("brewping-fb-file-{}.txt", Uuid::new_v4().simple()));
        std::fs::write(&file, b"x").unwrap();
        assert_eq!(browse_directory(Some(file.to_str().unwrap()), false, None, None), Err(BrowseError::PathInvalid));
        assert_eq!(browse_directory(Some("C:\\definitely\\missing\\dir"), false, None, None), Err(BrowseError::PathInvalid));
        let _ = std::fs::remove_file(file);
    }

    // TC-FB-06  UNC 拒绝；\\?\ 前缀不算 UNC
    #[test]
    fn unc_is_rejected_but_verbatim_is_not() {
        assert_eq!(browse_directory(Some("\\\\server\\share"), false, None, None), Err(BrowseError::UncNotAllowed));
        // \\?\C:\ 应通过 UNC 检查（走到后面的 realpath 步骤）—— 这里只验证不返回 UncNotAllowed
        let r = browse_directory(Some("\\\\?\\C:\\"), false, None, None);
        assert_ne!(r, Err(BrowseError::UncNotAllowed));
    }

    // TC-FB-07  canonicalize 结果已剥 \\?\（绝对路径不得带 verbatim 前缀）
    #[test]
    fn results_have_no_verbatim_prefix() {
        let result = browse_directory(None, false, None, None).unwrap();
        assert!(!result.path.starts_with("\\\\?\\"), "path 不应带 \\\\?\\ 前缀");
        assert!(result.parent_path.is_none() || !result.parent_path.as_ref().unwrap().starts_with("\\\\?\\"));
        for e in &result.entries {
            assert!(!e.absolute_path.starts_with("\\\\?\\"));
        }
    }

    // TC-FB-08  属性位隐藏：show_hidden=false 不出现 / true 出现
    #[test]
    fn attribute_hidden_respected() {
        let root = temp_root("hidden");
        let dir = root.join("BrewPingHiddenDir");
        std::fs::create_dir_all(&dir).unwrap();
        set_hidden_attr(&dir);

        let no = browse_directory(Some(root.to_str().unwrap()), false, None, None).unwrap();
        assert!(!no.entries.iter().any(|e| e.name == "BrewPingHiddenDir"), "默认必须隐藏");
        let yes = browse_directory(Some(root.to_str().unwrap()), true, None, None).unwrap();
        assert!(yes.entries.iter().any(|e| e.name == "BrewPingHiddenDir"), "开开关后应出现");
        let _ = std::fs::remove_dir_all(root);
    }

    // TC-FB-09  dotfile 默认不出现，开关后出现
    #[test]
    fn dotfile_hidden_respected() {
        let root = temp_root("dot");
        std::fs::create_dir_all(root.join(".gitdir")).unwrap();
        let no = browse_directory(Some(root.to_str().unwrap()), false, None, None).unwrap();
        assert!(!no.entries.iter().any(|e| e.name == ".gitdir"));
        let yes = browse_directory(Some(root.to_str().unwrap()), true, None, None).unwrap();
        assert!(yes.entries.iter().any(|e| e.name == ".gitdir"));
        let _ = std::fs::remove_dir_all(root);
    }

    // TC-FB-10  文件被过滤，空目录保留
    #[test]
    fn files_filtered_empty_dirs_kept() {
        let root = temp_root("files");
        std::fs::create_dir_all(root.join("empty-dir")).unwrap();
        std::fs::write(root.join("afile.txt"), b"x").unwrap();
        let r = browse_directory(Some(root.to_str().unwrap()), false, None, None).unwrap();
        let names: Vec<&str> = r.entries.iter().map(|e| e.name.as_str()).collect();
        assert!(names.contains(&"empty-dir"), "空目录应保留");
        assert!(!names.contains(&"afile.txt"), "文件应被过滤");
        let _ = std::fs::remove_dir_all(root);
    }

    // TC-FB-11  limit + cursor 分页：两页覆盖全部且无重复，nextCursor = offset 字符串
    #[test]
    fn pagination_covers_all_without_duplicates() {
        let root = temp_root("page");
        for i in 0..25 {
            std::fs::create_dir_all(root.join(format!("dir-{:02}", i))).unwrap();
        }
        let mut collected: Vec<String> = Vec::new();
        let mut cursor: Option<String> = None;
        let mut pages = 0;
        loop {
            let r = browse_directory(
                Some(root.to_str().unwrap()),
                false,
                Some(10),
                cursor.as_deref(),
            )
            .unwrap();
            collected.extend(r.entries.iter().map(|e| e.absolute_path.clone()));
            pages += 1;
            if r.truncated {
                assert!(r.next_cursor.is_some());
                cursor = r.next_cursor;
            } else {
                assert!(r.next_cursor.is_none());
                break;
            }
            assert!(pages < 10, "不应死循环");
        }
        assert_eq!(pages, 3, "25 条 / 每页 10 条 = 3 页");
        assert_eq!(collected.len(), 25);
        assert_eq!(collected.iter().collect::<std::collections::HashSet<_>>().len(), 25, "不应重复");
        let _ = std::fs::remove_dir_all(root);
    }

    // TC-FB-12  空目录 → entries: [], truncated: false, 无 nextCursor
    #[test]
    fn empty_dir_yields_empty_entries() {
        let root = temp_root("empty");
        let r = browse_directory(Some(root.to_str().unwrap()), false, None, None).unwrap();
        assert!(r.entries.is_empty());
        assert!(!r.truncated);
        assert!(r.next_cursor.is_none());
        let _ = std::fs::remove_dir_all(root);
    }

    // TC-FB-13 / TC-FB-14  hints.git：目录与文件（worktree 形态）都算
    #[test]
    fn git_hint_detects_dir_and_file() {
        let root = temp_root("git");
        std::fs::create_dir_all(root.join("repo").join(".git")).unwrap();
        std::fs::create_dir_all(root.join("worktree")).unwrap();
        std::fs::write(root.join("worktree").join(".git"), b"gitdir: ../repo/.git").unwrap();

        let r = browse_directory(Some(root.to_str().unwrap()), false, None, None).unwrap();
        let repo = r.entries.iter().find(|e| e.name == "repo").unwrap();
        assert!(repo.hints.as_ref().unwrap().git, "目录形态的 .git 应命中");
        let wt = r.entries.iter().find(|e| e.name == "worktree").unwrap();
        assert!(wt.hints.as_ref().unwrap().git, "文件形态的 .git（worktree）也应命中");
        let _ = std::fs::remove_dir_all(root);
    }

    // TC-FB-15  C:\ 的 parent_path 为 None
    #[test]
    fn drive_root_has_no_parent() {
        let r = browse_directory(Some("C:\\"), false, None, None).unwrap();
        assert_eq!(r.parent_path, None, "C:\\ 的父目录必须是 None");
        assert_eq!(r.path, "C:\\");
    }

    // TC-FB-17  序列化字段名是 camelCase，与 iOS 契约一致
    #[test]
    fn serialization_uses_camel_case() {
        let root = temp_root("camel");
        std::fs::create_dir_all(root.join("sub")).unwrap();
        let r = browse_directory(Some(root.to_str().unwrap()), false, None, None).unwrap();
        let json = serde_json::to_string(&r).unwrap();
        // nextCursor 仅在 truncated 时出现（skip_serializing_if），只断言必然存在的键
        for key in ["\"parentPath\"", "\"absolutePath\"", "\"isSymlink\"", "\"truncated\""] {
            assert!(json.contains(key), "JSON 应包含 {}，实际 {}", key, json);
        }
        assert!(!json.contains("parent_path") && !json.contains("absolute_path"));
        let _ = std::fs::remove_dir_all(root);
    }

    // TC-FB-18  BrowseError 的 code / status 映射
    #[test]
    fn error_codes_and_statuses() {
        assert_eq!(BrowseError::PathInvalid.code(), "path-invalid");
        assert_eq!(BrowseError::PathInvalid.status(), 400);
        assert_eq!(BrowseError::UncNotAllowed.code(), "unc-not-allowed");
        assert_eq!(BrowseError::UncNotAllowed.status(), 400);
        assert_eq!(BrowseError::OutsideAllowlist.code(), "path-outside-allowlist");
        assert_eq!(BrowseError::OutsideAllowlist.status(), 403);
        assert_eq!(BrowseError::PermissionDenied.code(), "permission-denied");
        assert_eq!(BrowseError::PermissionDenied.status(), 403);
        assert_eq!(BrowseError::ExecutionFailed.code(), "execution-failed");
        assert_eq!(BrowseError::ExecutionFailed.status(), 500);
    }

    // 补充：validate_workdir 的三类拒绝
    #[test]
    fn validate_workdir_rejects_bad_paths() {
        assert_eq!(validate_workdir("\\\\server\\share"), Err(BrowseError::UncNotAllowed));
        assert_eq!(validate_workdir("C:\\definitely\\missing"), Err(BrowseError::PathInvalid));
        let file = std::env::temp_dir().join(format!("brewping-fb-wd-{}.txt", Uuid::new_v4().simple()));
        std::fs::write(&file, b"x").unwrap();
        assert_eq!(validate_workdir(file.to_str().unwrap()), Err(BrowseError::PathInvalid));
        let _ = std::fs::remove_file(file);

        // 合法目录 → 返回剥前缀的绝对路径
        let dir = temp_root("wd");
        let got = validate_workdir(dir.to_str().unwrap()).unwrap();
        assert!(!got.starts_with("\\\\?\\"));
        assert!(Path::new(&got).is_dir());
        let _ = std::fs::remove_dir_all(dir);
    }

    // 补充：limit clamp 边界（0 与超大值都被夹住，而非报错）
    #[test]
    fn limit_is_clamped() {
        let root = temp_root("clamp");
        for i in 0..3 {
            std::fs::create_dir_all(root.join(format!("d{}", i))).unwrap();
        }
        // limit=0 → clamp 到 1，仍应返回 1 条
        let r = browse_directory(Some(root.to_str().unwrap()), false, Some(0), None).unwrap();
        assert_eq!(r.entries.len(), 1);
        assert!(r.truncated);
        // limit 超大 → 全量
        let r = browse_directory(Some(root.to_str().unwrap()), false, Some(100_000), None).unwrap();
        assert_eq!(r.entries.len(), 3);
        assert!(!r.truncated);
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(windows)]
    fn set_hidden_attr(path: &Path) {
        // 目录属性必须用 SetFileAttributesW 设置（std::fs 没有对应 API）
        use windows_sys::Win32::Storage::FileSystem::SetFileAttributesW;
        const FILE_ATTRIBUTE_HIDDEN: u32 = 0x2;
        let wide: Vec<u16> = path.as_os_str().to_string_lossy().encode_utf16().chain(std::iter::once(0)).collect();
        let ok = unsafe { SetFileAttributesW(wide.as_ptr(), FILE_ATTRIBUTE_HIDDEN) };
        assert!(ok != 0, "SetFileAttributesW 失败");
    }
}
