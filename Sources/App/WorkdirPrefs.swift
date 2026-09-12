import Foundation

/// 用户通过桌面端 / 手机端选定的 **Agent 工作目录**持久化。
///
/// 与 Windows 端 `workdir_prefs.rs` 同构：它是"用户偏好"，**不修改各 Agent 自己的
/// 配置文件**。落盘 `~/.brewping/workdirs.json`，与 `approval.json` / `pairing.json`
/// 同目录、各自一个文件。
///
/// 注入方式：命令执行时经 `CommandContext.workdir` 传到 `CommandRunner`，仅对
/// **headless 型** Agent 生效（会话型 Agent 的 cwd 在进程启动时就固定了）。
public final class WorkdirPrefs {
    public static let shared = WorkdirPrefs()

    private struct Stored: Codable {
        var workdirs: [String: String]
    }

    private let lock = NSLock()
    private var workdirs: [String: String]
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? SessionManager.shared.directory.appendingPathComponent("workdirs.json")
        if let data = try? Data(contentsOf: self.fileURL),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            workdirs = stored.workdirs
        } else {
            workdirs = [:]
        }
    }

    /// 读取某个 Agent 的工作目录；未设置过时为 nil。
    public func get(agentID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return workdirs[agentID]
    }

    /// 设置 / 清除某个 Agent 的工作目录。返回落盘后的值（`path` 为空串 = 清除）。
    ///
    /// 目录必须真实存在（与「绑定目录」的语义一致：目录失效时不写入，
    /// 避免留下一个执行时必然失败的 cwd）。
    @discardableResult
    public func set(agentID: String, path: String?) -> String? {
        let normalized = Self.normalize(path)
        lock.lock()
        if let normalized {
            workdirs[agentID] = normalized
        } else {
            workdirs.removeValue(forKey: agentID)
        }
        persistLocked()
        let result = workdirs[agentID]
        lock.unlock()
        return result
    }

    /// 规范化：展开 `~`、剥离尾斜杠、解析符号链接，并校验确实是目录。
    /// 非目录 / 不存在 → nil（调用方据此清除偏好）。
    public static func normalize(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if text == "~" {
            text = FileManager.default.homeDirectoryForCurrentUser.path
        } else if text.hasPrefix("~/") {
            text = FileManager.default.homeDirectoryForCurrentUser.path + String(text.dropFirst(1))
        }
        // 统一成绝对路径（相对路径按当前工作目录解析，与 CLI 行为一致）
        if !text.hasPrefix("/") {
            text = FileManager.default.currentDirectoryPath + "/" + text
        }
        let url = URL(fileURLWithPath: text).standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return url.path
    }

    private func persistLocked() {
        let stored = Stored(workdirs: workdirs)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
