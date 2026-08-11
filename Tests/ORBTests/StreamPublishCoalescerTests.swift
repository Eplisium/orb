import Foundation
import Testing
@testable import ORB

@Suite("Stream publish coalescing")
@MainActor
struct StreamPublishCoalescerTests {
    @Test("a pending delta publishes at the trailing frame deadline")
    func trailingDeadlinePublishesLatestValue() async throws {
        var published: [String] = []
        let coalescer = StreamPublishCoalescer<String>(
            interval: .milliseconds(30),
            characterBackstop: 512
        ) { published.append($0) }

        coalescer.submit("a", addedCharacters: 1)
        coalescer.submit("ab", addedCharacters: 1)

        #expect(published == ["a"])
        try await Task.sleep(for: .milliseconds(60))
        #expect(published == ["a", "ab"])
    }
}
