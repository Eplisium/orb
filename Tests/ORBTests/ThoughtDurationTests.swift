import Foundation
import Testing

@testable import ORB

// MARK: - Chain-of-thought duration phrasing

@Suite("Thought duration formatting")
struct ThoughtDurationTests {
    @Test("Sub-minute durations render as whole seconds")
    func subMinute() {
        #expect(ThoughtDurationFormatter.duration(0.2) == "1s") // never "0s"
        #expect(ThoughtDurationFormatter.duration(8) == "8s")
        #expect(ThoughtDurationFormatter.duration(59.4) == "59s")
    }

    @Test("Minute durations render compactly")
    func minutes() {
        #expect(ThoughtDurationFormatter.duration(60) == "1m")
        #expect(ThoughtDurationFormatter.duration(72) == "1m 12s")
        #expect(ThoughtDurationFormatter.duration(600) == "10m")
        #expect(ThoughtDurationFormatter.duration(3661) == "61m 1s")
    }

    @Test("Live and finished phrasing")
    func phrasing() {
        #expect(ThoughtDurationFormatter.live(4) == "Thinking… 4s")
        #expect(ThoughtDurationFormatter.summary(11) == "Thought for 11s")
        #expect(ThoughtDurationFormatter.summary(72) == "Thought for 1m 12s")
    }
}
