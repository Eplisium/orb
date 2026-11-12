import Foundation
import Testing
@testable import ORB

@Suite("Markdown block parsing")
struct MarkdownParserTests {
    @Test("render cache parses new content once and never returns stale blocks")
    @MainActor
    func renderCacheTracksContent() {
        let cache = MarkdownRenderCache()
        let first = cache.blocks(for: "# Hello")
        #expect(first == [.heading(level: 1, text: "Hello")])
        #expect(cache.blocks(for: "# Hello") == first)
        #expect(cache.parseCount == 1)
        #expect(cache.blocks(for: "# Hello\n\nMore") != first)
        #expect(cache.parseCount == 2)
    }

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

    @Test("incremental cache matches a full parse at every streamed prefix")
    @MainActor
    func incrementalCacheEquivalence() {
        let doc = "# T\n\nPara one\nstill one.\n\n- a\n  - nested\n- b\n\n```swift\nlet x = 1\n\nlet y = 2\n```\n\n| A | B |\n|---|--:|\n| 1 | 2 |\n\n1. x\n2. y\n\nDone."
        let cache = MarkdownRenderCache()
        var prefix = ""
        for character in doc {
            prefix.append(character)
            #expect(cache.blocks(for: prefix) == MarkdownParser.parse(prefix), "prefix: \(prefix.debugDescription)")
        }
    }

    @Test("tables parse header, alignment, and rows")
    func tables() {
        let blocks = MarkdownParser.parse("| Name | Qty |\n|:--|--:|\n| a | 1 |\n| b \\| c | 2 |")
        #expect(blocks == [.table(MarkdownTable(
            header: ["Name", "Qty"], alignments: [.leading, .trailing],
            rows: [["a", "1"], ["b | c", "2"]]))])
    }

    @Test("nested lists and task items keep depth and checkbox state")
    func nestedLists() {
        let blocks = MarkdownParser.parse("- [x] done\n- [ ] todo\n    - child")
        guard case .list(let items) = blocks.first else { Issue.record("expected list"); return }
        #expect(items.map(\.depth) == [0, 0, 1])
        #expect(items.map(\.checked) == [true, false, nil])
    }
}

@Suite("Markdown fences and table cells")
struct MarkdownFenceTableTests {
    private typealias Code = (language: String?, source: String, isClosed: Bool)

    private func codeBlock(_ text: String) throws -> Code {
        for block in MarkdownParser.parse(text) {
            if case .code(let language, let source, let isClosed) = block {
                return (language, source, isClosed)
            }
        }
        throw FenceTestError.noCodeBlock
    }

    private enum FenceTestError: Error { case noCodeBlock }

    @Test("a longer fence can wrap shorter backtick fences")
    func nestedBacktickFences() throws {
        let source = """
        ````python
        ```js
        const x = 1
        ```
        ````

        after
        """
        let code = try codeBlock(source)
        #expect(code.language == "python")
        #expect(code.isClosed)
        #expect(code.source.contains("const x = 1"))
        #expect(code.source.contains("```js"))
        // The prose after the fence must not be swallowed by it.
        #expect(MarkdownParser.parse(source).contains(.paragraph("after")))
    }

    @Test("tilde fences parse and close only on tildes")
    func tildeFences() throws {
        let code = try codeBlock("~~~swift\n```\nlet x = 1\n~~~\ndone")
        #expect(code.language == "swift")
        #expect(code.isClosed)
        #expect(code.source.contains("```"))
        #expect(code.source.contains("let x = 1"))
    }

    @Test("a one-line backtick run is paragraph text, not a fence")
    func oneLineInlineCode() throws {
        let blocks = MarkdownParser.parse("``` 1 + 1 ```\n\nstill prose")
        #expect(!blocks.contains { block in
            if case .code = block { return true }
            return false
        })
        #expect(blocks.contains(.paragraph("``` 1 + 1 ```")))
        #expect(blocks.contains(.paragraph("still prose")))
    }

    @Test("table cells keep backslashes that do not escape a pipe")
    func tableBackslashesSurvive() throws {
        let table = try #require(
            MarkdownParser.parse("| path | pattern |\n| --- | --- |\n| C:\\Users\\orb | a\\|b |").first
        )
        guard case .table(let value) = table else {
            Issue.record("expected a table")
            return
        }
        #expect(value.rows.first == ["C:\\Users\\orb", "a|b"])
    }

    @Test("the cached streaming parse matches a full parse at every prefix")
    @MainActor
    func streamingCacheMatchesFullParse() {
        let cache = MarkdownRenderCache()
        let source = """
        # Heading

        ```
        code
        ```

        | a | b |
        | --- | --- |
        | 1 | 2 |

        ~~strike~~

        ````md
        ```inner
        ```
        ````

        tail paragraph
        """
        // Chunks grow the way a stream does: the document only ever gets
        // longer, so the cached stable prefix must never go stale.
        var soFar = ""
        var next = source.startIndex
        while next < source.endIndex {
            let step = source.index(next, offsetBy: 3, limitedBy: source.endIndex) ?? source.endIndex
            soFar += source[next..<step]
            next = step
            #expect(cache.blocks(for: soFar) == MarkdownParser.parse(soFar), "prefix \(soFar.count) chars")
        }
    }
}
