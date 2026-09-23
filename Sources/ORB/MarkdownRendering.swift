import SwiftUI

/// Block-level Markdown model.
///
/// `AttributedString(markdown:)` alone only handles inline syntax, so streamed
/// answers showed literal `###`, `-`, and ``` fences. Parsing into blocks lets
/// code render in a real monospaced panel with a copy button, and lets headings
/// and lists carry proper typography.
enum MarkdownBlock: Identifiable, Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullet(items: [String])
    case numbered(items: [String])
    case code(language: String?, source: String, isClosed: Bool)
    case quote(String)
    case rule

    var id: String {
        switch self {
        case .paragraph(let text): return "p:\(text)"
        case .heading(let level, let text): return "h\(level):\(text)"
        case .bullet(let items): return "ul:\(items.count):\(items.first ?? "")"
        case .numbered(let items): return "ol:\(items.count):\(items.first ?? "")"
        case .code(let language, let source, let closed):
            return "code:\(language ?? ""):\(source.count):\(closed)"
        case .quote(let text): return "q:\(text)"
        case .rule: return "hr"
        }
    }
}

enum MarkdownParser {
    /// Parses Markdown into blocks. Safe for partial input: an unterminated code
    /// fence yields an open `.code` block rather than swallowing the rest of the
    /// document, so streaming never flickers between states.
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var quote: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }
        func flushBullets() {
            guard !bullets.isEmpty else { return }
            blocks.append(.bullet(items: bullets))
            bullets.removeAll()
        }
        func flushNumbered() {
            guard !numbered.isEmpty else { return }
            blocks.append(.numbered(items: numbered))
            numbered.removeAll()
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(quote.joined(separator: "\n")))
            quote.removeAll()
        }
        func flushAll() {
            flushParagraph(); flushBullets(); flushNumbered(); flushQuote()
        }

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
                flushParagraph(); flushBullets(); flushNumbered()
                quote.append(String(trimmed.dropFirst(trimmed.hasPrefix("> ") ? 2 : 1)))
                index += 1
                continue
            }

            if let item = bulletItem(trimmed) {
                flushParagraph(); flushNumbered(); flushQuote()
                bullets.append(item)
                index += 1
                continue
            }

            if let item = numberedItem(trimmed) {
                flushParagraph(); flushBullets(); flushQuote()
                numbered.append(item)
                index += 1
                continue
            }

            flushBullets(); flushNumbered(); flushQuote()
            paragraph.append(line)
            index += 1
        }
        flushAll()
        return blocks
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

    private static func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func numberedItem(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }

    /// Inline emphasis/code/links, with a plain-text fallback so malformed
    /// mid-stream syntax never blanks a message.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)
    }
}

// MARK: - Rendering

/// Per-view memoization. This mutates only a private reference (not SwiftUI
/// `@State` during body evaluation), so the first frame and subsequent token
/// frames use exactly one parse per distinct content value.
@MainActor
final class MarkdownRenderCache {
    private var content: String?
    private var parsed: [MarkdownBlock] = []
    private(set) var parseCount = 0

    func blocks(for newContent: String) -> [MarkdownBlock] {
        guard content != newContent else { return parsed }
        let next = MarkdownParser.parse(newContent)
        content = newContent
        parsed = next
        parseCount += 1
        return next
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
        return VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block, isLast: index == blocks.count - 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock, isLast: Bool) -> some View {
        switch block {
        case .paragraph(let text):
            Text(MarkdownParser.inline(text)) + cursor(isLast)
        case .heading(let level, let text):
            Text(MarkdownParser.inline(text))
                .font(.system(size: headingSize(level), weight: .bold))
                .padding(.top, 2)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(accent.opacity(0.55))
                            .frame(width: 4, height: 4)
                            .padding(.top, 6)
                        Text(MarkdownParser.inline(item))
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(offset + 1).")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(accent.opacity(0.8))
                            .frame(minWidth: 16, alignment: .trailing)
                        Text(MarkdownParser.inline(item))
                    }
                }
            }
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

    private func cursor(_ isLast: Bool) -> Text {
        guard showsCursor, isLast else { return Text("") }
        // Soft write-head: keeps the "still typing" signal without shouting
        // louder than the text it tails.
        return Text(" ▍").foregroundColor(accent.opacity(0.55))
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 18
        case 2: return 16
        case 3: return 14
        default: return 13
        }
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
