import Foundation
import Testing
@testable import ORB

@Suite("Adapter SSE chunk boundary independence")
struct AdapterSSEChunkTests {
    @Test("coalesced and fragmented deliveries produce the same legal events",
          arguments: [1, 7, 64, 4096])
    func chunkBoundaries(chunkSize: Int) throws {
        let frame = Data("event: fixture\r\ndata: héllo\r\ndata: world\r\n\r\n".utf8)
        let wire = Data((0..<20).flatMap { _ in frame })
        var framer = AdapterSSEFramer(maxEventBytes: 64)
        var output: [Data] = []
        for offset in stride(from: 0, to: wire.count, by: chunkSize) {
            output += try framer.consume(wire[offset..<min(offset + chunkSize, wire.count)])
        }
        output += try framer.finish()
        #expect(output == Array(repeating: Data("héllo\nworld".utf8), count: 20))
    }

    @Test("near-limit lines reset their budgets before subsequent events",
          arguments: ["\n", "\r\n"])
    func nearLimit(lineEnding: String) throws {
        let prefix = "data: "
        // The inherited line allowance includes framing bytes, while the
        // accumulated event counter measures joined payload bytes.
        let payload = String(repeating: "x", count: 65 - prefix.utf8.count - lineEnding.utf8.count)
        let frame = Data("\(prefix)\(payload)\(lineEnding)\(lineEnding)".utf8)
        var framer = AdapterSSEFramer(maxEventBytes: 64)
        let initial = try framer.consume(frame.prefix(9))
        #expect(initial.isEmpty)
        let output = try framer.consume(Data(frame.dropFirst(9)) + frame + frame)
        #expect(output == Array(repeating: Data(payload.utf8), count: 3))
        #expect(try framer.finish().isEmpty)
        var oversized = AdapterSSEFramer(maxEventBytes: 64)
        #expect(throws: AdapterStreamError.eventTooLarge(limit: 64)) {
            _ = try oversized.consume(Data("\(prefix)\(payload)x\(lineEnding)\(lineEnding)".utf8))
        }
    }

    @Test("pump accepts a coalesced delivery larger than its per-event default")
    func coalescedPump() async throws {
        let payload = Data(String(repeating: "x", count: 4096).utf8)
        let frame = Data("data: ".utf8) + payload + Data("\n\n".utf8)
        let wire = Data((0..<300).flatMap { _ in frame }) + Data("data: done\n\n".utf8)
        let body = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(wire)
            continuation.finish()
        }
        let response = HTTPURLResponse(url: URL(string: "https://fixture.invalid/stream")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let terminal = Data("done".utf8)
        let stream = try await AdapterStreamPump.run(response: response, body: body,
            map: { [$0] }, isTerminal: { $0 == terminal })
        var output: [Data] = []
        for try await event in stream { output.append(event) }
        #expect(output == Array(repeating: payload, count: 300) + [terminal])
    }

    @Test("an oversized event remains rejected across chunk boundaries",
          arguments: [1, 8, 4096])
    func oversizedEvent(chunkSize: Int) throws {
        // Each individual line fits, but the accumulated event does not.
        let wire = Data(String(repeating: "data: 1234567890\n", count: 7).utf8)
        var framer = AdapterSSEFramer(maxEventBytes: 64)
        #expect(throws: AdapterStreamError.eventTooLarge(limit: 64)) {
            for offset in stride(from: 0, to: wire.count, by: chunkSize) {
                _ = try framer.consume(wire[offset..<min(offset + chunkSize, wire.count)])
            }
        }
    }

    @Test("unterminated comments and unknown lines remain bounded",
          arguments: [":", "event:", "data:"])
    func oversizedLine(prefix: String) throws {
        var framer = AdapterSSEFramer(maxEventBytes: 64)
        _ = try framer.consume(Data(prefix.utf8))
        #expect(throws: AdapterStreamError.eventTooLarge(limit: 64)) {
            _ = try framer.consume(Data(String(repeating: "x", count: 70).utf8))
        }
    }
}
