import SwiftUI

/// Block-level Markdown model.
///
/// `AttributedString(markdown:)` alone only handles inline syntax, so streamed
/// answers showed literal `###`, `-`, and ``` fences. Parsing into blocks lets
/// code render in a real monospaced panel with a copy button, tables render as
/// grids, and lists keep nesting, task checkboxes, and numbering.
struct MarkdownListItem: Equatable {
    var depth: Int
    var marker: String
    var text: String
    var checked: Bool?
}

struct MarkdownTable: Equatable {
    enum Alignment: Equatable { case leading, center, trailing }
    var header: [String]
    var alignments: [Alignment]
    var rows: [[String]]
}

enum MarkdownBlock: Identifiable, Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullet(items: [String])
    case numbered(items: [String])
    case list(items: [MarkdownListItem])
    case table(MarkdownTable)
    case code(language: String?, source: String, isClosed: Bool)
    case quote(String)
    case rule

    var id: String {
        switch self {
        case .paragraph(let text): return "p:\(text)"
        case .heading(let level, let text): return "h\(level):\(text)"
        case .bullet(let items): return "ul:\(items.count):\(items.first ?? "")"
        case .numbered(let items): return "ol:\(items.count):\(items.first ?? "")"
        case .list(let items): return "li:\(items.count):\(items.first?.text ?? "")"
        case .table(let table): return "t:\(table.rows.count):\(table.header.joined(separator: "|"))"
        case .code(let language, let source, let closed):
            return "code:\(language ?? ""):\(source.count):\(closed)"
        case .quote(let text): return "q:\(text)"
        case .rule: return "hr"
        }
    }
}

enum MarkdownParser {
    private struct RawListItem {
        var indent: Int
        var ordered: Bool
        var number: Int
        var text: String
        var checked: Bool?
    }

    /// Parses Markdown into blocks. Safe for partial input: an unterminated code
    /// fence yields an open `.code` block rather than swallowing the rest of the
    /// document, so streaming never flickers between states.
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var listRun: [RawListItem] = []
        var quote: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }
        func flushList() {
            guard !listRun.isEmpty else { return }
            blocks.append(makeList(listRun))
            listRun.removeAll()
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(quote.joined(separator: "\n")))
            quote.removeAll()
        }
        func flushAll() { flushParagraph(); flushList(); flushQuote() }

        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushAll()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var source: [String] = []
                var closed = false
                index += 1
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        closed = true
                        index += 1
                        break
                    }
                    source.append(lines[index])
                    index += 1
                }
                blocks.append(.code(
                    language: language.isEmpty ? nil : language,
                    source: source.joined(separator: "\n"),
                    isClosed: closed
                ))
                continue
            }

            if trimmed.isEmpty {
                flushAll()
                index += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll()
                blocks.append(.rule)
                index += 1
                continue
            }

            if let hashes = headingLevel(trimmed) {
                flushAll()
                let body = String(trimmed.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: min(hashes, 4), text: body))
                index += 1
                continue
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph(); flushList()
                quote.append(String(trimmed.dropFirst(trimmed.hasPrefix("> ") ? 2 : 1)))
                index += 1
                continue
            }

            // Table: header row followed by a delimiter row.
            if trimmed.contains("|"), index + 1 < lines.count,
               let alignments = tableAlignments(lines[index + 1]) {
                flushAll()
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    rows.append(tableCells(row))
                    index += 1
                }
                blocks.append(.table(MarkdownTable(header: header, alignments: alignments, rows: rows)))
                continue
            }

            if let item = listItem(line) {
                flushParagraph(); flushQuote()
                if let first = listRun.first, let top = listRun.map(\.indent).min(),
                   item.indent <= top, item.ordered != first.ordered {
                    flushList()
                }
                listRun.append(item)
                index += 1
                continue
            }

            // Indented continuation of the previous list item.
            if !listRun.isEmpty, line.hasPrefix("  ") {
                listRun[listRun.count - 1].text += "\n" + trimmed
                index += 1
                continue
            }

            flushList(); flushQuote()
            paragraph.append(line)
            index += 1
        }
        flushAll()
        return blocks
    }

    private static func makeList(_ run: [RawListItem]) -> MarkdownBlock {
        // Normalise arbitrary indent widths (2, 3, 4 spaces, tabs) into depths.
        var stack: [Int] = []
        var counters: [Int: Int] = [:]
        var items: [MarkdownListItem] = []
        for raw in run {
            while let last = stack.last, raw.indent < last { stack.removeLast() }
            if stack.last != raw.indent { stack.append(raw.indent) }
            let depth = stack.count - 1
            counters = counters.filter { $0.key <= depth }
            let marker: String
            if raw.ordered {
                let value = counters[depth].map { $0 + 1 } ?? raw.number
                counters[depth] = value
                marker = "\(value)."
            } else {
                counters[depth] = nil
                marker = "•"
            }
            items.append(MarkdownListItem(depth: depth, marker: marker, text: raw.text, checked: raw.checked))
        }
        let flat = items.allSatisfy { $0.depth == 0 && $0.checked == nil }
        if flat, let first = run.first {
            if !first.ordered { return .bullet(items: items.map(\.text)) }
            if first.number == 1 { return .numbered(items: items.map(\.text)) }
        }
        return .list(items: items)
    }

    private static func listItem(_ line: String) -> RawListItem? {
        var indent = 0
        var rest = Substring(line)
        while let first = rest.first, first == " " || first == "\t" {
            indent += first == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        var text: String
        var ordered = false
        var number = 1
        if let marker = ["- ", "* ", "+ "].first(where: { rest.hasPrefix($0) }) {
            text = String(rest.dropFirst(marker.count))
        } else {
            let digits = rest.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            let tail = rest.dropFirst(digits.count)
            guard tail.hasPrefix(". ") || tail.hasPrefix(") ") else { return nil }
            ordered = true
            number = Int(digits) ?? 1
            text = String(tail.dropFirst(2))
        }
        var checked: Bool?
        if text.hasPrefix("[ ] ") { checked = false; text = String(text.dropFirst(4)) }
        else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { checked = true; text = String(text.dropFirst(4)) }
        return RawListItem(indent: indent, ordered: ordered, number: number, text: text, checked: checked)
    }

    private static func headingLevel(_ line: String) -> Int? {
        var count = 0
        for character in line {
            if character == "#" { count += 1 } else { break }
        }
        guard count > 0, count <= 6 else { return nil }
        let remainder = line.dropFirst(count)
        guard remainder.first == " " else { return nil }
        return count
    }

    private static func tableCells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "|" { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(character)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func tableAlignments(_ line: String) -> [MarkdownTable.Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix(":") else { return nil }
        let cells = tableCells(trimmed)
        guard !cells.isEmpty else { return nil }
        var result: [MarkdownTable.Alignment] = []
        for cell in cells {
            guard !cell.isEmpty, cell.allSatisfy({ $0 == "-" || $0 == ":" }), cell.contains("-") else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): result.append(.center)
            case (false, true): result.append(.trailing)
            default: result.append(.leading)
            }
        }
        return result
    }

    /// Inline emphasis/code/links, with a plain-text fallback so malformed
    /// mid-stream syntax never blanks a message. Results are cached: completed
    /// blocks are re-evaluated on every streamed frame otherwise.
    static func inline(_ text: String) -> AttributedString {
        let key = text as NSString
        if let hit = inlineCache.object(forKey: key) { return hit.value }
        var attributed = (try? AttributedString(
            markdown: text,
            options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)
        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].font = .system(size: 12, design: .monospaced)
                attributed[run.range].backgroundColor = Color.primary.opacity(0.08)
            }
        }
        inlineCache.setObject(InlineBox(attributed), forKey: key, cost: text.utf8.count)
        return attributed
    }

    private final class InlineBox {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    nonisolated(unsafe) private static let inlineCache: NSCache<NSString, InlineBox> = {
        let cache = NSCache<NSString, InlineBox>()
        cache.totalCostLimit = 2_000_000
        return cache
    }()
}

// MARK: - Rendering

/// Incremental parse cache. Everything up to the last blank line outside a code
/// fence is *stable* (later tokens can't change it), so it is parsed once and
/// reused; only the trailing unstable region is re-parsed per streamed frame.
/// This turns per-frame cost from O(total length) into O(tail length).
@MainActor
final class MarkdownRenderCache {
    private var content: String?
    private var parsed: [MarkdownBlock] = []
    private var stableText = ""
    private var stableBlocks: [MarkdownBlock] = []
    private(set) var parseCount = 0

    func blocks(for newContent: String) -> [MarkdownBlock] {
        guard content != newContent else { return parsed }
        if !newContent.hasPrefix(stableText) {
            stableText = ""
            stableBlocks = []
        }
        let boundary = stableBoundary(in: newContent, from: stableText.utf8.count)
        if boundary > stableText.utf8.count {
            let start = newContent.utf8.index(newContent.utf8.startIndex, offsetBy: stableText.utf8.count)
            let end = newContent.utf8.index(newContent.utf8.startIndex, offsetBy: boundary)
            stableBlocks += MarkdownParser.parse(String(newContent[start..<end]))
            stableText = String(newContent[..<end])
        }
        let tailStart = newContent.utf8.index(newContent.utf8.startIndex, offsetBy: stableText.utf8.count)
        let tail = String(newContent[tailStart...])
        let next = stableBlocks + (tail.isEmpty ? [] : MarkdownParser.parse(tail))
        content = newContent
        parsed = next
        parseCount += 1
        return next
    }

    /// UTF-8 offset just past the last blank-line break outside a fence.
    private func stableBoundary(in text: String, from start: Int) -> Int {
        let utf8 = text.utf8
        var boundary = start
        var inFence = false
        var lineStart = utf8.index(utf8.startIndex, offsetBy: start)
        var offset = start
        var previousBlank = false
        var index = lineStart
        while index < utf8.endIndex {
            if utf8[index] == 0x0A {
                let line = text[lineStart..<index].trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("```") { inFence.toggle() }
                let blank = line.isEmpty && !inFence
                if blank && !previousBlank { boundary = offset + 1 }
                previousBlank = blank
                lineStart = utf8.index(after: index)
            }
            offset += 1
            index = utf8.index(after: index)
        }
        return boundary
    }
}

/// Equatable so SwiftUI skips finished blocks while the tail streams.
private struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    let accent: Color
    let cursor: Bool

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(MarkdownParser.inline(text)) + cursorText
        case .heading(let level, let text):
            Text(MarkdownParser.inline(text))
                .font(.system(size: Self.headingSize(level), weight: .bold))
                .padding(.top, level <= 2 ? 6 : 2)
        case .bullet(let items):
            listView(items.map { MarkdownListItem(depth: 0, marker: "•", text: $0, checked: nil) })
        case .numbered(let items):
            listView(items.enumerated().map { MarkdownListItem(depth: 0, marker: "\($0.offset + 1).", text: $0.element, checked: nil) })
        case .list(let items):
            listView(items)
        case .table(let table):
            MarkdownTableView(table: table, accent: accent)
        case .code(let language, let source, let isClosed):
            CodeBlockView(language: language, source: source, isStreaming: !isClosed, accent: accent)
        case .quote(let text):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accent.opacity(0.45))
                    .frame(width: 3)
                Text(MarkdownParser.inline(text))
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    private func listView(_ items: [MarkdownListItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let checked = item.checked {
                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                            .font(.system(size: 12))
                            .foregroundStyle(checked ? accent : Color.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                    } else if item.marker == "•" {
                        Circle()
                            .fill(accent.opacity(item.depth == 0 ? 0.55 : 0.35))
                            .frame(width: 4, height: 4)
                            .padding(.top, 6)
                            .frame(minWidth: 16, alignment: .trailing)
                    } else {
                        Text(item.marker)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(accent.opacity(0.8))
                            .frame(minWidth: 16, alignment: .trailing)
                    }
                    if offset == items.count - 1 {
                        Text(MarkdownParser.inline(item.text)) + cursorText
                    } else {
                        Text(MarkdownParser.inline(item.text))
                    }
                }
                .padding(.leading, CGFloat(item.depth) * 18)
            }
        }
    }

    private var cursorText: Text {
        guard cursor else { return Text("") }
        return Text(" ▍").foregroundColor(accent.opacity(0.55))
    }

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 18
        case 2: return 16
        case 3: return 14
        default: return 13
        }
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable
    let accent: Color

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                        cellView(cell, column: column, isHeader: true)
                    }
                }
                .background(accent.opacity(0.10))
                ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(0..<table.header.count, id: \.self) { column in
                            cellView(column < row.count ? row[column] : "", column: column, isHeader: false)
                        }
                    }
                    .background(rowIndex.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035))
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.10), lineWidth: 0.5) }
    }

    private func cellView(_ text: String, column: Int, isHeader: Bool) -> some View {
        let alignment = column < table.alignments.count ? table.alignments[column] : .leading
        return Text(MarkdownParser.inline(text))
            .font(.system(size: 12, weight: isHeader ? .semibold : .regular))
            .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .textSelection(.enabled)
    }
}

struct MarkdownText: View {
    let content: String
    var accent: Color = .accentColor
    /// Streaming messages get a caret on the trailing block.
    var showsCursor: Bool = false

    /// Local reference cache is not observable state: it avoids duplicate
    /// parses on initial mount and on every streaming content change.
    @State private var renderCache = MarkdownRenderCache()

    var body: some View {
        let blocks = renderCache.blocks(for: content)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(block: block, accent: accent,
                                  cursor: showsCursor && index == blocks.count - 1)
                    .equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Syntax-panel code block with a language chip and a copy button.
struct CodeBlockView: View {
    let language: String?
    let source: String
    var isStreaming: Bool = false
    var accent: Color = .accentColor

    @State private var copied = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(accent.opacity(0.75))
                Text((language ?? "code").lowercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                if isStreaming {
                    ProgressView().controlSize(.mini).scaleEffect(0.6)
                }
                Spacer(minLength: 8)
                if isHovering || copied {
                    Button(action: copyCode) {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(copied ? Color.green : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05))

            Divider().opacity(0.4)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(source)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.primary.opacity(0.028))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
        .onHover { isHovering = $0 }
        .contextMenu { Button("Copy code", systemImage: "doc.on.doc") { copyCode() } }
        .accessibilityAction(named: Text("Copy code")) { copyCode() }
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }
}
