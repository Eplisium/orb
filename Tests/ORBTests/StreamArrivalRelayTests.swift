import Foundation
import Testing
@testable import ORB

@Suite("Stream arrival relay")
struct StreamArrivalRelayTests {
    @Test("arrival stamps reflect when events left the network, not when they were consumed")
    func stampsSurviveSlowConsumer() async throws {
        let upstream = AsyncThrowingStream<Int, Error> { continuation in
            Task {
                continuation.yield(1)
                try? await Task.sleep(for: .milliseconds(80))
                continuation.yield(2)
                continuation.finish()
            }
        }
        let relayed = StreamArrivalRelay.relay(upstream)
        // A busy consumer (the main actor during heavy layout) starts reading
        // only after both events arrived; consumption-time stamps would be ~0 apart.
        try await Task.sleep(for: .milliseconds(200))
        var stamps: [Date] = []
        var values: [Int] = []
        for try await timed in relayed {
            values.append(timed.event)
            stamps.append(timed.arrivedAt)
        }
        #expect(values == [1, 2])
        let gap = stamps[1].timeIntervalSince(stamps[0])
        #expect(gap >= 0.06)
        #expect(gap < 0.19)
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
