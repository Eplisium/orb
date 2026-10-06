import Foundation

/// A stream event paired with the wall-clock instant it left the network
/// layer, sampled off the main actor.
struct TimedStreamEvent<Event: Sendable>: Sendable {
    let event: Event
    let arrivedAt: Date
}

/// Re-yields a stream's events stamped with their arrival time.
///
/// Chat consumes its SSE stream on the main actor. When the main actor is
/// busy (a long Markdown layout, a SQLite checkpoint, or — in tests — dozens
/// of `@MainActor` suites), events queue up and are then drained back to
/// back. Sampling `Date()` at consumption time collapsed a real 80ms
/// reasoning phase into a few milliseconds. The relay task is detached, so
/// the timestamp records when the provider actually sent the token.
enum StreamArrivalRelay {
    static func relay<Event: Sendable>(
        _ upstream: AsyncThrowingStream<Event, Error>
    ) -> AsyncThrowingStream<TimedStreamEvent<Event>, Error> {
        AsyncThrowingStream { continuation in
            // High priority: under a saturated cooperative pool a default-
            // priority relay ran *after* higher-priority producer jobs, so two
            // events 80ms apart were stamped together. The relay does no work
            // beyond stamping and forwarding.
            let task = Task.detached(priority: .userInitiated) {
                do {
                    for try await event in upstream {
                        continuation.yield(.init(event: event, arrivedAt: Date()))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A client that can stamp events where they are produced (e.g. on its own
/// network/delegate queue), which is more faithful than the relay's
/// consumer-side stamp when the cooperative pool itself is saturated.
protocol TimedOpenRouterStreaming: OpenRouterClientProtocol {
    func timedStream(_ request: OpenRouterRequest) async throws
        -> AsyncThrowingStream<TimedStreamEvent<OpenRouterStreamEvent>, Error>
}

extension StreamArrivalRelay {
    /// Arrival-stamped events for any client: producer stamps when the client
    /// supports them, otherwise the detached relay.
    static func stream(
        _ client: any OpenRouterClientProtocol, _ request: OpenRouterRequest
    ) async throws -> AsyncThrowingStream<TimedStreamEvent<OpenRouterStreamEvent>, Error> {
        if let timed = client as? any TimedOpenRouterStreaming {
            return try await timed.timedStream(request)
        }
        return relay(try await client.stream(request))
    }
}
