import CoreGraphics
import Foundation
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
    @Test func sendNeedsTheFullHoldAndFiresOnce() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.5)
        s.hold(.thumbsUp, for: 1.2)
        #expect(s.count(.sendRequested) == 0)      // let go before 1.5 s: nothing sent
        s.hold(.openPalm, for: 0.5)
        s.hold(.thumbsUp, for: 3)
        #expect(s.count(.sendRequested) == 1)
        s.hold(.openPalm, for: 0.5)
        s.hold(.thumbsUp, for: 1.7)
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
        #expect(sent - ended >= 1.5)              // the send hold starts after the hand opened
        #expect(sent - ended < 1.7)
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
    @Test func pointingUpScrollsUpOnceHeldLongEnough() {
        let s = GestureSim()
        s.hold(.pointUp, for: 0.2)
        #expect(s.scrollTotal() == 0)
        s.hold(.pointUp, for: 1)
        #expect(s.scrollTotal() < 0)
        let first = s.log.first { if case .scroll = $0.intent { return true }; return false }
        #expect((first?.t ?? 0) - 10 >= 0.25)
    }

    @Test func pointingDownScrollsDown() {
        let s = GestureSim()
        s.hold(.pointDown, for: 1.2)
        #expect(s.scrollTotal() > 0)
    }

    @Test func scrollEmitsEveryFrameWhileHeld() {
        let s = GestureSim()
        s.hold(.pointDown, for: 1.0)
        let scrolls = s.intents.filter { if case .scroll = $0 { return true }; return false }
        // 30 frames, the first 7 (0.25 s) are the hold; the frame that completes the hold already scrolls.
        #expect(scrolls.count >= 22 && scrolls.count <= 24, "\(scrolls.count)")
    }

    @Test func speedRampsFromSlowToFast() {
        let s = GestureSim()
        s.hold(.pointDown, for: 0.25 + 0.2)
        let slow = s.scrollTotal() / 0.2
        s.hold(.pointDown, for: 1.5)
        s.log.removeAll()
        s.hold(.pointDown, for: 1.0)
        let fast = s.scrollTotal() / 1.0
        #expect(slow > 250 && slow < 450, "early speed \(slow)")
        #expect(fast > 1100 && fast < 1250, "late speed \(fast)")
    }

    @Test func totalOverFirstThreeSecondsMatchesTheRamp() {
        let s = GestureSim()
        s.hold(.pointUp, for: 3.25)
        // 3 s of scrolling: 300 -> 1200 over the first 1.5 s is 1125 points, then 1.5 s at 1200.
        let expected = 1125.0 + 1.5 * 1200
        #expect(abs(-s.scrollTotal() - expected) < 150, "scrolled \(s.scrollTotal())")
    }

    @Test func stopsImmediatelyOnPoseChange() {
        let s = GestureSim()
        s.hold(.pointUp, for: 1)
        let before = s.scrollTotal()
        s.hold(.openPalm, for: 0.5)
        s.hold(nil, for: 0.5)
        #expect(s.scrollTotal() == before)
    }

    @Test func rampRestartsAfterAnInterruption() {
        let s = GestureSim()
        s.hold(.pointDown, for: 2)
        s.hold(nil, for: 0.1)
        s.log.removeAll()
        s.hold(.pointDown, for: 0.25 + 0.2)
        #expect(s.scrollTotal() / 0.2 < 450)
    }

    @Test func handLossStopsScrolling() {
        let s = GestureSim()
        s.hold(.pointUp, for: 1)
        let before = s.scrollTotal()
        s.absent(for: 1)
        #expect(s.scrollTotal() == before)
    }

    @Test func otherPosesDoNotScroll() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.3)
        s.hold(.openPalm, for: 1, palmY: { 0.3 + 0.6 * $0 })
        s.hold(.twoFingers, for: 1, palmY: { 0.3 + 0.6 * $0 })
        #expect(s.scrollTotal() == 0)
    }

    @Test func noScrollWhileDictationIsHeld() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.3)
        s.hold(.fist, for: 1)
        #expect(s.machine.talking)
        s.hold(.pointUp, for: 0.3)   // shorter than the release hold: still talking
        #expect(s.machine.talking)
        #expect(s.scrollTotal() == 0)
    }

    @Test func thePoseThatEndedDictationDoesNotScroll() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.3)
        s.hold(.fist, for: 1)
        s.hold(.pointUp, for: 2)
        #expect(!s.machine.talking)
        #expect(s.scrollTotal() == 0)
        s.hold(nil, for: 0.1)
        s.hold(.pointUp, for: 1)
        #expect(s.scrollTotal() < 0)
    }

    @Test func scrollOffByMapping() {
        var m = GestureMapping()
        m.scrollUp = nil
        m.scrollDown = nil
        let s = GestureSim(mapping: m)
        s.hold(.pointUp, for: 1.5)
        s.hold(.pointDown, for: 1.5)
        #expect(s.scrollTotal() == 0)
    }

    @Test func eachDirectionCanBeTurnedOffSeparately() {
        var m = GestureMapping.holdFist
        m.scrollDown = nil
        let s = GestureSim(mapping: m)
        s.hold(.pointDown, for: 1.5)
        #expect(s.scrollTotal() == 0)
        s.hold(.pointUp, for: 1.5)
        #expect(s.scrollTotal() < 0)
    }

    @Test func remappedPosesScroll() {
        var m = GestureMapping()
        m.scrollUp = .twoFingers
        m.scrollDown = .thumbsUp
        m.send = nil
        let s = GestureSim(mapping: m)
        s.hold(.twoFingers, for: 1)
        #expect(s.scrollTotal() < 0)
        s.hold(nil, for: 0.1)
        s.log.removeAll()
        s.hold(.thumbsUp, for: 1)
        #expect(s.scrollTotal() > 0)
        #expect(s.count(.sendRequested) == 0)
    }

    @Test func progressBubbleFillsOverTheHoldAndIsActiveWhileScrolling() {
        let s = GestureSim()
        s.hold(.pointUp, for: 0.1)
        let early = s.machine.progress
        #expect(early?.action == .scrollUp && early?.active == false)
        #expect((early?.progress ?? 0) > 0.2 && (early?.progress ?? 1) < 0.8)
        s.hold(.pointUp, for: 0.5)
        let late = s.machine.progress
        #expect(late?.progress == 1 && late?.active == true && late?.willAct == true)
        s.hold(.pointDown, for: 0.5)
        #expect(s.machine.progress?.action == .scrollDown)
        s.hold(.openPalm, for: 0.1)
        #expect(s.machine.progress == nil)          // an open hand shows nothing
    }
}

@Suite struct GestureMappingCodingTests {
    private func decode(_ json: String) throws -> GestureMapping {
        try JSONDecoder().decode(GestureMapping.self, from: Data(json.utf8))
    }

    @Test func poseScrollIsOffByDefault() {
        let m = GestureMapping()           // pinch and drag scrolls; pose scrolling is opt-in
        #expect(m.scrollUp == nil && m.scrollDown == nil)
    }

    @Test func roundTripKeepsOffAndCustomValues() throws {
        var m = GestureMapping()
        m.scrollUp = nil
        m.scrollDown = .twoFingers
        m.send = nil
        let back = try JSONDecoder().decode(GestureMapping.self, from: JSONEncoder().encode(m))
        #expect(back == m)
        #expect(back.scrollUp == nil && back.send == nil)
    }

    @Test func legacyScrollPoseGetsTheDefaults() throws {
        let m = try decode(#"{"talk":"fist","send":"thumbsUp","scroll":"twoFingers","cancel":"openPalm"}"#)
        #expect(m.scrollUp == nil && m.scrollDown == nil && m.send == .thumbsUp && m.talk == .fist)
    }

    @Test func legacyScrollOffTurnsBothDirectionsOff() throws {
        let m = try decode(#"{"talk":"fist","send":"thumbsUp","scroll":null,"cancel":"openPalm"}"#)
        #expect(m.scrollUp == nil && m.scrollDown == nil)
        #expect(m.talk == .fist && m.send == .thumbsUp && m.cancel == .openPalm)
    }

    @Test func legacyMappingWithoutScrollKeyDecodesWithDefaults() throws {
        let m = try decode(#"{"talk":"openPalm","cancel":"fist"}"#)
        #expect(m.talk == .openPalm && m.cancel == .fist)
        #expect(m.send == .thumbsUp && m.scrollUp == nil && m.scrollDown == nil)
    }

    @Test func legacySendOffStaysOff() throws {
        let m = try decode(#"{"talk":"fist","scroll":"twoFingers","cancel":"openPalm"}"#)
        #expect(m.send == .thumbsUp)
        let off = try decode(#"{"talk":"fist","send":null,"scroll":"twoFingers","cancel":"openPalm"}"#)
        #expect(off.send == nil)
    }
}
