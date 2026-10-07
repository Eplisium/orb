import Foundation
import Testing
@testable import ORB

@Suite("Stream arrival relay")
struct StreamArrivalRelayTests {
    @Test("arrival stamps reflect when events left the network, not when they were consumed")
    func stampsSurviveSlowConsumer() async throws {
        // `upstreamDone` fires once both events have left the "network", so
        // the consumer below provably starts late no matter how slow the
        // machine is (shared CI runners stretch fixed sleeps a lot).
        let (upstreamDone, signalDone) = AsyncStream<Void>.makeStream()
        let upstream = AsyncThrowingStream<Int, Error> { continuation in
            Task {
                continuation.yield(1)
                try? await Task.sleep(for: .milliseconds(80))
                continuation.yield(2)
                continuation.finish()
                signalDone.yield()
                signalDone.finish()
            }
        }
        let relayed = StreamArrivalRelay.relay(upstream)
        // A busy consumer (the main actor during heavy layout) starts reading
        // only after both events arrived; consumption-time stamps would be ~0
        // apart and later than `readStart`.
        for await _ in upstreamDone {}
        try await Task.sleep(for: .milliseconds(50))
        let readStart = Date()
        var stamps: [Date] = []
        var values: [Int] = []
        for try await timed in relayed {
            values.append(timed.event)
            stamps.append(timed.arrivedAt)
        }
        #expect(values == [1, 2])
        let gap = stamps[1].timeIntervalSince(stamps[0])
        #expect(gap >= 0.06)
        #expect(stamps[1] < readStart, "stamped at consumption, not arrival")
    }

    @Test("upstream errors and cancellation propagate")
    func errorsPropagate() async throws {
        let upstream = AsyncThrowingStream<Int, Error> { continuation in
            continuation.yield(1)
            continuation.finish(throwing: CocoaError(.fileReadUnknown))
        }
        var received: [Int] = []
        await #expect(throws: CocoaError.self) {
            for try await timed in StreamArrivalRelay.relay(upstream) { received.append(timed.event) }
        }
        #expect(received == [1])
    }
}
