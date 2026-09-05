import Foundation

enum ResponseExtractor {
    static func extract(rows: [String], sentText: String) -> (text: String, complete: Bool)? {
        let sentKey = PTYText.normalized(sentText)
        guard !sentKey.isEmpty, rows.count > 0 else { return nil }

        let bottomLimit = bottomContentLimit(rows)

        var candidates: [Int] = []
        for (i, row) in rows.enumerated() where i < bottomLimit {
            if PTYText.normalized(row).contains(sentKey) {
                candidates.append(i)
            }
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
            if isActivityLine(trimmed) {
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
