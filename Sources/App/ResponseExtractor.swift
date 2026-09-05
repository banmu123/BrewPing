import Foundation

enum ResponseExtractor {
    static let fallbackMaxLines = 14
    static let maxMatchWindow = 6

    static func extract(rows: [String], sentText: String, cwd: String? = nil) -> (text: String, complete: Bool)? {
        let sentKey = PTYText.normalized(sentText)
        guard !sentKey.isEmpty, rows.count > 0 else { return nil }

        let bottomLimit = bottomContentLimit(rows)

        var candidates: [Int] = []
        for i in 0..<bottomLimit where matchWindow(rows: rows, start: i, limit: bottomLimit, sentKey: sentKey) != nil {
            candidates.append(i)
        }
        let bubbleCandidates = candidates.filter { isBubbleLine(rows[$0]) }
        guard let userRow = (bubbleCandidates.last ?? candidates.last) else { return nil }

        var collected: [String] = []
        var pendingBlanks = 0
        var i = userRow + 1
        while i < bottomLimit {
            let raw = rows[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                if !collected.isEmpty { pendingBlanks += 1 }
                i += 1
                continue
            }
            if isMetaLine(trimmed) {
                return (finalize(collected), true)
            }
            if isActivityLine(trimmed) || isChromeLine(trimmed, cwd: cwd) {
                i += 1
                continue
            }
            let bubble = isBubbleLine(raw)
            if bubble {
                if !collected.isEmpty && !trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "┃")).trimmingCharacters(in: .whitespaces).isEmpty {
                    return (finalize(collected), false)
                }
                i += 1
                continue
            }
            if !collected.isEmpty && pendingBlanks > 0 {
                collected.append("")
                pendingBlanks = 0
            }
            pendingBlanks = 0
            collected.append(trimmed)
            i += 1
        }
        guard !collected.isEmpty else { return nil }
        return (finalize(collected), false)
    }

    private static func matchWindow(rows: [String], start: Int, limit: Int, sentKey: String) -> Int? {
        guard start < limit else { return nil }
        let first = normalizedContent(rows[start])
        guard !first.isEmpty else { return nil }
        if first.contains(sentKey) { return 1 }
        var joined = first
        var size = 2
        while size <= maxMatchWindow && start + size - 1 < limit {
            let next = rows[start + size - 1]
            guard isBubbleLine(next) else { break }
            joined += normalizedContent(next)
            if joined.contains(sentKey) { return size }
            size += 1
        }
        return nil
    }

    private static func normalizedContent(_ row: String) -> String {
        PTYText.normalized(row.replacingOccurrences(of: "┃", with: ""))
    }

    static func fallbackRaw(rows: [String], cwd: String? = nil) -> String? {
        guard !rows.isEmpty else { return nil }
        let limit = bottomContentLimit(rows)
        var collected: [String] = []
        var sawContent = false
        var i = min(limit, rows.count) - 1
        while i >= 0 {
            let raw = rows[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            i -= 1
            if isBubbleLine(raw) {
                if sawContent { break }
                continue
            }
            if trimmed.isEmpty {
                if sawContent { collected.append("") }
                continue
            }
            if isSpinnerLine(trimmed) { continue }
            if isActivityLine(trimmed) { continue }
            if isMetaLine(trimmed) { continue }
            if isChromeLine(trimmed, cwd: cwd) { continue }
            sawContent = true
            collected.append(sanitize(removeWideCharGaps(trimmed)))
            if collected.count >= ResponseExtractor.fallbackMaxLines { break }
        }
        collected.reverse()
        while let first = collected.first, first.isEmpty { collected.removeFirst() }
        while let last = collected.last, last.isEmpty { collected.removeLast() }
        guard !collected.isEmpty else { return nil }
        return collected.joined(separator: "\n")
    }

    private static func sanitize(_ line: String) -> String {
        let filtered = line.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar != "\u{7f}" && scalar != "\u{fffd}"
        }
        return String(String.UnicodeScalarView(filtered))
    }

    private static func bottomContentLimit(_ rows: [String]) -> Int {
        if let idx = rows.lastIndex(where: { $0.contains("╹") || $0.contains("▀▀") }) {
            return idx
        }
        if let idx = rows.lastIndex(where: { $0.contains("ctrl+p") }) {
            return max(idx - 1, 0)
        }
        return rows.count
    }

    private static func isMetaLine(_ trimmed: String) -> Bool {
        guard let first = trimmed.unicodeScalars.first else { return false }
        let glyphs: Set<Unicode.Scalar> = ["▣", "▪", "◆", "◈", "●", "■", "▶", "▸", "■"]
        return glyphs.contains(first) && trimmed.contains("·")
    }

    private static func isActivityLine(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("+ ") || isSpinnerLine(trimmed)
    }

    private static func isChromeLine(_ trimmed: String, cwd: String? = nil) -> Bool {
        if trimmed.contains("ctrl+p") { return true }
        if trimmed.contains("╹") || trimmed.contains("▀▀") { return true }
        if trimmed.hasPrefix("·") { return true }
        if let cwd, !cwd.isEmpty, trimmed.hasPrefix(cwd) { return true }
        if isPurePath(trimmed) { return true }
        return false
    }

    private static func isPurePath(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("/"), !trimmed.contains(" ") else { return false }
        var scalars = trimmed.unicodeScalars
        scalars.removeFirst()
        return !scalars.isEmpty && scalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "/" || scalar == "_" || scalar == "-" || scalar == "."
        }
    }

    private static func isSpinnerLine(_ trimmed: String) -> Bool {
        guard let first = trimmed.unicodeScalars.first else { return false }
        return (0x2800...0x28FF).contains(first.value)
            || first == "◐" || first == "◓" || first == "◑" || first == "◒"
            || first == "◒" || first == "⠁" || first == "⠂" || first == "⠄"
    }

    private static func isBubbleLine(_ raw: String) -> Bool {
        raw.prefix(6).contains("┃")
    }

    private static func finalize(_ lines: [String]) -> String {
        var cleaned = lines.map { removeWideCharGaps($0).trimmingCharacters(in: .whitespaces) }
        while let first = cleaned.first, first.isEmpty { cleaned.removeFirst() }
        while let last = cleaned.last, last.isEmpty { cleaned.removeLast() }
        return cleaned.joined(separator: "\n")
    }

    private static func removeWideCharGaps(_ line: String) -> String {
        var scalars = Array(line.unicodeScalars)
        guard scalars.count > 2 else { return line }
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(scalars.count)
        for (i, scalar) in scalars.enumerated() {
            if scalar == " "
                && i > 0 && i + 1 < scalars.count
                && isWide(scalars[i - 1]) && isWide(scalars[i + 1]) {
                continue
            }
            out.append(scalar)
        }
        scalars = out
        return String(String.UnicodeScalarView(scalars))
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        ScreenRenderer.isWide(scalar)
    }
}
