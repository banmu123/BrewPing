import Foundation

// ─── 最小 TOML 编辑器（保注释 / 保格式 / 保顺序）─────────────────────────────
//
// 为什么自己写：Windows 用 `toml_edit`「保注释与格式，只动目标位置」，
// Swift 生态没有等价库。这里的实现走**按行编辑**路线：
// 解析出「顶层标量」与「各个 [table] 块」的行号，修改时只替换/插入/删除目标行，
// 其余行（注释、空行、用户的其它表、`[[array of tables]]`）**原样保留**。
//
// 与 toml_edit 的**有意差异**（语义等价，输出更干净）：
//   toml_edit 在 `[model_providers.<key>]` 之前可能额外输出一个显式的
//   `[model_providers]` 父表头；本实现不生成父表头（TOML 里父表由子表隐式建立，
//   语义完全一致），删除最后一个子表时也会把空的父表头一并摘掉。
//
// 支持的编辑范围（够用即可，**不追求完整 TOML 语法**）：
//   · 读/写/删 顶层 `key = "value"`
//   · 读/写/删 `[table]` 块内的 `key = "value"`
//   · 新增/删除 `[table]` 块
// 不解析数组、内联表、多行字符串——遇到时当作普通行保留，绝不破坏。

struct MiniTOML {

    /// 文件原始行（已统一成 `\n` 分隔；写回时按原行尾风格还原）。
    private(set) var lines: [String]
    private let usesCRLF: Bool

    /// 顶层标量：key → 行号（仅第一个表头之前的 `key = value`）。
    private var topScalars: [String: Int] = [:]
    /// 表块：表名 → 信息。
    private var tables: [String: Table] = [:]
    /// 表出现顺序（用于定位插入点）。
    private var tableOrder: [String] = []

    struct Table {
        /// 表头 `[name]` 所在行号。
        var header: Int
        /// 块结束行号（不含；= 下一个表头或文件末）。
        var end: Int
        /// 直接字段：key → 行号（不含子表）。
        var fields: [String: Int]
    }

    /// 数组表 `[[name]]` 的合成段名前缀：我们**不管理**这类段，
    /// 但要认出来，避免把它的字段误记成顶层键。
    private static let arraySectionPrefix = "\u{1}array:"

    // ─── 构造 / 解析 ─────────────────────────────────────────────────────────

    init(text: String) {
        usesCRLF = text.contains("\r\n")
        let normalized = usesCRLF ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
        lines = normalized.components(separatedBy: "\n")
        reindex()
    }

    /// 还原成文本（保持原行尾风格）。
    var text: String {
        lines.joined(separator: usesCRLF ? "\r\n" : "\n")
    }

    private static func trimmed(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private mutating func reindex() {
        topScalars = [:]
        tables = [:]
        tableOrder = []

        var section: String?
        var sectionHeader = 0
        var sectionFields: [String: Int] = [:]

        func close(_ endLine: Int) {
            guard let name = section else { return }
            tables[name] = Table(header: sectionHeader, end: endLine, fields: sectionFields)
            tableOrder.append(name)
        }

        for (index, line) in lines.enumerated() {
            let text = Self.trimmed(line)
            if text.isEmpty || text.hasPrefix("#") { continue }

            if text.hasPrefix("[[") {
                // `[[array of tables]]` —— 结束当前段，并进入一个「我们不管理」的段
                close(index)
                let inner = Self.headerInner(text)
                section = Self.arraySectionPrefix + inner
                sectionHeader = index
                sectionFields = [:]
                continue
            }
            if text.hasPrefix("[") {
                close(index)
                section = Self.headerInner(text)
                sectionHeader = index
                sectionFields = [:]
                continue
            }
            guard let eq = text.firstIndex(of: "=") else { continue }
            let key = String(text[text.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(" ") else { continue }
            if section != nil {
                sectionFields[key] = index
            } else {
                topScalars[key] = index
            }
        }
        close(lines.count)
    }

    /// 取出 `[name]` / `[[name]]` 里的 name（按第一个 `]` 切）。
    private static func headerInner(_ text: String) -> String {
        var body = text.dropFirst()
        if body.hasPrefix("[") { body = body.dropFirst() }
        guard let end = body.firstIndex(of: "]") else { return String(body) }
        return String(body[body.startIndex..<end])
    }

    // ─── 查询 ────────────────────────────────────────────────────────────────

    func topString(_ key: String) -> String? {
        guard let index = topScalars[key] else { return nil }
        return Self.value(of: lines[index])
    }

    func hasTopKey(_ key: String) -> Bool { topScalars[key] != nil }

    func hasTable(_ name: String) -> Bool { tables[name] != nil }

    func tableString(_ table: String, _ field: String) -> String? {
        guard let info = tables[table], let index = info.fields[field] else { return nil }
        return Self.value(of: lines[index])
    }

    /// 前缀匹配的表名（已排序；跳过 `[[array]]` 合成段）。
    func tableNames(withPrefix prefix: String) -> [String] {
        tableOrder
            .filter { !$0.hasPrefix(Self.arraySectionPrefix) && $0.hasPrefix(prefix + ".") }
            .sorted()
    }

    /// 是否存在「有直接字段的 `[name]` 空壳表」（用于删除后清理）。
    func isEmptyTable(_ name: String) -> Bool {
        guard let info = tables[name] else { return false }
        return info.fields.isEmpty && tableNames(withPrefix: name).isEmpty
    }

    // ─── 修改 ────────────────────────────────────────────────────────────────
    //
    // 每次修改后立即重建索引：行号会变，重建比手工维护下标安全得多。

    mutating func setTopString(_ key: String, _ value: String) {
        let newLine = "\(key) = \(Self.quote(value))"
        if let index = topScalars[key] {
            lines[index] = newLine
        } else {
            // 插到「顶层区」末尾 —— 即第一个表头之前；没有表头则插到文件末。
            let insertAt = tableOrder.compactMap { tables[$0]?.header }.min() ?? lines.count
            lines.insert(newLine, at: min(insertAt, lines.count))
        }
        reindex()
    }

    mutating func removeTopKey(_ key: String) {
        guard let index = topScalars[key] else { return }
        lines.remove(at: index)
        reindex()
    }

    /// 删除顶层的一个键**所在行**（不要求它是 `key = value` 形式 —— 用于清理
    /// `model_providers = {...}` 这类非法写法）。
    mutating func removeTopLine(forKey key: String) {
        removeTopKey(key)
    }

    mutating func setTableString(_ table: String, _ field: String, _ value: String) {
        guard let info = tables[table] else { return }
        let newLine = "\(field) = \(Self.quote(value))"
        if let index = info.fields[field] {
            lines[index] = newLine
        } else {
            // 追加到该段末尾（最后一个非空行之后，空行与下一个表头之前）
            var insertAt = info.header + 1
            var index = info.header + 1
            while index < info.end {
                if !Self.trimmed(lines[index]).isEmpty { insertAt = index + 1 }
                index += 1
            }
            lines.insert(newLine, at: min(insertAt, lines.count))
        }
        reindex()
    }

    mutating func removeTableField(_ table: String, _ field: String) {
        guard let info = tables[table], let index = info.fields[field] else { return }
        lines.remove(at: index)
        reindex()
    }

    /// 确保 `[table]` 块存在（不存在则在文件末尾新建）。
    mutating func ensureTable(_ table: String) {
        guard tables[table] == nil else { return }
        while let last = lines.last, Self.trimmed(last).isEmpty { lines.removeLast() }
        if !lines.isEmpty { lines.append("") }
        lines.append("[\(table)]")
        reindex()
    }

    /// 删除整个 `[table]` 块（含表头与字段行）。
    mutating func removeTable(_ table: String) {
        guard let info = tables[table] else { return }
        let end = min(info.end, lines.count)
        guard info.header < end else { return }
        lines.removeSubrange(info.header..<end)
        reindex()
    }

    // ─── 值解析 / 序列化 ─────────────────────────────────────────────────────

    /// 从 `key = value` 行里取出字符串值。
    ///
    /// 只处理我们关心的那几种写法：基本字符串 `"..."`（含转义）、字面量 `'...'`、
    /// 以及裸值（截到行内 `#` 注释前）。其它类型（数字/布尔/数组）原样返回字符串形式。
    static func value(of line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let raw = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        return parseValue(raw)
    }

    static func parseValue(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        // 行内注释：只在非引号开头时才可能（引号内的 `#` 是内容）
        if !s.hasPrefix("\"") && !s.hasPrefix("'") {
            if let hash = s.firstIndex(of: "#") {
                s = String(s[s.startIndex..<hash]).trimmingCharacters(in: .whitespaces)
            }
            return s
        }
        if s.hasPrefix("\"") {
            var out = ""
            var index = s.index(after: s.startIndex)
            var escaped = false
            while index < s.endIndex {
                let ch = s[index]
                if escaped {
                    switch ch {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    default: out.append(ch)
                    }
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    break
                } else {
                    out.append(ch)
                }
                index = s.index(after: index)
            }
            return out
        }
        // 字面量字符串 '...'（无转义）
        let body = s.dropFirst()
        guard let end = body.firstIndex(of: "'") else { return String(body) }
        return String(body[body.startIndex..<end])
    }

    /// 序列化成 TOML 基本字符串（转义 `\` 与 `"` 及控制字符）。
    static func quote(_ value: String) -> String {
        var out = "\""
        for ch in value {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        out += "\""
        return out
    }
}
