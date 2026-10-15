import Testing
@testable import EnsembleCore

@Suite struct TourPracticeDetectorTests {
    @Test func dictateNeedsAFullStartAndStopPair() {
        let d = TourPracticeDetector()
        #expect(d.observe(.talkBegan) == nil)
        #expect(d.observe(.talkEnded(.released)) == .dictate)
    }

    @Test func talkEndedAloneDoesNotCompleteDictate() {
        let d = TourPracticeDetector()
        #expect(d.observe(.talkEnded(.stale)) == nil)
    }

    @Test func resetDiscardsAPendingTalkBegan() {
        let d = TourPracticeDetector()
        #expect(d.observe(.talkBegan) == nil)
        d.reset()
        #expect(d.observe(.talkEnded(.released)) == nil)
    }

    @Test func sendAndScrollCompleteOnTheirOwnIntent() {
        let d = TourPracticeDetector()
        #expect(d.observe(.sendRequested) == .send)
        #expect(d.observe(.dragScroll(handDy: 12)) == .scroll)
    }

    @Test func unrelatedIntentsCompleteNothing() {
        let d = TourPracticeDetector()
        #expect(d.observe(.cancelRequested) == nil)
        #expect(d.observe(.scroll(dy: 5)) == nil)
        #expect(d.observe(.dragScrollEnded) == nil)
    }

    @Test func dictateCanBePracticedAgainAfterCompleting() {
        let d = TourPracticeDetector()
        #expect(d.observe(.talkBegan) == nil)
        #expect(d.observe(.talkEnded(.released)) == .dictate)
        #expect(d.observe(.talkBegan) == nil)
        #expect(d.observe(.talkEnded(.released)) == .dictate)
    }
}

@Suite struct TourLookDetectorTests {
    @Test func smallJitterAroundCentreNeverCompletes() {
        let d = TourLookDetector()
        for yaw in [0.0, 0.02, -0.03, 0.05, -0.04, 0.01] {
            #expect(!d.observe(yaw: yaw))
        }
        #expect(!d.done)
    }

    @Test func turningAwayAndBackCompletesOnce() {
        let d = TourLookDetector()
        #expect(!d.observe(yaw: 0.05))
        #expect(!d.observe(yaw: 0.3))     // turned away
        #expect(!d.observe(yaw: 0.25))    // still away
        #expect(d.observe(yaw: 0.02))     // back near centre: done
        #expect(d.done)
        #expect(!d.observe(yaw: 0.3))     // already done; further motion reports nothing new
    }

    @Test func negativeYawCountsTheSameAsPositive() {
        let d = TourLookDetector()
        #expect(!d.observe(yaw: -0.3))
        #expect(d.observe(yaw: -0.02))
        #expect(d.done)
    }

    @Test func resetAllowsPracticingAgain() {
        let d = TourLookDetector()
        _ = d.observe(yaw: 0.3)
        _ = d.observe(yaw: 0.0)
        #expect(d.done)
        d.reset()
        #expect(!d.done)
        #expect(!d.observe(yaw: 0.0))
    }
}
