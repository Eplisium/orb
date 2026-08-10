import Foundation
import Testing
@testable import ORB

@Suite("Markdown block parsing")
struct MarkdownParserTests {
    @Test("headings, paragraphs, and rules are separated")
    func basicBlocks() {
        let blocks = MarkdownParser.parse("# Title\n\nBody text.\n\n---")
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .paragraph("Body text."),
            .rule
        ])
    }

    @Test("fenced code keeps its language and closed state")
    func closedCodeFence() {
        let blocks = MarkdownParser.parse("```swift\nlet x = 1\n```")
        #expect(blocks == [.code(language: "swift", source: "let x = 1", isClosed: true)])
    }

    @Test("an unterminated fence streams as an open code block")
    func openCodeFence() {
        let blocks = MarkdownParser.parse("Here:\n```bash\nsw_vers")
        #expect(blocks == [
            .paragraph("Here:"),
            .code(language: "bash", source: "sw_vers", isClosed: false)
        ])
    }

    @Test("bullet and numbered lists group their items")
    func lists() {
        let blocks = MarkdownParser.parse("- one\n- two\n\n1. first\n2. second")
        #expect(blocks == [
            .bullet(items: ["one", "two"]),
            .numbered(items: ["first", "second"])
        ])
    }

    @Test("blockquotes collapse into one block")
    func quotes() {
        #expect(MarkdownParser.parse("> a\n> b") == [.quote("a\nb")])
    }

    @Test("hash without a space is not a heading")
    func hashtagIsNotHeading() {
        #expect(MarkdownParser.parse("#hashtag") == [.paragraph("#hashtag")])
    }

    @Test("plain text survives partial inline syntax mid-stream")
    func partialInlineSyntax() {
        let rendered = MarkdownParser.inline("a **bold")
        #expect(String(rendered.characters).contains("bold"))
    }

    @Test("code fences inside a stream do not swallow later content")
    func fenceThenText() {
        let blocks = MarkdownParser.parse("```\nx\n```\nafter")
        #expect(blocks == [
            .code(language: nil, source: "x", isClosed: true),
            .paragraph("after")
        ])
    }
}
