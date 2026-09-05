import Foundation

final class ScreenRenderer {
    let rowCount: Int
    let columnCount: Int

    private var grid: [[Character]]
    private var cursorRow = 0
    private var cursorCol = 0

    init(rows: Int, columns: Int) {
        rowCount = rows
        columnCount = columns
        grid = ScreenRenderer.blankGrid(rows: rows, columns: columns)
    }

    private static func blankGrid(rows: Int, columns: Int) -> [[Character]] {
        Array(repeating: Array(repeating: Character(" "), count: columns), count: rows)
    }

    var lines: [String] {
        grid.map { row in
            var text = String(row)
            while let last = text.unicodeScalars.last, last == " " {
                text.unicodeScalars.removeLast()
            }
            return text
        }
    }

    var snapshot: String {
        lines.joined(separator: "\n")
    }

    func reset() {
        grid = ScreenRenderer.blankGrid(rows: rowCount, columns: columnCount)
        cursorRow = 0
        cursorCol = 0
    }

    func feed(_ text: String) {
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            if scalar == "\u{1b}" {
                i = handleEscape(scalars, at: i)
                continue
            }
            switch scalar {
            case "\n":
                cursorRow = min(cursorRow + 1, rowCount - 1)
            case "\r":
                cursorCol = 0
            case "\t":
                cursorCol = min((cursorCol / 8 + 1) * 8, columnCount - 1)
            case "\u{7f}":
                break
            default:
                if scalar.value >= 0x20 {
                    put(scalar)
                }
            }
            i += 1
        }
    }

    private func put(_ scalar: Unicode.Scalar) {
        guard cursorRow < rowCount, cursorCol < columnCount else { return }
        grid[cursorRow][cursorCol] = Character(scalar)
        cursorCol += Self.isWide(scalar) ? 2 : 1
        if cursorCol >= columnCount {
            cursorRow = min(cursorRow + 1, rowCount - 1)
            cursorCol = 0
        }
    }

    private func handleEscape(_ scalars: [Unicode.Scalar], at index: Int) -> Int {
        var j = index + 1
        guard j < scalars.count else { return j }
        switch scalars[j] {
        case "[":
            j += 1
            var params = ""
            while j < scalars.count, scalars[j].value >= 0x30 && scalars[j].value <= 0x3F {
                params.unicodeScalars.append(scalars[j])
                j += 1
            }
            var intermediates = ""
            while j < scalars.count, scalars[j].value >= 0x20 && scalars[j].value <= 0x2F {
                intermediates.unicodeScalars.append(scalars[j])
                j += 1
            }
            guard j < scalars.count else { return j }
            let final = Character(scalars[j])
            j += 1
            handleCSI(params: params, intermediates: intermediates, final: final)
            return j
        case "]", "P", "X", "^", "_":
            j += 1
            while j < scalars.count {
                if scalars[j] == "\u{07}" { return j + 1 }
                if scalars[j] == "\u{1b}" && j + 1 < scalars.count && scalars[j + 1] == "\\" {
                    return j + 2
                }
                j += 1
            }
            return j
        default:
            if scalars[j].value >= 0x20 && scalars[j].value <= 0x2F {
                j += 1
                if j < scalars.count { j += 1 }
                return j
            }
            return j + 1
        }
    }

    private func handleCSI(params: String, intermediates: String, final: Character) {
        _ = intermediates
        let isPrivate = params.hasPrefix("?") || params.hasPrefix(">") || params.hasPrefix("<") || params.hasPrefix("=")
        if isPrivate {
            if final == "h" && (params.contains("1049") || params.contains("1047") || params.contains("1048")) {
                reset()
            }
            return
        }
        let parts = params.split(separator: ";", omittingEmptySubsequences: false)
        let nums = parts.map { Int($0) ?? 0 }
        func n(_ index: Int, _ fallback: Int) -> Int {
            let value = index < nums.count ? nums[index] : 0
            return value == 0 ? fallback : value
        }
        switch final {
        case "H", "f":
            cursorRow = Self.clamp(n(0, 1) - 1, 0, rowCount - 1)
            cursorCol = Self.clamp(n(1, 1) - 1, 0, columnCount - 1)
        case "J":
            let mode = nums.first ?? 0
            if mode == 2 || mode == 3 {
                grid = ScreenRenderer.blankGrid(rows: rowCount, columns: columnCount)
            } else if mode == 0 {
                for c in cursorCol..<columnCount { grid[cursorRow][c] = " " }
                for r in (cursorRow + 1)..<rowCount { grid[r] = Array(repeating: Character(" "), count: columnCount) }
            }
        case "K":
            let mode = nums.first ?? 0
            if mode == 0 {
                for c in cursorCol..<columnCount { grid[cursorRow][c] = " " }
            } else if mode == 1 {
                for c in 0...min(cursorCol, columnCount - 1) { grid[cursorRow][c] = " " }
            } else {
                grid[cursorRow] = Array(repeating: Character(" "), count: columnCount)
            }
        case "A":
            cursorRow = max(0, cursorRow - n(0, 1))
        case "B":
            cursorRow = min(rowCount - 1, cursorRow + n(0, 1))
        case "C":
            cursorCol = min(columnCount - 1, cursorCol + n(0, 1))
        case "D":
            cursorCol = max(0, cursorCol - n(0, 1))
        case "G":
            cursorCol = Self.clamp(n(0, 1) - 1, 0, columnCount - 1)
        case "d":
            cursorRow = Self.clamp(n(0, 1) - 1, 0, rowCount - 1)
        default:
            break
        }
    }

    private static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        min(max(value, low), high)
    }

    static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        switch v {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x2FFFD, 0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
