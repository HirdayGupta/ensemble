import CoreGraphics
import Testing
@testable import ClutchCore

@Suite struct GestureMachineTalkTests {
    @Test func openToFistHoldBeginsTalkOnce() throws {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.5)
        let fistStart = s.t
        s.hold(.fist, for: 5)
        #expect(s.count(.talkBegan) == 1)
        #expect(s.machine.talking)
        let began = try #require(s.firstTime(of: .talkBegan))
        #expect(began - fistStart >= 0.3 && began - fistStart < 0.4)
    }

    @Test func shortFistDoesNotBegin() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.5)
        s.hold(.fist, for: 0.25)
        s.hold(.openPalm, for: 0.5)
        #expect(s.count(.talkBegan) == 0)
    }

    @Test func fistThatInterruptsResetsTheHold() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.5)
        s.hold(.fist, for: 0.2)
        s.hold(nil, for: 0.1)
        s.hold(.fist, for: 0.2)
        #expect(s.count(.talkBegan) == 0)
    }

    @Test func handArrivingAlreadyClosedDoesNotBegin() {
        let s = GestureSim()
        s.absent(for: 2)
        s.hold(.fist, for: 3)
        #expect(s.count(.talkBegan) == 0)
        #expect(!s.machine.talking)
    }

    @Test func openHandSeenLongAgoDoesNotArm() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.5)
        s.absent(for: 2)
        s.hold(.fist, for: 1)
        #expect(s.count(.talkBegan) == 0)
    }

    @Test func openHandSeenWithinWindowArms() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.5)
        s.absent(for: 0.9)
        s.hold(.fist, for: 1)
        #expect(s.count(.talkBegan) == 1)
    }

    @Test func unclassifiedHandCountsAsDifferentState() {
        let s = GestureSim()
        s.hold(nil, for: 0.4)
        s.hold(.fist, for: 1)
        #expect(s.count(.talkBegan) == 1)
    }

    @Test func releaseEndsTalkAfterPointFourSeconds() throws {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.3)
        s.hold(.fist, for: 1)
        let releaseStart = s.t
        s.hold(.openPalm, for: 1)
        #expect(s.intents.last == .talkEnded(.released))
        let ended = try #require(s.firstTime(of: .talkEnded(.released)))
        #expect(ended - releaseStart >= 0.4 && ended - releaseStart < 0.5)
        #expect(!s.machine.talking)
    }

    @Test func briefFlickerDoesNotEndTalk() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.3)
        s.hold(.fist, for: 1)
        s.hold(nil, for: 0.3)
        s.hold(.fist, for: 1)
        s.hold(.openPalm, for: 0.3)
        s.hold(.fist, for: 1)
        #expect(s.machine.talking)
        #expect(s.count(.talkEnded(.released)) == 0)
    }

    @Test func otherPoseAlsoReleases() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.3)
        s.hold(.fist, for: 1)
        s.hold(.twoFingers, for: 0.6)
        #expect(s.count(.talkEnded(.released)) == 1)
    }

    @Test func handLostEndsTalkAfterPointSixSeconds() throws {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.3)
        s.hold(.fist, for: 1)
        let lostStart = s.t
        s.absent(for: 1)
        let ended = try #require(s.firstTime(of: .talkEnded(.handLost)))
        #expect(ended - lostStart >= 0.6 && ended - lostStart < 0.7)
        #expect(!s.machine.talking)
    }

    @Test func shortHandLossKeepsTalking() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.3)
        s.hold(.fist, for: 1)
        s.absent(for: 0.5)
        s.hold(.fist, for: 1)
        #expect(s.machine.talking)
        #expect(s.count(.talkEnded(.handLost)) == 0)
    }

    @Test func staleCameraEndsTalkOnTick() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.3)
        s.hold(.fist, for: 1)
        s.tick(after: 0.9)
        #expect(s.machine.talking)
        s.tick(after: 1.0)
        #expect(s.intents.last == .talkEnded(.stale))
        #expect(!s.machine.talking)
        s.tick(after: 5)
        #expect(s.count(.talkEnded(.stale)) == 1)
    }

    @Test func tickIsSilentWhenNotTalking() {
        let s = GestureSim()
        s.hold(.openPalm, for: 1)
        let before = s.log.count
        s.tick(after: 10)
        #expect(s.log.count == before)
    }

    @Test func canTalkAgainAfterRelease() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.3)
        s.hold(.fist, for: 1)
        s.hold(.openPalm, for: 0.6)
        s.hold(.fist, for: 1)
        #expect(s.count(.talkBegan) == 2)
        #expect(s.count(.talkEnded(.released)) == 1)
    }

    @Test func resetClearsTalking() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.3)
        s.hold(.fist, for: 1)
        s.machine.reset()
        #expect(!s.machine.talking)
        s.tick(after: 5)
        #expect(s.count(.talkEnded(.stale)) == 0)
    }

    @Test func customTalkPose() {
        var m = GestureMapping()
        m.talk = .thumbsUp
        m.send = nil
        let s = GestureSim(mapping: m)
        s.hold(.openPalm, for: 0.3)
        s.hold(.thumbsUp, for: 1)
        #expect(s.count(.talkBegan) == 1)
        #expect(s.count(.sendRequested) == 0)
    }
}

@Suite struct GestureMachineSendCancelTests {
    @Test func sendNeedsPointThreeSecondsAndFiresOnce() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.5)
        s.hold(.thumbsUp, for: 0.2)
        #expect(s.count(.sendRequested) == 0)
        s.hold(.thumbsUp, for: 3)
        #expect(s.count(.sendRequested) == 1)
        s.hold(.openPalm, for: 0.5)
        s.hold(.thumbsUp, for: 1)
        #expect(s.count(.sendRequested) == 2)
    }

    @Test func sendOffByMapping() {
        var m = GestureMapping()
        m.send = nil
        let s = GestureSim(mapping: m)
        s.hold(.openPalm, for: 0.5)
        s.hold(.thumbsUp, for: 2)
        #expect(s.count(.sendRequested) == 0)
    }

    @Test func fistStraightToThumbsUpStopsThenSendsOnce() throws {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.3)
        s.hold(.fist, for: 1)
        s.hold(.thumbsUp, for: 4)
        #expect(s.count(.talkEnded(.released)) == 1)
        #expect(s.count(.sendRequested) == 1)
        let ended = try #require(s.firstTime(of: .talkEnded(.released)))
        let sent = try #require(s.firstTime(of: .sendRequested))
        #expect(sent >= ended)
    }

    @Test func openPalmEndingAHoldNeverSends() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.3)
        s.hold(.fist, for: 1)
        s.hold(.openPalm, for: 4)
        #expect(s.count(.talkEnded(.released)) == 1)
        #expect(s.count(.sendRequested) == 0)
    }

    @Test func sendWaitsHalfSecondAfterTalkEnded() throws {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.3)
        s.hold(.fist, for: 1)
        s.hold(.openPalm, for: 0.47)          // ends the hold at about 0.4 s
        let ended = try #require(s.firstTime(of: .talkEnded(.released)))
        s.hold(.thumbsUp, for: 2)
        let sent = try #require(s.firstTime(of: .sendRequested))
        #expect(sent - ended >= 0.5)
        #expect(sent - ended < 0.6)
    }

    @Test func sendNotWhileTalking() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.3)
        s.hold(.fist, for: 1)
        s.hold(.thumbsUp, for: 0.3)
        s.hold(.fist, for: 0.5)
        #expect(s.machine.talking)
        #expect(s.count(.sendRequested) == 0)
    }

    @Test func cancelNeedsPointThreeSecondsAndFiresOnce() {
        let s = GestureSim()
        s.hold(.thumbsUp, for: 0.2)
        s.hold(.openPalm, for: 0.2)
        #expect(s.count(.cancelRequested) == 0)
        s.hold(.openPalm, for: 3)
        #expect(s.count(.cancelRequested) == 1)
    }

    @Test func openHandThatReleasesTalkDoesNotCancel() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.3)
        s.hold(.fist, for: 1)
        s.hold(.openPalm, for: 3)
        #expect(s.count(.talkEnded(.released)) == 1)
        #expect(s.count(.cancelRequested) == 0)
    }

    @Test func noCancelWhileTalking() {
        let s = GestureSim()
        s.hold(.thumbsUp, for: 0.3)
        s.hold(.fist, for: 1)
        s.hold(.openPalm, for: 0.35)
        #expect(s.machine.talking)
        #expect(s.count(.cancelRequested) == 0)
    }
}

@Suite struct GestureMachineScrollTests {
    @Test func briskUpwardMotionScrollsAboutAPage() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.3)
        // Settle in the scroll pose, then move up 0.3 frame heights in 0.5 s.
        s.hold(.twoFingers, for: 0.4, palmY: { _ in 0.3 })
        s.hold(.twoFingers, for: 0.5, palmY: { 0.3 + 0.6 * $0 })
        s.hold(.twoFingers, for: 0.3, palmY: { _ in 0.6 })
        let total = s.scrollTotal()
        #expect(total > 450 && total < 750, "scrolled \(total)")
    }

    @Test func downwardMotionScrollsTheOtherWay() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.3)
        s.hold(.twoFingers, for: 0.4, palmY: { _ in 0.7 })
        s.hold(.twoFingers, for: 0.5, palmY: { 0.7 - 0.6 * $0 })
        s.hold(.twoFingers, for: 0.3, palmY: { _ in 0.4 })
        #expect(s.scrollTotal() < -450)
    }

    @Test func holdingStillOrJitteringDoesNotScroll() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.3)
        s.hold(.twoFingers, for: 4, palmY: { 0.5 + 0.002 * sin($0 * 40) })
        #expect(s.scrollTotal() == 0)
    }

    @Test func motionBeforeTheHoldElapsesDoesNotScroll() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.3)
        s.hold(.twoFingers, for: 0.15, palmY: { 0.3 + 2 * $0 })
        #expect(s.scrollTotal() == 0)
    }

    @Test func otherPosesDoNotScroll() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.3)
        s.hold(.openPalm, for: 1, palmY: { 0.3 + 0.6 * $0 })
        #expect(s.scrollTotal() == 0)
    }

    @Test func noScrollWhileTalking() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.3)
        s.hold(.fist, for: 1)
        s.hold(.twoFingers, for: 0.3, palmY: { 0.3 + 0.6 * $0 })
        #expect(s.machine.talking)
        #expect(s.scrollTotal() == 0)
    }

    @Test func scrollOffByMapping() {
        var m = GestureMapping()
        m.scroll = nil
        let s = GestureSim(mapping: m)
        s.hold(.twoFingers, for: 1.5, palmY: { 0.3 + 0.3 * $0 })
        #expect(s.scrollTotal() == 0)
    }
}
