import AppKit
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import ORB

// MARK: - Fixtures

private enum W1Fixture {
    static func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ORB-w1chatui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A solid-colour test image; `alpha` makes it half transparent.
    static func cgImage(width: Int, height: Int, alpha: Bool) -> CGImage {
        let info: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func size(of data: Data) -> (type: String, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (type, w, h)
    }

    static func model(input: [String]) throws -> ModelInfo {
        let object: [String: Any] = ["id": "test/\(input.joined(separator: "-"))", "name": "Test",
                                     "architecture": ["input_modalities": input, "output_modalities": ["text"]]]
        return try JSONDecoder().decode(ModelInfo.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

// MARK: - CHAT-2 image transcoding

@Suite("W1 chat-ui: image transcoding")
struct W1ChatUIImageTranscodeTests {
    @Test("HEIC is re-encoded to JPEG")
    func heicToJPEG() throws {
        let heic = try #require(W1Fixture.encode(W1Fixture.cgImage(width: 64, height: 48, alpha: false), as: .heic),
                                "this Mac cannot encode HEIC fixtures")
        let out = try ChatImageTranscoder.prepare(data: heic, mimeType: "image/heic")
        #expect(out.mimeType == "image/jpeg")
        let info = try #require(W1Fixture.size(of: out.data))
        #expect(info.type == UTType.jpeg.identifier)
        #expect(info.width == 64 && info.height == 48)
    }

    @Test("BMP and TIFF are re-encoded; alpha keeps PNG")
    func bmpAndTiff() throws {
        let opaqueBMP = try #require(W1Fixture.encode(W1Fixture.cgImage(width: 20, height: 10, alpha: false), as: .bmp))
        #expect(try ChatImageTranscoder.prepare(data: opaqueBMP, mimeType: "image/bmp").mimeType == "image/jpeg")
        let alphaTIFF = try #require(W1Fixture.encode(W1Fixture.cgImage(width: 20, height: 10, alpha: true), as: .tiff))
        let out = try ChatImageTranscoder.prepare(data: alphaTIFF, mimeType: "image/tiff")
        #expect(out.mimeType == "image/png")
        #expect(W1Fixture.size(of: out.data)?.type == UTType.png.identifier)
    }

    @Test("Long edge is capped at 2048 px, keeping aspect ratio")
    func capsLongEdge() throws {
        let big = try #require(W1Fixture.encode(W1Fixture.cgImage(width: 4096, height: 1024, alpha: false), as: .png))
        let out = try ChatImageTranscoder.prepare(data: big, mimeType: "image/png")
        let info = try #require(W1Fixture.size(of: out.data))
        #expect(max(info.width, info.height) == ChatImageTranscoder.maxLongEdge)
        #expect(info.height == 512)
        #expect(out.mimeType == "image/jpeg")
    }

    @Test("Small supported images pass through byte-for-byte")
    func passthrough() throws {
        let png = try #require(W1Fixture.encode(W1Fixture.cgImage(width: 32, height: 32, alpha: true), as: .png))
        let out = try ChatImageTranscoder.prepare(data: png, mimeType: "image/png")
        #expect(out == .init(data: png, mimeType: "image/png"))
        // Undecodable bytes in a supported format are left to the provider…
        let junk = Data(repeating: 1, count: 16)
        #expect(try ChatImageTranscoder.prepare(data: junk, mimeType: "image/png").data == junk)
        // …but an undecodable HEIC fails with a readable error.
        #expect(throws: ChatImageTranscoder.TranscodeError.self) {
            try ChatImageTranscoder.prepare(data: junk, mimeType: "image/heic", filename: "x.heic")
        }
    }

    @Test("buildParts encodes HEIC/BMP drafts off the main actor as JPEG data URLs")
    func buildPartsTranscodes() async throws {
        let dir = try W1Fixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bmp = dir.appendingPathComponent("photo.bmp")
        try #require(W1Fixture.encode(W1Fixture.cgImage(width: 30, height: 20, alpha: false), as: .bmp)).write(to: bmp)
        let heic = dir.appendingPathComponent("IMG_0001.HEIC")
        if let data = W1Fixture.encode(W1Fixture.cgImage(width: 30, height: 20, alpha: false), as: .heic) {
            try data.write(to: heic)
        }
        let urls = FileManager.default.fileExists(atPath: heic.path) ? [bmp, heic] : [bmp]
        let classified = ChatAttachmentBuilder.classify(urls: urls)
        #expect(classified.warnings.isEmpty)
        let parts = try await ChatAttachmentBuilder.buildParts(for: classified.drafts)
        #expect(parts.count == urls.count)
        for part in parts {
            guard case .image(let url, _) = part else { Issue.record("expected an image part"); continue }
            #expect(url.hasPrefix("data:image/jpeg;base64,"))
        }
    }
}

// MARK: - CHAT-4 text attachments

@Suite("W1 chat-ui: text attachments")
struct W1ChatUITextAttachmentTests {
    @Test("Source and text files classify as .text with a fence language")
    func classifiesText() throws {
        let dir = try W1Fixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var urls: [URL] = []
        for name in ["main.swift", "app.py", "index.tsx", "data.json", "notes.md", "a.csv", "Dockerfile", "run.sh", "x.log"] {
            let url = dir.appendingPathComponent(name)
            try Data("hello\n".utf8).write(to: url)
            urls.append(url)
        }
        let result = ChatAttachmentBuilder.classify(urls: urls)
        #expect(result.warnings.isEmpty)
        let kinds = result.drafts.map(\.kind)
        #expect(kinds == [.text(language: "swift"), .text(language: "python"), .text(language: "tsx"),
                          .text(language: "json"), .text(language: "markdown"), .text(language: "csv"),
                          .text(language: "dockerfile"), .text(language: "bash"), .text(language: nil)])
        #expect(result.drafts[0].iconName == "doc.text")
        #expect(result.drafts[0].typeLabel == "swift")
    }

    @Test("PDFs stay file parts")
    func pdfStaysFile() throws {
        let dir = try W1Fixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("paper.pdf")
        try Data("%PDF-1.4\n".utf8).write(to: pdf)
        let drafts = ChatAttachmentBuilder.classify(urls: [pdf]).drafts
        #expect(drafts.map(\.kind) == [.file(mimeType: "application/pdf")])
        #expect(drafts.first?.isPDF == true)
    }

    @Test("Text is inlined as a fenced part with the filename and language")
    func encodesFence() async throws {
        let dir = try W1Fixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hello.swift")
        try Data("print(\"hi\")\n".utf8).write(to: url)
        let drafts = ChatAttachmentBuilder.classify(urls: [url]).drafts
        let parts = try await ChatAttachmentBuilder.buildParts(for: drafts)
        guard case .text(let text, _) = try #require(parts.first) else { Issue.record("expected text"); return }
        #expect(text == "File: hello.swift\n```swift\nprint(\"hi\")\n```")
        #expect(ChatTextAttachment.filename(in: text) == "hello.swift")
        #expect(ChatTextAttachment.filename(in: "File: notes but not a fence") == nil)
    }

    @Test("Backticks in the file lengthen the fence so it can't close early")
    func longerFence() throws {
        let text = try ChatTextAttachment.encode(data: Data("a\n```\nb".utf8), filename: "README.md", language: "markdown")
        #expect(text.contains("\n````markdown\n"))
        #expect(text.hasSuffix("\n````"))
    }

    @Test("Files over 200 KB are truncated with an honest notice, never splitting a character")
    func truncates() throws {
        // "é" is two UTF-8 bytes; an odd prefix forces the cap mid-character.
        let body = "x" + String(repeating: "é", count: ChatTextAttachment.byteCap)
        let data = Data(body.utf8)
        let text = try ChatTextAttachment.encode(data: data, filename: "big.txt", language: nil)
        #expect(text.contains("[Truncated: only the first"))
        #expect(text.contains("bytes were left out.]"))
        #expect(text.utf8.count < ChatTextAttachment.byteCap + 400)
        #expect(!text.contains("\u{FFFD}"))
    }

    @Test("Non-UTF-8 and binary files are rejected with clear copy")
    func rejectsNonUTF8() throws {
        let dir = try W1Fixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let latin1 = dir.appendingPathComponent("legacy.txt")
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: latin1) // "café" in Latin-1
        let binary = dir.appendingPathComponent("blob.log")
        try Data([0x41, 0x00, 0x42]).write(to: binary)
        let result = ChatAttachmentBuilder.classify(urls: [latin1, binary])
        #expect(result.drafts.isEmpty)
        #expect(result.warnings == [ChatTextAttachment.notTextMessage("legacy.txt"),
                                    ChatTextAttachment.notTextMessage("blob.log")])
        #expect(result.warnings[0].contains("isn't UTF-8 text"))
    }

    @Test("Only the inlined prefix counts toward the 24 MB total")
    func countsPrefixOnly() throws {
        let dir = try W1Fixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("huge.log")
        try Data(repeating: 0x61, count: 1_000_000).write(to: url)
        let draft = try #require(ChatAttachmentBuilder.classify(urls: [url]).drafts.first)
        #expect(draft.estimatedTokens == ChatTextAttachment.byteCap / 4)
    }
}

// MARK: - CHAT-3 / CHAT-11 capability warnings

@Suite("W1 chat-ui: capability warnings")
struct W1ChatUICapabilityTests {
    private func draft(_ name: String, _ kind: ChatAttachmentDraft.Kind) -> ChatAttachmentDraft {
        ChatAttachmentDraft(url: URL(fileURLWithPath: "/tmp/\(name)"), kind: kind, byteCount: 10)
    }

    @Test("PDF on a model without file input names the engine and cost, never 'ignored'")
    func pdfCopy() throws {
        let textOnly = try W1Fixture.model(input: ["text"])
        let pdf = draft("a.pdf", .file(mimeType: "application/pdf"))
        let defaultCopy = AttachmentCapability.warnings(model: textOnly, drafts: [pdf])
        #expect(defaultCopy.count == 1)
        #expect(defaultCopy[0].contains("Mistral OCR"))
        #expect(defaultCopy[0].contains("per page"))
        #expect(!defaultCopy[0].localizedCaseInsensitiveContains("ignored"))

        var settings = GenerationSettings.default
        settings.extraPlugins = [ExtraPlugin(kind: .fileParser, pdfEngine: "cloudflare-ai")]
        let free = AttachmentCapability.warnings(model: textOnly, drafts: [pdf], settings: settings)
        #expect(free == [PDFParsingCopy.warning(engine: "cloudflare-ai")])
        #expect(free[0].contains("Cloudflare AI") && free[0].contains("free"))

        settings.extraPlugins = [ExtraPlugin(kind: .fileParser, pdfEngine: "native")]
        let native = AttachmentCapability.warnings(model: textOnly, drafts: [pdf], settings: settings)
        #expect(native[0].contains("native") && native[0].contains("fail"))
        #expect(PDFParsingCopy.warning(engine: "future-engine").contains("“future-engine”"))

        // Models that read files natively get no PDF note.
        let fileModel = try W1Fixture.model(input: ["text", "file"])
        #expect(AttachmentCapability.warnings(model: fileModel, drafts: [pdf]).isEmpty)
    }

    @Test("Text attachments never warn: every model reads text")
    func textNeverWarns() throws {
        let textOnly = try W1Fixture.model(input: ["text"])
        #expect(AttachmentCapability.warnings(model: textOnly, drafts: [draft("a.swift", .text(language: "swift"))]).isEmpty)
    }

    @Test("Switching model recomputes warnings in both directions")
    func recomputesOnModelSwitch() throws {
        let image = draft("a.png", .image(mimeType: "image/png"))
        let vision = try W1Fixture.model(input: ["text", "image"])
        let textOnly = try W1Fixture.model(input: ["text"])
        let attachNotes = ["Skipped duplicate: a.png."]
        let onText = ComposerWarnings.make(classify: attachNotes, model: textOnly, drafts: [image])
        #expect(onText.count == 2)
        #expect(onText[1].contains("cannot see images"))
        let onVision = ComposerWarnings.make(classify: attachNotes, model: vision, drafts: [image])
        #expect(onVision == attachNotes)
        let backToText = ComposerWarnings.make(classify: attachNotes, model: textOnly, drafts: [image])
        #expect(backToText == onText)
        #expect(ComposerWarnings.make(classify: [], model: textOnly, drafts: []).isEmpty)
    }

    @Test("GenerationSettings exposes the file-parser engine")
    func pdfEngineSetting() {
        var settings = GenerationSettings.default
        #expect(settings.pdfEngine == nil)
        settings.extraPlugins = [ExtraPlugin(kind: .moderation), ExtraPlugin(kind: .fileParser, pdfEngine: "mistral-ocr")]
        #expect(settings.pdfEngine == "mistral-ocr")
        settings.extraPlugins = [ExtraPlugin(kind: .fileParser, pdfEngine: "")]
        #expect(settings.pdfEngine == nil)
    }
}

// MARK: - CHAT-9 sent attachments

@Suite("W1 chat-ui: sent attachment strip")
struct W1ChatUISentAttachmentTests {
    @Test("Parts map to thumbnails and chips; prose text parts are skipped")
    func items() throws {
        let inlined = try ChatTextAttachment.encode(data: Data("x".utf8), filename: "a.py", language: "python")
        let parts: [MessageContentPart] = [
            .textPart("What's in these?"),
            .imageDataPart(Data([1, 2, 3]), mimeType: "image/png"),
            .image(url: "https://example.com/cat.jpg"),
            .fileDataPart(filename: "paper.pdf", data: Data([1]), mimeType: "application/pdf"),
            .textPart(inlined),
            .audioDataPart(Data([1]), format: "mp3"),
            .video(url: "data:video/mp4;base64,AA=="),
        ]
        let items = SentAttachmentSummary.items(parts)
        #expect(items.count == 6)
        guard case .image(let index, let url) = items[0] else { Issue.record("expected image"); return }
        #expect(index == 1 && url.hasPrefix("data:image/png;base64,"))
        #expect(items[1] == .remoteImage(url: "https://example.com/cat.jpg"))
        #expect(items[1].title == "cat.jpg")
        #expect(items[2] == .file(name: "paper.pdf", typeLabel: "pdf"))
        #expect(items[3] == .text(name: "a.py"))
        #expect(items[3].badge == "py")
        #expect(items[4] == .audio(format: "mp3"))
        #expect(items[5] == .video)
    }

    @Test("Unnamed files fall back to the data URL's type")
    func unnamedFile() {
        #expect(SentAttachmentSummary.typeLabel(filename: nil, dataURL: "data:application/pdf;base64,AA") == "pdf")
        #expect(SentAttachmentSummary.typeLabel(filename: "", dataURL: nil) == "file")
    }

    @Test("Thumbnails decode small, off the main actor")
    func thumbnail() throws {
        let png = try #require(W1Fixture.encode(W1Fixture.cgImage(width: 800, height: 400, alpha: false), as: .png))
        let dataURL = "data:image/png;base64,\(png.base64EncodedString())"
        let thumb = try #require(SentImageThumbnailCache.thumbnailPNG(dataURL: dataURL, maxPixelSize: 128))
        let info = try #require(W1Fixture.size(of: thumb))
        #expect(info.width == 128 && info.height == 64)
        #expect(SentImageThumbnailCache.thumbnailPNG(dataURL: "https://x/y.png", maxPixelSize: 128) == nil)
    }
}

// MARK: - CHAT-13 context gauge

@Suite("W1 chat-ui: context gauge")
@MainActor
struct W1ChatUIContextGaugeTests {
    @Test("Baseline is the last reply's reported prompt + completion tokens")
    func baseline() throws {
        let messages = [
            ChatMessage(role: "user", content: String(repeating: "a", count: 40_000)),
            ChatMessage(role: "assistant", content: "ok", usage: MessageUsage(promptTokens: 1_000, completionTokens: 200)),
            ChatMessage(role: "user", content: String(repeating: "b", count: 400)),
        ]
        let gauge = try #require(ContextGauge.make(system: String(repeating: "s", count: 4_000), history: messages,
                                                   draft: "abcd", contextLength: 100_000))
        // 1,200 measured + 100 newer + 1 draft; the system prompt and early
        // turns are already inside promptTokens.
        #expect(gauge.usedTokens == 1_301)
    }

    @Test("Without reported usage it estimates everything, with attachment allowances")
    func fallback() throws {
        let messages = [
            ChatMessage(role: "user", content: "abcd", parts: [.textPart("abcd"), .imageDataPart(Data([1]), mimeType: "image/png")]),
            ChatMessage(role: "assistant", content: "abcdefgh"),
        ]
        let gauge = try #require(ContextGauge.make(system: "abcd", history: messages, draft: "", draftAllowance: 3_000,
                                                   contextLength: 100_000))
        #expect(gauge.usedTokens == 1 + 1 + 1 + ContextGauge.imageAllowance + 2 + 3_000)
        #expect(ContextGauge.make(system: "", history: [], draft: "x", contextLength: nil) == nil)
    }

    @Test("Memo recomputes only when an input changes")
    func memo() throws {
        let memo = ContextGaugeMemo()
        var messages = [ChatMessage(role: "user", content: "hello")]
        func key() -> ContextGaugeMemo.Key {
            .init(conversationID: nil, messages: messages, system: "", draft: "d", draftAllowance: 0, contextLength: 1_000)
        }
        let compute = { ContextGauge.make(system: "", history: messages, draft: "d", contextLength: 1_000) }
        for _ in 0..<30 { _ = memo.gauge(for: key(), compute: compute) }
        #expect(memo.computeCount == 1)
        messages[0].content += " world" // a streamed delta
        let updated = try #require(memo.gauge(for: key(), compute: compute))
        #expect(memo.computeCount == 2)
        #expect(updated.usedTokens == ContextGauge.estimateTokens("hello world") + 1)
    }
}

// MARK: - CHAT-14 keyboard

@Suite("W1 chat-ui: keyboard")
struct W1ChatUIKeyboardTests {
    private func model(_ id: String) throws -> ModelInfo {
        let object: [String: Any] = ["id": id, "name": id]
        return try JSONDecoder().decode(ModelInfo.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test("Picker ↑/↓ clamp at the ends and Return picks the highlight")
    func pickerNavigation() throws {
        let a = try model("x/a"), b = try model("x/b"), c = try model("x/c")
        let sections = [AgentModelSection(title: "Favorites", models: [a]),
                        AgentModelSection(title: "All", models: [a, b, c])]
        let rows = ModelPickerKeyboard.flattened(sections)
        #expect(rows.count == 4)
        #expect(Set(rows.map(\.rowID)).count == 4, "a favorite also listed under All needs its own row id")
        #expect(ModelPickerKeyboard.moved(0, by: -1, count: 4) == 0)
        #expect(ModelPickerKeyboard.moved(0, by: 1, count: 4) == 1)
        #expect(ModelPickerKeyboard.moved(3, by: 1, count: 4) == 3)
        #expect(ModelPickerKeyboard.moved(9, by: 0, count: 4) == 3)
        #expect(ModelPickerKeyboard.selection(in: sections, highlighted: 2)?.id == "x/b")
        #expect(ModelPickerKeyboard.selection(in: sections, highlighted: 0)?.id == "x/a")
        #expect(ModelPickerKeyboard.selection(in: [], highlighted: 0) == nil)
    }

    @Test("Choose Model (⌘L) and Find in Conversation (⇧⌘F) don't collide, and ⌘F stays global")
    func shortcuts() {
        #expect(ConversationShortcuts.chooseModel == KeyboardShortcut("l", modifiers: .command))
        #expect(ConversationShortcuts.findInConversation == KeyboardShortcut("f", modifiers: [.command, .shift]))
        let combos = ShellShortcuts.allBoundCombos
        #expect(Set(combos).count == combos.count)
        #expect(!ConversationShortcuts.all.contains(KeyboardShortcut("f", modifiers: .command)))
    }

    @Test("↑ edits the last message only from an empty, idle composer")
    func arrowPolicy() {
        func edits(text: String = "", modifiers: EventModifiers = [], composing: Bool = false, drafts: Bool = false,
                   editing: Bool = false, running: Bool = false) -> Bool {
            ChatComposerArrowPolicy.editsLastMessage(text: text, modifiers: modifiers, composing: composing,
                                                     hasDrafts: drafts, isEditing: editing, isRunning: running)
        }
        #expect(edits())
        #expect(!edits(text: "draft"))
        #expect(!edits(text: "\n"))
        #expect(!edits(modifiers: .shift))
        #expect(!edits(modifiers: .command))
        #expect(!edits(composing: true), "IME composition owns the arrow keys")
        #expect(!edits(drafts: true))
        #expect(!edits(editing: true))
        #expect(!edits(running: true))
        let messages = [ChatMessage(role: "user", content: "one"), ChatMessage(role: "assistant", content: "a"),
                        ChatMessage(role: "user", content: "two"), ChatMessage(role: "assistant", content: "b")]
        #expect(ChatComposerArrowPolicy.lastUserMessageID(in: messages) == messages[2].id)
        #expect(ChatComposerArrowPolicy.lastUserMessageID(in: []) == nil)
    }

    @Test("Continue is offered only for a reply cut off at the length limit")
    func continuation() {
        let user = ChatMessage(role: "user", content: "q")
        let cut = ChatMessage(role: "assistant", content: "a", status: .truncated, finishReason: "length")
        let lengthOnly = ChatMessage(role: "assistant", content: "a", finishReason: "length")
        let done = ChatMessage(role: "assistant", content: "a", finishReason: "stop")
        #expect(ChatContinuation.canContinue([user, cut], running: false))
        #expect(ChatContinuation.canContinue([user, lengthOnly], running: false))
        #expect(!ChatContinuation.canContinue([user, cut], running: true))
        #expect(!ChatContinuation.canContinue([user, done], running: false))
        #expect(!ChatContinuation.canContinue([cut, user], running: false))
        #expect(!ChatContinuation.prompt.isEmpty)
    }

    @Test("Find in conversation matches case- and accent-insensitively and wraps")
    func find() {
        let messages = [ChatMessage(role: "user", content: "Tell me about Café culture"),
                        ChatMessage(role: "assistant", content: "cafe life is…"),
                        ChatMessage(role: "system", content: "cafe system"),
                        ChatMessage(role: "assistant", content: "nothing here")]
        let matches = ChatFindModel.matches(in: messages, query: "  CAFE ")
        #expect(matches == [messages[0].id, messages[1].id])
        #expect(ChatFindModel.matches(in: messages, query: " ").isEmpty)
        #expect(ChatFindModel.stepped(1, by: 1, count: 2) == 0)
        #expect(ChatFindModel.stepped(0, by: -1, count: 2) == 1)
        #expect(ChatFindModel.target(in: matches, index: 5) == messages[1].id)
        #expect(ChatFindModel.status(query: "cafe", index: 0, count: 2) == "1 of 2")
        #expect(ChatFindModel.status(query: "zzz", index: 0, count: 0) == "No matches")
        #expect(ChatFindModel.status(query: "", index: 0, count: 0) == "")
    }
}

// MARK: - V-9 welcome starters

@Suite("W1 chat-ui: welcome starters")
struct W1ChatUIWelcomeTests {
    @Test("Starters are actionable and round-trip by title")
    func starters() {
        let titles = ChatWelcomeStarter.allCases.map(\.suggestion.title)
        #expect(Set(titles).count == titles.count)
        for starter in ChatWelcomeStarter.allCases {
            #expect(ChatWelcomeStarter(title: starter.suggestion.title) == starter)
        }
        #expect(ChatWelcomeStarter.chooseModel.action == .openModelPicker)
        #expect(ChatWelcomeStarter.summarizeFile.action == .prompt(ChatWelcomeStarter.summarizePrompt, attach: true))
        #expect(!titles.contains("Streaming") && !titles.contains("Markdown"))
    }
}
