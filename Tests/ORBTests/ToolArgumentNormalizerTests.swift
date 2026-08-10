import Foundation
import Testing
@testable import ORB

@Suite("Tool argument normalization")
struct ToolArgumentNormalizerTests {
    @Test("omitted, empty, and null arguments become an empty object")
    func emptyPayloads() {
        #expect(ToolArgumentNormalizer.normalize("") == "{}")
        #expect(ToolArgumentNormalizer.normalize("   ") == "{}")
        #expect(ToolArgumentNormalizer.normalize("null") == "{}")
        #expect(ToolArgumentNormalizer.normalize("{}") == "{}")
    }

    @Test("valid objects pass through untouched")
    func validObject() {
        let raw = "{\"command\":\"ls -la\"}"
        #expect(ToolArgumentNormalizer.normalize(raw) == raw)
    }

    @Test("double-encoded JSON strings are unwrapped")
    func doubleEncoded() {
        let raw = "\"{\\\"command\\\":\\\"uptime\\\"}\""
        #expect(ToolArgumentNormalizer.normalize(raw) == "{\"command\":\"uptime\"}")
    }

    @Test("markdown code fences are stripped")
    func codeFenced() {
        let raw = "```json\n{\"path\":\"/tmp/a\"}\n```"
        #expect(ToolArgumentNormalizer.normalize(raw) == "{\"path\":\"/tmp/a\"}")
    }

    @Test("trailing provider bytes after the object are discarded")
    func trailingBytes() {
        let raw = "{\"command\":\"sw_vers\"}<|tool_end|>"
        #expect(ToolArgumentNormalizer.normalize(raw) == "{\"command\":\"sw_vers\"}")
    }

    @Test("concatenated objects keep only the first")
    func concatenatedObjects() {
        let raw = "{\"command\":\"a\"}{\"command\":\"b\"}"
        #expect(ToolArgumentNormalizer.normalize(raw) == "{\"command\":\"a\"}")
    }

    @Test("braces inside string values do not end the scan early")
    func bracesInStrings() {
        let raw = "{\"command\":\"echo {not json}\"} trailing"
        #expect(ToolArgumentNormalizer.normalize(raw) == "{\"command\":\"echo {not json}\"}")
    }

    @Test("truncated and non-object payloads are unrecoverable")
    func unrecoverable() {
        #expect(ToolArgumentNormalizer.normalize("{\"command\":\"ls") == nil)
        #expect(ToolArgumentNormalizer.normalize("[1,2,3]") == nil)
        #expect(ToolArgumentNormalizer.normalize("not json at all") == nil)
    }
}
