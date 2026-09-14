import Foundation

// ─── CLI 原生配置读写的基础设施（四个「厂商原生配置」模块共用）─────────────────
//
// 对应 Windows `agent_config::read_text` 的 BOM 剥离 + 各 `*_config.rs` 的
// 读写约定。四个模块（claude / codex / pi / opencode）共用这一份，
// 保证「读到什么就原样写回什么」的语义一致。

/// 配置读写的统一错误（与 Windows 各模块返回的 `Err(String)` 同构）。
public struct CLIConfigError: LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// CLI 配置文件的读写工具。
public enum CLIConfigIO {

    /// 剥掉行首 UTF-8 BOM。
    ///
    /// 为什么必须剥：Windows 上大量编辑器（记事本 / PowerShell 5.1 的
    /// `Set-Content -Encoding utf8`）保存 JSON 时会带 BOM（首 3 字节 `EF BB BF`）。
    /// `JSONSerialization` 对 BOM 是宽容的，但 **TOML / 按行解析的格式不行** ——
    /// 行首多一个 `U+FEFF` 后 `hasPrefix("[")` 直接判否，整段配置被静默丢掉。
    /// 只剥开头那一个（BOM 按规范只允许出现在文件最前）。
    public static func stripBOM(_ data: Data) -> Data {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        if data.count >= 3, Array(data.prefix(3)) == bom {
            return data.dropFirst(3)
        }
        return data
    }

    /// 读一个文本文件（自动剥 BOM）。文件不存在 → nil。
    public static func readText(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: stripBOM(data), encoding: .utf8)
    }

    /// 读一份 JSON 对象。
    ///
    /// 语义（与 Windows `claude_config::read_config_at` 逐条对齐）：
    /// - 文件不存在 → `[:]`（空对象，不报错）
    /// - 内容全空白 → `[:]`
    /// - 解析失败 → 抛错（**静默重建会清空用户配置**，绝不允许）
    /// - 根不是对象 → 抛错（同理：整体覆盖的前提是"我们知道根长什么样"）
    public static func readJSONObject(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let text = readText(at: url) else {
            throw CLIConfigError("read \(url.path) failed")
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        let data = Data(text.utf8)
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CLIConfigError("\(url.path) is not valid JSON: \(error.localizedDescription)")
        }
        guard let object = parsed as? [String: Any] else {
            throw CLIConfigError("\(url.path) root must be a JSON object (found \(typeName(parsed)))")
        }
        return object
    }

    /// 写一份 JSON 对象（pretty + 键排序 + 不转义 `/`）。
    ///
    /// - 自动创建父目录；
    /// - **非原子写**（等价于 Rust `std::fs::write`）：原地截断写入，
    ///   从而**保留文件原有权限**。用 `.atomic` 会新建文件、把 0600 重置成
    ///   默认 0644，可能把用户的明文 Key 暴露给同机其他用户。
    public static func writeJSONObject(_ object: [String: Any], at url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw CLIConfigError("encode JSON failed: \(error.localizedDescription)")
        }
        var out = data
        out.append(0x0A)   // 与 Windows 的 `format!("{data}\n")` 一致
        do {
            try out.write(to: url)
        } catch {
            throw CLIConfigError("write \(url.path) failed: \(error.localizedDescription)")
        }
    }

    /// 原子写一份 JSON 对象（先写同目录临时文件再 rename，避免半截 JSON）。
    ///
    /// 与 `writeJSONObject` 的差别**只在写入方式**：语义等价，但崩在中途不会
    /// 留下半截文件（Windows `pi_config::write_atomic` 同款思路）。
    /// 🚨 额外修好 Windows 的一处疏漏：temp+rename 会新建文件，把原权限重置成
    /// 默认值；这里**先把临时文件权限对齐原文件**再替换，避免把 0600 放宽成 0644。
    public static func writeJSONObjectAtomic(_ object: [String: Any], at url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw CLIConfigError("encode JSON failed: \(error.localizedDescription)")
        }
        var payload = data
        payload.append(0x0A)

        let temp = parent.appendingPathComponent(url.lastPathComponent + ".brewping-tmp")
        do {
            try payload.write(to: temp)
        } catch {
            throw CLIConfigError("write \(temp.path) failed: \(error.localizedDescription)")
        }
        // 保留目标原有权限（新文件则不动，交给 umask）
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let perms = attrs[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: temp.path)
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw CLIConfigError("replace \(url.path) failed: \(error.localizedDescription)")
        }
    }

    /// 读一个「键排序」的时间戳指纹（与 `AgentConfigDiscovery.configVersion` 同格式）。
    public static func fingerprint(at url: URL) -> String {        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue else { return "-" }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(Int64(mtime * 1_000_000_000)):\(size)"
    }

    static func typeName(_ value: Any) -> String {
        switch value {
        case is NSNull:          return "null"
        case is Bool:            return "bool"
        case is NSNumber:        return "number"
        case is String:          return "string"
        case is [Any]:           return "array"
        case is [String: Any]:   return "object"
        default:                 return "unknown"
        }
    }
}

/// 简单的进程内串行锁（等价于 Windows 各模块的 `Mutex<()>`）：
/// 避免两个界面（设置页 + 表单 sheet）同时写导致丢更新。
public final class CLIConfigLock {
    private let lock = NSLock()
    public init() {}
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
