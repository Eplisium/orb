import Foundation
import Testing
@testable import ORB

@Suite("Message auto-follow intent")
struct MessageScrollIntentTests {
    @Test("large response growth never looks like a user scroll")
    func growthIsNotManualScroll() {
        var intent = MessageScrollIntent()
        let baseline = intent.observe(top: -400, contentHeight: 1000, viewportHeight: 600, threshold: 200)
        #expect(!baseline)
        // A 500-point code panel grows below the content origin.
        let afterGrowth = intent.observe(top: -400, contentHeight: 1500, viewportHeight: 600, threshold: 200)
        #expect(!afterGrowth)
        #expect(intent.upwardDistance == 0)
    }

    @Test("collapsing a reasoning panel while pinned to bottom is not a wheel gesture")
    func layoutShrinkDoesNotUnfollow() {
        var intent = MessageScrollIntent()
        let baseline = intent.observe(top: -400, contentHeight: 1000, viewportHeight: 600, threshold: 200)
        #expect(!baseline)
        // A 240-point disclosure collapses when the first answer arrives;
        // NSScrollView clamps to the new bottom, moving the origin down.
        let collapsed = intent.observe(top: -160, contentHeight: 760, viewportHeight: 600, threshold: 200)
        #expect(!collapsed)
        #expect(intent.upwardDistance == 0)
        let userScroll = intent.observe(top: -112, contentHeight: 760, viewportHeight: 600, threshold: 200)
        #expect(!userScroll)
        #expect(intent.upwardDistance == 48)
    }

    @Test("a taller viewport does not look like a scroll when pinned to bottom")
    func viewportGrowthDoesNotUnfollow() {
        var intent = MessageScrollIntent()
        _ = intent.observe(top: -400, contentHeight: 1000, viewportHeight: 600, threshold: 200)
        let resized = intent.observe(top: -160, contentHeight: 1000, viewportHeight: 840, threshold: 200)
        #expect(!resized)
        #expect(intent.upwardDistance == 0)
    }

    @Test("bottom corrections between wheel ticks do not erase upward intent")
    func interleavedFollowCorrections() {
        var intent = MessageScrollIntent()
        let baseline = intent.observe(top: -400, contentHeight: 1000, viewportHeight: 600, threshold: 200)
        #expect(!baseline)
        for _ in 1...4 {
            // A streaming follow-scroll can move the origin back down
            // between two small manual upward wheel ticks.
            let up = intent.observe(top: -352, contentHeight: 1000, viewportHeight: 600, threshold: 200)
            #expect(!up)
            let correction = intent.observe(top: -400, contentHeight: 1000, viewportHeight: 600, threshold: 200)
            #expect(!correction)
        }
        let disengaged = intent.observe(top: -352, contentHeight: 1000, viewportHeight: 600, threshold: 200)
        #expect(disengaged)
    }

    @Test("small upward gestures accumulate across downward movement")
    func upwardScroll() {
        var intent = MessageScrollIntent()
        let baseline = intent.observe(top: -400, contentHeight: 1000, viewportHeight: 600, threshold: 200)
        #expect(!baseline)
        for step in 1...4 {
            let disengaged = intent.observe(top: CGFloat(-400 + step * 40), contentHeight: 1000, viewportHeight: 600, threshold: 200)
            #expect(!disengaged)
        }
        let disengaged = intent.observe(top: -180, contentHeight: 1000, viewportHeight: 600, threshold: 200)
        #expect(disengaged)
        let downward = intent.observe(top: -200, contentHeight: 1000, viewportHeight: 600, threshold: 200)
        #expect(downward)
        intent.reset()
        let afterReset = intent.observe(top: 0, contentHeight: 1000, viewportHeight: 600, threshold: 200)
        #expect(!afterReset)
    }
}
