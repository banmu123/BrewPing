import BrewPingCore
import SwiftUI

// ─── Markdown 渲染（对齐 Windows 的 `.markdown-body` 规则）──────────────────────
//
// Windows 用 Streamdown + shiki 做完整渲染；macOS 侧不引入第三方依赖，改为
// **自实现轻量块级解析 + 富文本内联渲染**，视觉规则逐条落在 `app.css` 的
// `.markdown-body` 上：
//   标题 h1 1.29em / h2 1.14em / h3+ 0.93em（规格 §10.3 的 --markdown-* 变量）；
//   正文段间距 0.75rem；列表标记用伪元素（点/序号）而非原生 marker；
//   引用左缘 2px + muted 且不斜体；行内代码 code 底 + 2px 圆角 + 1px/4px 内边距；
//   代码块 code 底 + code-border 描边 + 8pt 圆角；表格斑马纹 + muted/45 表头。

struct MarkdownView: View {
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            inlineText(content)
                .font(headingFont(level))
                .foregroundStyle(level >= 6 ? Latte.mutedForeground : Latte.foreground)
                .textCase(level >= 5 ? .uppercase : nil)
                .padding(.top, headingTop(level))
                .padding(.bottom, level <= 2 ? 8 : 6)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .paragraph(let content):
            inlineText(content)
                .font(LatteFont.base)
                .foregroundStyle(Latte.foreground)
                .lineSpacing(LatteFont.baseLineSpacing)
                .textSelection(.enabled)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Latte.foreground)
                            .frame(width: 5, height: 5)
                            .padding(.top, 7)
                        inlineText(item)
                            .font(LatteFont.base)
                            .foregroundStyle(Latte.foreground)
                            .lineSpacing(LatteFont.baseLineSpacing)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .ordered(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(LatteFont.base.monospacedDigit())
                            .foregroundStyle(Latte.foreground)
                            .frame(minWidth: 18, alignment: .trailing)
                        inlineText(item)
                            .font(LatteFont.base)
                            .foregroundStyle(Latte.foreground)
                            .lineSpacing(LatteFont.baseLineSpacing)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .quote(let content):
            HStack(alignment: .top, spacing: 12) {
                Rectangle().fill(Latte.border).frame(width: 2)
                inlineText(content)
                    .font(LatteFont.base)
                    .foregroundStyle(Latte.mutedForeground)
                    .lineSpacing(LatteFont.baseLineSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 2)
            .padding(.bottom, 12)

        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 0) {
                if !language.isEmpty {
                    Text(language)
                        .font(LatteFont.font9)
                        .foregroundStyle(Latte.mutedForeground)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Latte.codeForeground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .background(Latte.code)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Latte.codeBorder, lineWidth: 1)
            }
            .padding(.bottom, 12)

        case .divider:
            LatteDivider()
                .padding(.vertical, 14)

        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows)
                .padding(.bottom, 12)

        case .empty:
            EmptyView()
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 14 * 1.29, weight: .semibold)
        case 2: return .system(size: 14 * 1.14, weight: .semibold)
        default: return .system(size: 14 * 0.93, weight: .semibold)
        }
    }

    private func headingTop(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 24
        case 2: return 20
        default: return 16
        }
    }

    /// 内联富文本（粗体 / 斜体 / 行内代码 / 链接 / 裸 URL）。
    private func inlineText(_ raw: String) -> Text {
        Text(MarkdownInline.attributed(raw))
    }
}

// MARK: - 表格

private struct MarkdownTable: View {
    var header: [String]
    var rows: [[String]]

    var body: some View {
        VStack(spacing: 0) {
            if !header.isEmpty {
                row(header, isHeader: true, background: Latte.muted.opacity(0.45))
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                row(cells, isHeader: false,
                    background: index % 2 == 1 ? Latte.muted.opacity(0.15) : .clear)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Latte.border.opacity(0.7), lineWidth: 1)
        }
    }

    private func row(_ cells: [String], isHeader: Bool, background: Color) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                Text(MarkdownInline.attributed(cell))
                    .font(LatteFont.xs)
                    .fontWeight(isHeader ? .semibold : .regular)
                    .foregroundStyle(Latte.foreground)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlay(alignment: .trailing) {
                        if index < cells.count - 1 {
                            Rectangle().fill(Latte.border.opacity(0.7)).frame(width: 1)
                        }
                    }
            }
        }
        .background(background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Latte.border.opacity(0.7)).frame(height: 1)
        }
    }
}

// MARK: - 块级解析

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet([String])
    case ordered([String])
    case quote(String)
    case code(language: String, body: String)
    case divider
    case table(header: [String], rows: [[String]])
    case empty

    /// 逐行扫描成块。刻意保持简单：Markdown 的完整规范不在此处追求
    /// （Windows 用 Streamdown，行为差异集中在极少数边缘语法上）。
    static func parse(_ raw: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0

        func flushParagraph(_ buffer: inout [String]) {
            guard !buffer.isEmpty else { return }
            blocks.append(.paragraph(buffer.joined(separator: "\n")))
            buffer.removeAll()
        }

        var paragraph: [String] = []

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 代码围栏
            if trimmed.hasPrefix("```") {
                flushParagraph(&paragraph)
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[index])
                    index += 1
                }
                index += 1  // 跳过收尾围栏
                blocks.append(.code(language: language, body: body.joined(separator: "\n")))
                continue
            }

            // 空行 → 段落结束
            if trimmed.isEmpty {
                flushParagraph(&paragraph)
                index += 1
                continue
            }

            // 分隔线
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph(&paragraph)
                blocks.append(.divider)
                index += 1
                continue
            }

            // 标题
            if let heading = parseHeading(trimmed) {
                flushParagraph(&paragraph)
                blocks.append(heading)
                index += 1
                continue
            }

            // 引用（连续多行合并）
            if trimmed.hasPrefix(">") {
                flushParagraph(&paragraph)
                var quoted: [String] = []
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let q = lines[index].trimmingCharacters(in: .whitespaces)
                    quoted.append(String(q.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            // 表格：表头 + 分隔行
            if trimmed.hasPrefix("|"), index + 1 < lines.count,
               isTableSeparator(lines[index + 1]) {
                flushParagraph(&paragraph)
                let header = parseTableRow(trimmed)
                index += 2
                var rows: [[String]] = []
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(parseTableRow(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // 无序列表
            if parseBullet(trimmed) != nil {
                flushParagraph(&paragraph)
                var items: [String] = []
                while index < lines.count,
                      let next = parseBullet(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.bullet(items))
                continue
            }

            // 有序列表
            if parseOrdered(trimmed) != nil {
                flushParagraph(&paragraph)
                var items: [String] = []
                while index < lines.count,
                      let next = parseOrdered(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.ordered(items))
                continue
            }

            paragraph.append(line)
            index += 1
        }

        flushParagraph(&paragraph)
        return blocks
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        guard line.hasPrefix("#") else { return nil }
        let level = line.prefix(while: { $0 == "#" }).count
        guard level >= 1, level <= 6 else { return nil }
        let body = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: body)
    }

    private static func parseBullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func parseOrdered(_ line: String) -> String? {
        guard let dot = line.firstIndex(of: "."), dot > line.startIndex else { return nil }
        let digits = line[line.startIndex..<dot]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        let after = line.index(after: dot)
        guard after < line.endIndex, line[after] == " " else { return nil }
        return String(line[line.index(after: after)...])
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") || trimmed.contains("---") else { return false }
        let cells = parseTableRow(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            return c.count >= 3 && c.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func parseTableRow(_ line: String) -> [String] {
        var body = line
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }
}

// MARK: - 内联解析

enum MarkdownInline {
    /// 把 `**粗**`、`*斜*`、`` `code` ``、`[文字](链接)`、裸 URL 转成 `AttributedString`。
    static func attributed(_ raw: String) -> AttributedString {
        var out = AttributedString()
        var buffer = ""
        var index = raw.startIndex

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            out.append(AttributedString(buffer))
            buffer.removeAll()
        }

        while index < raw.endIndex {
            let rest = raw[index...]

            // 行内代码
            if rest.hasPrefix("`"), let end = findClosing("`", in: raw, from: raw.index(after: index)) {
                flushBuffer()
                let inner = String(raw[raw.index(after: index)..<end])
                var piece = AttributedString(inner)
                piece.font = .system(size: 12.6, design: .monospaced)
                piece.backgroundColor = Latte.code
                out.append(piece)
                index = raw.index(after: end)
                continue
            }

            // 粗体
            if rest.hasPrefix("**"), let end = raw.range(of: "**", range: raw.index(index, offsetBy: 2)..<raw.endIndex) {
                flushBuffer()
                let inner = String(raw[raw.index(index, offsetBy: 2)..<end.lowerBound])
                out.append(bold(inner))
                index = end.upperBound
                continue
            }

            // 斜体
            if rest.hasPrefix("*") || rest.hasPrefix("_") {
                let marker = String(rest.first!)
                if let end = raw.range(of: marker, range: raw.index(after: index)..<raw.endIndex) {
                    let inner = String(raw[raw.index(after: index)..<end.lowerBound])
                    if !inner.isEmpty, !inner.contains("\n") {
                        flushBuffer()
                        var piece = AttributedString(inner)
                        piece.inlinePresentationIntent = .emphasized
                        out.append(piece)
                        index = end.upperBound
                        continue
                    }
                }
            }

            // 链接 [文字](地址)
            if rest.hasPrefix("["),
               let close = raw.range(of: "](", range: index..<raw.endIndex),
               let end = raw.range(of: ")", range: close.upperBound..<raw.endIndex) {
                let label = String(raw[raw.index(after: index)..<close.lowerBound])
                let target = String(raw[close.upperBound..<end.lowerBound])
                flushBuffer()
                out.append(link(label, target))
                index = end.upperBound
                continue
            }

            // 裸 URL
            if rest.hasPrefix("http://") || rest.hasPrefix("https://") {
                let tail = raw[index...]
                let endIdx = tail.firstIndex { $0 == " " || $0 == "\n" || $0 == ")" || $0 == "，" || $0 == "。" }
                    ?? raw.endIndex
                let target = String(raw[index..<endIdx])
                flushBuffer()
                out.append(link(target, target))
                index = endIdx
                continue
            }

            buffer.append(raw[index])
            index = raw.index(after: index)
        }

        flushBuffer()
        return out
    }

    private static func bold(_ text: String) -> AttributedString {
        var piece = AttributedString(text)
        piece.inlinePresentationIntent = .stronglyEmphasized
        return piece
    }

    private static func link(_ label: String, _ target: String) -> AttributedString {
        var piece = AttributedString(label)
        if let url = URL(string: target) {
            piece.link = url
            piece.underlineStyle = .single
            piece.foregroundColor = Latte.primary
        }
        return piece
    }

    private static func findClosing(_ marker: Character, in text: String, from start: String.Index) -> String.Index? {
        var cursor = start
        while cursor < text.endIndex {
            if text[cursor] == marker { return cursor }
            cursor = text.index(after: cursor)
        }
        return nil
    }
}
