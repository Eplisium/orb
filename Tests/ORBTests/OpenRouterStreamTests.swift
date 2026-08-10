import Foundation
import Testing
@testable import ORB

@Suite("OpenRouter SSE decoder")
struct OpenRouterStreamTests {
    private let contentEvent = Data("data: {\"id\":\"gen-1\",\"model\":\"test/model\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"héllo 🌍\"}}]}\n\n".utf8)

    @Test("one event survives every possible byte boundary")
    func everyByteBoundary() throws {
        for split in 0...contentEvent.count {
            var decoder = ServerSentEventDecoder()
            let first = try decoder.consume(contentEvent.prefix(split))
            let second = try decoder.consume(contentEvent.dropFirst(split))
            let events = first + second + (try decoder.finish())
            #expect(events == [.contentDelta(choiceIndex: 0, text: "héllo 🌍")])
        }
    }

    @Test("CRLF, comments, and data without a space are accepted")
    func framingVariants() throws {
        var decoder = ServerSentEventDecoder()
        let bytes = Data(": keep alive\r\ndata:{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"}}]}\r\n\r\n".utf8)
        #expect(try decoder.consume(bytes) == [.contentDelta(choiceIndex: 0, text: "ok")])
        #expect(try decoder.finish().isEmpty)
    }

    @Test("multiple data lines are joined according to SSE")
    func multipleDataLines() throws {
        var decoder = ServerSentEventDecoder()
        let bytes = Data("data: {\"choices\":[{\"index\":0,\"delta\":\ndata: {\"content\":\"joined\"}}]}\n\n".utf8)
        #expect(try decoder.consume(bytes) == [.contentDelta(choiceIndex: 0, text: "joined")])
    }

    @Test("unicode scalar may be fragmented at every byte")
    func unicodeFragments() throws {
        var decoder = ServerSentEventDecoder()
        var output: [OpenRouterStreamEvent] = []
        for byte in contentEvent { output += try decoder.consume(Data([byte])) }
        output += try decoder.finish()
        #expect(output == [.contentDelta(choiceIndex: 0, text: "héllo 🌍")])
    }

    @Test("DONE is typed")
    func done() throws {
        var decoder = ServerSentEventDecoder()
        #expect(try decoder.consume(Data("data:[DONE]\n\n".utf8)) == [.done])
        #expect(try decoder.finish().isEmpty)
    }

    @Test("malformed JSON reports capped raw text")
    func malformedJSON() throws {
        var decoder = ServerSentEventDecoder(diagnosticLimit: 12)
        do {
            _ = try decoder.consume(Data("data: {definitely invalid json}\n\n".utf8))
            Issue.record("Expected a decoding error")
        } catch let error as OpenRouterStreamError {
            guard case .malformedEvent(let raw) = error else {
                Issue.record("Wrong error: \(error)")
                return
            }
            #expect(raw.utf8.count <= 12)
        }
    }

    @Test("oversized events fail before unbounded allocation")
    func oversizedEvent() throws {
        var decoder = ServerSentEventDecoder(maxEventBytes: 32)
        #expect(throws: OpenRouterStreamError.self) {
            _ = try decoder.consume(Data("data: \(String(repeating: "x", count: 40))".utf8))
        }
    }

    @Test("mid-stream OpenRouter errors are typed")
    func apiError() throws {
        var decoder = ServerSentEventDecoder()
        let json = "data: {\"error\":{\"code\":429,\"message\":\"rate limited\",\"metadata\":{\"error_type\":\"rate_limit\",\"provider_name\":\"fixture\"}}}\n\n"
        let events = try decoder.consume(Data(json.utf8))
        #expect(events == [.apiError(.init(code: 429, message: "rate limited", errorType: "rate_limit", providerName: "fixture"))])
    }

    @Test("fragmented tool name and arguments remain ordered fragments")
    func toolFragments() throws {
        var decoder = ServerSentEventDecoder()
        let first = "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"read_\",\"arguments\":\"{\\\"pa\"}}]}}]}\n\n"
        let second = "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"file\",\"arguments\":\"th\\\":\\\"a\\\"}\"}}]}}]}\n\n"
        let events = try decoder.consume(Data(first.utf8)) + decoder.consume(Data(second.utf8))
        #expect(events == [
            .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: "call-1", type: "function", name: "read_", arguments: "{\"pa"),
            .toolCallFragment(choiceIndex: 0, toolIndex: 0, id: nil, type: nil, name: "file", arguments: "th\":\"a\"}")
        ])
    }

    @Test("unterminated data at EOF is rejected")
    func abruptEOF() throws {
        var decoder = ServerSentEventDecoder()
        _ = try decoder.consume(Data("data: {\"choices\":[]}".utf8))
        #expect(throws: OpenRouterStreamError.self) { _ = try decoder.finish() }
    }
}
