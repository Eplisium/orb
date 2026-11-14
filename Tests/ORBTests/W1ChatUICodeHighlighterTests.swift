import Foundation
import SwiftUI
import Testing
@testable import ORB

/// Text of each coloured token, keyed by kind.
private func w1ChatUITokens(_ source: String, _ language: String) -> [(CodeTokenKind, String)] {
    guard let spec = CodeHighlighter.spec(for: language) else { return [] }
    let units = Array(source.utf16)
    return CodeHighlighter.tokens(in: source, spec: spec).map { token in
        (token.kind, String(decoding: units[token.range], as: UTF16.self))
    }
}

private func w1ChatUIKinds(_ source: String, _ language: String, _ kind: CodeTokenKind) -> [String] {
    w1ChatUITokens(source, language).filter { $0.0 == kind }.map(\.1)
}

@Suite("W1 chat-ui: code highlighter")
struct W1ChatUICodeHighlighterTests {
    @Test("Swift: keyword, string and comment get distinct colours")
    func swiftDistinctColours() throws {
        let source = "let x = \"a\" // c"
        let attributed = try #require(CodeHighlighter.highlighted(source, language: "swift"))
        var colours: [String: Color] = [:]
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            if let colour = run.foregroundColor { colours[text] = colour }
        }
        let keyword = try #require(colours["let"])
        let string = try #require(colours["\"a\""])
        let comment = try #require(colours["// c"])
        #expect(keyword != string && string != comment && keyword != comment)
        #expect(colours["x"] == nil, "plain identifiers keep the default colour")
        #expect(String(attributed.characters) == source)
    }

    @Test("Unknown or missing languages render plain")
    func unknownLanguagePlain() {
        #expect(CodeHighlighter.highlighted("print(1)", language: "brainfork") == nil)
        #expect(CodeHighlighter.highlighted("print(1)", language: nil) == nil)
        #expect(CodeHighlighter.highlighted("", language: "swift") == nil)
        #expect(CodeHighlighter.highlighted("output text", language: "output") == nil)
    }

    @Test("Same source and language hit the cache")
    func cacheHit() throws {
        let source = "func cached\(UUID().uuidString.prefix(8))() { return 42 }"
        #expect(CodeHighlighter.cachedValue(source, language: "swift") == nil)
        let first = try #require(CodeHighlighter.highlighted(source, language: "swift"))
        #expect(CodeHighlighter.cachedValue(source, language: "swift") == first)
        let hitsBefore = CodeHighlighter.currentStats.hits
        let second = try #require(CodeHighlighter.highlighted(source, language: "Swift"))
        #expect(first == second)
        #expect(CodeHighlighter.currentStats.hits > hitsBefore)
        // Different content never shares an entry.
        #expect(CodeHighlighter.cachedValue(source + " ", language: "swift") == nil)
    }

    @Test("Streaming (open) blocks stay plain; closed blocks highlight")
    func streamingStaysPlain() throws {
        let blocks = MarkdownParser.parse("```swift\nlet a = 1")
        guard case .code(let language, let source, let isClosed) = try #require(blocks.first) else {
            Issue.record("expected a code block"); return
        }
        #expect(!isClosed)
        #expect(CodeBlockView.highlighted(source: source, language: language, isStreaming: !isClosed) == nil)
        #expect(CodeBlockView.highlighted(source: source, language: language, isStreaming: false) != nil)
    }

    @Test("Highlighting never changes the text, including emoji and combining marks")
    func roundTrip() throws {
        let samples: [(String, String)] = [
            ("swift", "let e\u{301} = \"🙂 ok\" /* 👍🏽 */ + 1..<5"),
            ("python", "s = '''multi\nline''' # cafe\u{301}"),
            ("json", "{\"k\": [1, 2.5e-3, true, null]}"),
            ("bash", "echo \"$HOME\" ${PATH} $# # done"),
            ("html", "<a href=\"x\">Don't</a><!-- c -->"),
            ("yaml", "- name: \"x\" # c\n  on: true"),
        ]
        for (language, source) in samples {
            let attributed = try #require(CodeHighlighter.highlighted(source, language: language))
            #expect(String(attributed.characters) == source, "\(language) changed its text")
        }
    }

    @Test("Each supported family finds keywords, strings, comments and numbers")
    func families() {
        #expect(w1ChatUIKinds("def f(x): # note\n    return 'y' + 3", "py", .keyword) == ["def", "return"])
        #expect(w1ChatUIKinds("def f(x): # note\n    return 'y' + 3", "python", .comment) == ["# note"])
        #expect(w1ChatUIKinds("const s = `t ${a}` // c\nlet n = 0x1F", "ts", .keyword) == ["const", "let"])
        #expect(w1ChatUIKinds("const s = `t ${a}` // c\nlet n = 0x1F", "tsx", .number) == ["0x1F"])
        #expect(w1ChatUIKinds("{\"key\": \"value\", \"n\": 2}", "json", .type) == ["\"key\"", "\"n\""])
        #expect(w1ChatUIKinds("{\"key\": \"value\", \"n\": 2}", "json", .string) == ["\"value\""])
        #expect(w1ChatUIKinds("echo $# x # tail", "sh", .comment) == ["# tail"])
        #expect(w1ChatUIKinds("export A=$HOME", "zsh", .type) == ["$HOME"])
        #expect(w1ChatUIKinds("func main() { var s string = \"x\" }", "go", .keyword) == ["func", "var"])
        #expect(w1ChatUIKinds("fn main() { let v: Vec<u8> = vec![]; }", "rust", .type) == ["Vec", "u8"])
        #expect(w1ChatUIKinds("public static void main(String[] a) { int n = 10; }", "java", .number) == ["10"])
        #expect(w1ChatUIKinds("#include <stdio.h>\nint main(void) { return 0; } /* c */", "c++", .comment) == ["/* c */"])
        #expect(w1ChatUIKinds("<div class=\"a\">hi</div><!-- c -->", "html", .keyword) == ["div", "div"])
        #expect(w1ChatUIKinds("<div class=\"a\">hi</div><!-- c -->", "xml", .string) == ["\"a\""])
        #expect(w1ChatUIKinds(".a { margin: 10px; } /* c */", "css", .number) == ["10px"])
        #expect(w1ChatUIKinds("SELECT id FROM t WHERE n = 'x' -- c", "sql", .keyword) == ["SELECT", "FROM", "WHERE"])
        #expect(w1ChatUIKinds("SELECT id FROM t WHERE n = 'x' -- c", "sqlite", .comment) == ["-- c"])
        #expect(w1ChatUIKinds("name: app # c\nitems:\n  - port: 80\n    on: true", "yml", .type) == ["name", "items", "port", "on"])
        #expect(w1ChatUIKinds("name: app # c\nitems:\n  - port: 80\n    on: true", "yaml", .keyword) == ["true"])
    }

    @Test("Swift ranges, attributes and types tokenize sensibly")
    func swiftDetails() {
        #expect(w1ChatUIKinds("for i in 1..<5 {}", "swift", .number) == ["1", "5"])
        #expect(w1ChatUIKinds("@MainActor final class A: View {}", "swift", .keyword) == ["@MainActor", "final", "class"])
        #expect(w1ChatUIKinds("@MainActor final class A: View {}", "swift", .type) == ["A", "View"])
        #expect(w1ChatUIKinds("let s = \"\"\"\nhi \"q\"\n\"\"\"", "swift", .string) == ["\"\"\"\nhi \"q\"\n\"\"\""])
        #expect(w1ChatUIKinds("let s = \"esc \\\" q\"", "swift", .string) == ["\"esc \\\" q\""])
    }

    @Test("Fence info strings with attributes resolve the language")
    func infoStrings() {
        #expect(CodeHighlighter.spec(for: "Swift title=\"a.swift\"")?.name == "swift")
        #expect(CodeHighlighter.spec(for: "js{1,3}")?.name == "javascript")
        #expect(CodeHighlighter.spec(for: "objective-c")?.name == "c")
    }

    @Test("Oversized blocks skip highlighting")
    func oversized() {
        let huge = String(repeating: "let a = 1\n", count: CodeHighlighter.maxHighlightedLength / 10 + 1)
        #expect(CodeHighlighter.highlighted(huge, language: "swift") == nil)
    }

    @Test("Syntax colours meet text contrast on every surface, light and dark")
    func contrast() {
        let surfaces = [ORBPalette.surface, ORBPalette.surfaceRaised, ORBPalette.surfaceSunken]
        for kind in CodeTokenKind.allCases {
            guard let pair = CodeSyntaxPalette.pair(for: kind) else { continue }
            for appearance in ORBAppearance.allCases {
                for surface in surfaces {
                    let ratio = ORBRGB.contrast(pair.rgb(appearance), surface.rgb(appearance))
                    #expect(ratio >= ORBPalette.minimumTextContrast, "\(kind) in \(appearance): \(ratio)")
                }
            }
        }
        let distinct = Set(CodeTokenKind.allCases.compactMap { CodeSyntaxPalette.pair(for: $0).map { "\($0.light)|\($0.dark)" } })
        #expect(distinct.count == 5)
    }

    @Test("Horizontal scroll affordance shows the clipped edges only")
    func scrollAffordance() {
        let fits = CodeScrollAffordance(contentMinX: 0, contentWidth: 300, viewportWidth: 400)
        #expect(!fits.overflows && !fits.showsLeadingFade && !fits.showsTrailingFade)
        let start = CodeScrollAffordance(contentMinX: 0, contentWidth: 900, viewportWidth: 400)
        #expect(start.overflows && !start.showsLeadingFade && start.showsTrailingFade)
        let middle = CodeScrollAffordance(contentMinX: -200, contentWidth: 900, viewportWidth: 400)
        #expect(middle.showsLeadingFade && middle.showsTrailingFade)
        let end = CodeScrollAffordance(contentMinX: -500, contentWidth: 900, viewportWidth: 400)
        #expect(end.showsLeadingFade && !end.showsTrailingFade)
    }
}
