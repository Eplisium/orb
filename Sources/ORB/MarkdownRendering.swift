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

            if let fence = openingFence(trimmed) {
                flushAll()
                var source: [String] = []
                var closed = false
                index += 1
                while index < lines.count {
                    if fence.isClosed(by: lines[index].trimmingCharacters(in: .whitespaces)) {
                        closed = true
                        index += 1
                        break
                    }
                    source.append(lines[index])
                    index += 1
                }
                blocks.append(.code(
                    language: fence.info.isEmpty ? nil : fence.info,
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

    /// The marker that opened a code block. A fence closes only on a line made
    /// of at least as many of the same character, so a four-backtick fence can
    /// wrap a three-backtick example and a tilde fence can wrap backticks.
    struct Fence: Equatable {
        let marker: Character
        let count: Int
        /// Text after the marker (normally the language).
        let info: String

        func isClosed(by trimmedLine: String) -> Bool {
            trimmedLine.count >= count && trimmedLine.allSatisfy { $0 == marker }
        }
    }

    /// Reads a whitespace-trimmed line as an opening fence: three or more
    /// backticks or tildes, then an optional info string. A backtick fence
    /// whose info string contains a backtick is inline code written on one
    /// line (three backticks, code, three backticks), not a block — treating
    /// it as one swallowed everything after it.
    static func openingFence(_ trimmedLine: String) -> Fence? {
        guard let marker = trimmedLine.first, marker == "`" || marker == "~" else { return nil }
        let run = trimmedLine.prefix { $0 == marker }
        guard run.count >= 3 else { return nil }
        let info = trimmedLine.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        if marker == "`", info.contains("`") { return nil }
        return Fence(marker: marker, count: run.count, info: info)
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
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            // `\|` is the only escape a table row owns. Every other backslash
            // (a Windows path, a regex) is cell text and must survive.
            if character == "\\", next < text.endIndex, text[next] == "|" {
                current.append("|")
                index = text.index(after: next)
                continue
            }
            if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
            index = next
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
        // Same fence rules as `MarkdownParser.parse`, or the two disagree
        // about where a code block ends and the cached prefix goes stale.
        var fence: MarkdownParser.Fence?
        var lineStart = utf8.index(utf8.startIndex, offsetBy: start)
        var offset = start
        var previousBlank = false
        var index = lineStart
        while index < utf8.endIndex {
            if utf8[index] == 0x0A {
                let line = text[lineStart..<index].trimmingCharacters(in: .whitespaces)
                if let open = fence {
                    if open.isClosed(by: line) { fence = nil }
                } else {
                    fence = MarkdownParser.openingFence(line)
                }
                let blank = line.isEmpty && fence == nil
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
                .orbFont(size: Self.headingSize(level), weight: .bold)
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
                            .orbFont(size: 12)
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
                            .orbFont(size: 12, weight: .semibold, design: .rounded)
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
            .orbFont(size: 12, weight: isHeader ? .semibold : .regular)
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
///
/// Closed blocks are syntax highlighted (`CodeHighlighter`, cached by content
/// hash); the block still streaming stays plain so colours never flicker as
/// tokens arrive. Long lines scroll horizontally behind a visible scroll bar
/// and an edge fade, because trackpad Macs hide scroll bars until scrolling.
struct CodeBlockView: View {
    let language: String?
    let source: String
    var isStreaming: Bool = false
    var accent: Color = .accentColor

    @State private var copied = false
    @State private var isHovering = false
    @State private var scroll = CodeScrollAffordance()
    @State private var scrollSpace = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .orbFont(size: 11, weight: .bold)
                    .foregroundStyle(accent.opacity(0.75))
                Text((language ?? "code").lowercased())
                    .orbFont(size: 11, weight: .semibold, design: .monospaced)
                    .foregroundStyle(.secondary)
                if isStreaming {
                    ProgressView().controlSize(.mini).scaleEffect(0.6)
                }
                Spacer(minLength: 8)
                if scroll.overflows {
                    Image(systemName: "arrow.left.and.right")
                        .orbFont(size: 11, weight: .semibold)
                        .foregroundStyle(.tertiary)
                        .help("Long lines: scroll sideways to see the rest")
                        .accessibilityLabel("Scrolls horizontally")
                }
                if isHovering || copied {
                    Button(action: copyCode) {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .orbFont(size: 11, weight: .medium)
                            .foregroundStyle(copied ? Color.green : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.orbSurface(0.05))

            Divider().opacity(0.4)

            ScrollView(.horizontal, showsIndicators: true) {
                codeText
                    .orbFont(size: 11.5, design: .monospaced)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(key: CodeContentFrameKey.self,
                                                   value: content.frame(in: .named(scrollSpace)))
                        }
                    }
            }
            .coordinateSpace(name: scrollSpace)
            .background {
                GeometryReader { viewport in
                    Color.clear.preference(key: CodeViewportWidthKey.self, value: viewport.size.width)
                }
            }
            .onPreferenceChange(CodeContentFrameKey.self) { frame in
                scroll.contentMinX = frame.minX
                scroll.contentWidth = frame.width
            }
            .onPreferenceChange(CodeViewportWidthKey.self) { width in scroll.viewportWidth = width }
            .mask(edgeFadeMask)
        }
        .background(.orbSurface(0.028))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.orbSurface(0.07), lineWidth: 0.5)
        }
        .onHover { isHovering = $0 }
        .contextMenu { Button("Copy code", systemImage: "doc.on.doc") { copyCode() } }
        .accessibilityAction(named: Text("Copy code")) { copyCode() }
    }

    private var codeText: Text {
        if let highlighted = Self.highlighted(source: source, language: language, isStreaming: isStreaming) {
            return Text(highlighted)
        }
        return Text(source)
    }

    /// Highlighted only once the fence has closed; nil means render plain.
    static func highlighted(source: String, language: String?, isStreaming: Bool) -> AttributedString? {
        isStreaming ? nil : CodeHighlighter.highlighted(source, language: language)
    }

    /// Fades whichever edge hides more code, so the clipped line reads as
    /// "continues" rather than "cut off".
    private var edgeFadeMask: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(scroll.showsLeadingFade ? 0.15 : 1), .black],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 24)
            Color.black
            LinearGradient(colors: [.black, .black.opacity(scroll.showsTrailingFade ? 0.15 : 1)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 32)
        }
    }

    private func copyCode() {
        AppToasts.copy(source, what: "Code")
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }
}

private struct CodeContentFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct CodeViewportWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
