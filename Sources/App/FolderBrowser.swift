import Foundation

/// 目录浏览 —— 桌面端 composer 目录条的数据源。
///
/// 契约与 Windows 端 `folder_browser.rs` 的 serde 结构逐字对齐（camelCase），
/// 但实现按 macOS 的实际情况重写：
/// - 「盘符」→ 根 `/` + `/Volumes` 下已挂载的卷；
/// - `\\?\` verbatim 前缀 / `dunce` 剥离 → macOS 无此概念，改为统一
///   `resolvingSymlinksInPath()`（realpath 等价物）；
/// - UNC（`\\server\share`）拒绝 → macOS 类比：`//server/share` 形式的路径
///   **在 realpath 之前**拒绝（同样是"会触发网络认证"的输入）。
///
/// 安全铁律（与 Windows 一致，理由不同）：
/// 1. 只探测"是不是目录"，**绝不读文件内容**（OneDrive 类占位文件的对应风险：
///    iCloud Drive 的未下载文件读内容会触发全量下载）；
/// 2. 符号链接的 realpath 在做目录判定时解析，避免 `~/link` 指向 `/` 之后
///    以为自己只看了子目录；
/// 3. 枚举用 `FileManager` 的系统调用，**绝不**用路径存在性探测逐个拼名字。
public enum FolderBrowser {

    /// 单页条目数（对齐 Windows `DEFAULT_LIMIT`）。
    static let defaultLimit = 200
    /// 单页硬上限（对齐 Windows `HARD_LIMIT`）。
    static let hardLimit = 1000

    public struct RootsInfo: Codable {
        public init(platform: String, pathSeparator: String, homeDir: String, drives: [String]) {
            self.platform = platform; self.pathSeparator = pathSeparator; self.homeDir = homeDir; self.drives = drives
        }
        public var platform: String
        public var pathSeparator: String
        public var homeDir: String
        public var drives: [String]
    }

    public struct EntryInfo: Codable {
        public init(name: String, absolutePath: String, isSymlink: Bool, hidden: Bool) {
            self.name = name; self.absolutePath = absolutePath; self.isSymlink = isSymlink; self.hidden = hidden
        }
        public var name: String
        public var absolutePath: String
        public var isSymlink: Bool
        public var hidden: Bool
    }

    public struct BrowseResult: Codable {
        public init(path: String, parentPath: String?, entries: [EntryInfo], truncated: Bool) {
            self.path = path; self.parentPath = parentPath; self.entries = entries; self.truncated = truncated
        }
        public var path: String
        public var parentPath: String?
        public var entries: [EntryInfo]
        public var truncated: Bool
    }

    enum BrowseError: LocalizedError {
        case pathInvalid
        case notADirectory

        var errorDescription: String? {
            switch self {
            case .pathInvalid: return "path is invalid or cannot be resolved"
            case .notADirectory: return "path is not a directory"
            }
        }
    }

    // MARK: - 根列表

    /// 主目录 + 根 + 已挂载卷。
    public static func roots() -> RootsInfo {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var volumes: [String] = ["/"]
        if let names = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            for name in names.sorted() {
                let path = "/Volumes/\(name)"
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                      isDir.boolValue else { continue }
                volumes.append(path)
            }
        }
        return RootsInfo(
            platform: "macos",
            pathSeparator: "/",
            homeDir: home,
            drives: volumes
        )
    }

    // MARK: - 浏览

    /// 浏览某个目录（`path` 为 nil = 主目录）。只返回**子目录**，不返回文件。
    public static func browse(path: String?, limit: Int? = nil, offset: Int = 0) throws -> BrowseResult {
        let requested = path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? path!
            : FileManager.default.homeDirectoryForCurrentUser.path

        // 步骤 1：UNC 类比必须在 realpath **之前**按字符串拒绝。
        // `//server/share` 会触发 SMB 挂载与凭据交换，不是本地路径。
        if requested.hasPrefix("//") {
            throw BrowseError.pathInvalid
        }

        // 步骤 2：realpath + 目录校验。
        let real = try resolveDirectory(requested)

        // 步骤 3：limit clamp（宽容策略：非法值降级为缺省，不报错）。
        let pageLimit = min(max(limit ?? defaultLimit, 1), hardLimit)

        // 步骤 4：枚举。只认目录；隐藏 = 点号前缀。
        let names = (try? FileManager.default.contentsOfDirectory(atPath: real)) ?? []
        var entries: [EntryInfo] = []
        entries.reserveCapacity(names.count)

        for name in names {
            let full = real == "/" ? "/\(name)" : "\(real)/\(name)"
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            let attributes = try? FileManager.default.attributesOfItem(atPath: full)
            let isLink = (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink

            // 符号链接：解析后仍须是目录，否则跳过（避免把指向文件的链接当目录入层）。
            var resolvedIsDirectory = isDir.boolValue
            if isLink {
                let target = URL(fileURLWithPath: full).resolvingSymlinksInPath()
                var targetIsDir: ObjCBool = false
                resolvedIsDirectory = FileManager.default.fileExists(atPath: target.path, isDirectory: &targetIsDir)
                    && targetIsDir.boolValue
            }
            guard resolvedIsDirectory else { continue }

            let hidden = name.hasPrefix(".")
            entries.append(EntryInfo(
                name: name,
                absolutePath: full,
                isSymlink: isLink,
                hidden: hidden
            ))
        }

        // 排序：目录内按名字不区分大小写升序，保证 UI 顺序稳定。
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let total = entries.count
        let start = min(max(offset, 0), total)
        let end = min(start + pageLimit, total)
        let page = Array(entries[start..<end])

        return BrowseResult(
            path: real,
            parentPath: parent(of: real),
            entries: page,
            truncated: end < total
        )
    }

    /// 校验一个候选 workdir：realpath + 是目录 + 非网络路径。
    /// 返回规范化后的绝对路径；不合法抛错。
    public static func validateWorkdir(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BrowseError.pathInvalid }
        if trimmed.hasPrefix("//") { throw BrowseError.pathInvalid }
        return try resolveDirectory(trimmed)
    }

    // MARK: - Internals

    /// 展开 `~` → realpath → 断言是目录。
    private static func resolveDirectory(_ raw: String) throws -> String {
        var text = raw
        if text == "~" {
            text = FileManager.default.homeDirectoryForCurrentUser.path
        } else if text.hasPrefix("~/") {
            text = FileManager.default.homeDirectoryForCurrentUser.path + String(text.dropFirst(1))
        }
        if !text.hasPrefix("/") {
            text = FileManager.default.currentDirectoryPath + "/" + text
        }
        let url = URL(fileURLWithPath: text).standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw BrowseError.pathInvalid
        }
        guard isDir.boolValue else { throw BrowseError.notADirectory }
        return url.path
    }

    /// 上一级；根目录返回 nil（对齐 Windows：`C:\` 的 parent 为 None）。
    private static func parent(of path: String) -> String? {
        if path == "/" { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        if parent.isEmpty || parent == path { return nil }
        return parent
    }
}
