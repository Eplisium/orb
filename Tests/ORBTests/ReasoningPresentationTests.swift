import AppKit
import SwiftUI
import Testing
@testable import ORB

@Suite("Reasoning text presentation")
@MainActor
struct ReasoningPresentationTests {
    static let fragmented = "Let me peek into Test/src and Test\n/tests,\n and maybe\n\n README.md for\n description\n. Also\n\n the Guides\n files -\n I can\n describe\n by title\n. Maybe\n\n read\n README.md and\n list\n src/tests."

    @Test("Fragmented reasoning preserves words, punctuation, and split paths")
    func screenshotText() {
        #expect(ReasoningTextFormatter.display(Self.fragmented) == "Let me peek into Test/src and Test/tests, and maybe README.md for description. Also the Guides files - I can describe by title. Maybe read README.md and list src/tests.")
    }

    @Test("Normal paragraphs and structured Markdown retain their boundaries")
    func structuredReasoning() {
        let text = "First paragraph.\n\nSecond paragraph.\n\n## Checks\n- Read files\n- Run tests\n\n1. Inspect\n2. Verify\n\n> Quoted text\n\n```swift\nlet x = 1\n\nprint(x)\n```"
        #expect(ReasoningTextFormatter.display(text) == text)
        #expect(ReasoningTextFormatter.display("Read the\nproject first.") == "Read the project first.")
        #expect(ReasoningTextFormatter.display("Inspect\n/usr/bin") == "Inspect /usr/bin")
        #expect(ReasoningTextFormatter.display("inspect\n/usr/bin") == "inspect /usr/bin")
    }

    @Test("Rendering never changes persisted reasoning or opaque details")
    func sourceIsUntouched() {
        let details = [ReasoningDetail(type: "reasoning.text", text: Self.fragmented, signature: "fixture-signature")]
        let message = ChatMessage(role: "assistant", content: "Answer\nunchanged", reasoning: Self.fragmented, reasoningDetails: details)
        _ = ReasoningTextFormatter.display(message.reasoning ?? "")
        #expect(message.reasoning == Self.fragmented)
        #expect(message.reasoningDetails == details)
        #expect(message.content == "Answer\nunchanged")
    }

    @Test("Screenshot reasoning reflows into a compact full-width paragraph")
    func fragmentedReasoningLayout() throws {
        // Run opt-in rendering separately from stream timing tests: ImageRenderer
        // blocks MainActor while scripted deltas continue arriving.
        guard ProcessInfo.processInfo.environment["ORB_REASONING_SNAPSHOT"] != nil else { return }
        let view = ReasoningDisclosure(text: Self.fragmented, accent: .purple,
                                       isStreaming: true, startedAt: nil, duration: nil)
            .padding(20)
            .frame(width: 600)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, .dark)
            .background(Color(white: 0.17))
        let renderer = ImageRenderer(content: view)
        let image = try #require(renderer.nsImage)
        #expect(image.size.height < 180, "Reasoning must wrap to the viewport, not render each token fragment on a separate line")
        if let path = ProcessInfo.processInfo.environment["ORB_REASONING_SNAPSHOT"],
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}
