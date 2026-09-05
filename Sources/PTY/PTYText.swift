import Foundation

enum PTYText {
    static func stripANSI(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "\u{1b}\\[[0-9;:<=>?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\u{1b}\\][^\u{07}\u{1b}]*(\u{07}|\u{1b}\\\\)?", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\u{1b}[PX^_][^\u{1b}]*\u{1b}\\\\", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\u{1b}.", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "[\\x{2190}-\\x{28FF}\\x{2B00}-\\x{2BFF}]", with: "", options: .regularExpression)
        return t
    }

    static func normalized(_ s: String) -> String {
        String(stripANSI(s).unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && !CharacterSet.whitespacesAndNewlines.contains(scalar)
        })
    }

    static func escapedForDisplay(_ s: String, maxChars: Int = 4000) -> String {
        var text = s
            .replacingOccurrences(of: "\u{1b}", with: "<ESC>")
            .replacingOccurrences(of: "\r", with: "<CR>")
        if text.count > maxChars {
            text = String(text.prefix(maxChars / 2))
                + "\n...[truncated \(text.count - maxChars) chars]...\n"
                + String(text.suffix(maxChars / 2))
        }
        return text
    }
}
