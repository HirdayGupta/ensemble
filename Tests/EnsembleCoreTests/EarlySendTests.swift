import Testing
@testable import EnsembleCore

/// A thumbs-up while dictating as one motion: stop and settle during the hold, press when it completes.
@Suite struct EarlySendTests {
    @Test func everyStepBeforeTheHoldEndsPressesTheMomentItEnds() {
        var e = EarlySend()
        e.arm(at: 0)
        #expect(e.stopWasConfirmed(at: 0.15) == .wait)
        #expect(e.draftSettled(at: 0.6) == .wait)
        #expect(e.holdWasCompleted(at: 0.75) == .press)
        #expect(e.timeline() == "thumbs-up recognised, stopping +0 ms, stop confirmed +150 ms, draft stable +600 ms, hold complete +750 ms, send pressing +750 ms")
    }

    @Test func aDraftStillSettlingWhenTheHoldEndsPressesOnceItIsStable() {
        var e = EarlySend()
        e.arm(at: 0)
        _ = e.stopWasConfirmed(at: 0.2)
        #expect(e.holdWasCompleted(at: 0.75) == .wait)
        #expect(e.draftSettled(at: 0.9) == .press)
    }

    @Test func theDraftNeverCountsAsSettledBeforeTheStopIsConfirmed() {
        var e = EarlySend()
        e.arm(at: 0)
        #expect(e.draftSettled(at: 0.1) == .wait)
        #expect(!e.draftStable)
        #expect(e.holdWasCompleted(at: 0.75) == .wait)
        _ = e.stopWasConfirmed(at: 0.8)
        #expect(e.draftSettled(at: 1.1) == .press)
    }

    @Test func nothingIsPressedBeforeTheHoldCompletes() {
        var e = EarlySend()
        e.arm(at: 0)
        _ = e.stopWasConfirmed(at: 0.1)
        #expect(e.draftSettled(at: 0.5) == .wait)
        for t in stride(from: 0.5, to: 0.75, by: 0.05) { #expect(e.observe(holding: true, at: t) == .wait) }
    }

    @Test func aHandThatDropsBeforeTheHoldKeepsTheTextUnsent() {
        var e = EarlySend()
        e.arm(at: 0)
        _ = e.stopWasConfirmed(at: 0.1)
        #expect(e.observe(holding: false, at: 0.4) == .wait)
        #expect(e.observe(holding: false, at: 0.69) == .wait)
        #expect(e.observe(holding: false, at: 0.71) == .keptNotSent)
        #expect(!e.isArmed)
        #expect(e.draftSettled(at: 0.8) == .wait)
        #expect(e.holdWasCompleted(at: 0.9) == .wait)
    }

    @Test func aPoseLostForAFrameIsNotADrop() {
        var e = EarlySend()
        e.arm(at: 0)
        #expect(e.observe(holding: false, at: 0.2) == .wait)
        #expect(e.observe(holding: true, at: 0.25) == .wait)
        #expect(e.observe(holding: false, at: 0.5) == .wait)
        #expect(e.observe(holding: false, at: 0.79) == .wait)
        #expect(e.isArmed)
    }

    @Test func theHandMayDropOnceTheHoldCompleted() {
        var e = EarlySend()
        e.arm(at: 0)
        _ = e.holdWasCompleted(at: 0.75)
        #expect(e.observe(holding: false, at: 2) == .wait)
        _ = e.stopWasConfirmed(at: 2.1)
        #expect(e.draftSettled(at: 2.4) == .press)
    }

    @Test func anUnconfirmedStopSendsNothing() {
        var e = EarlySend()
        e.arm(at: 0)
        _ = e.holdWasCompleted(at: 0.75)
        #expect(e.stopFailed() == .dropped)
        #expect(e.draftSettled(at: 1) == .wait)
        #expect(!e.isArmed)
    }

    @Test func droppingForgetsEverything() {
        var e = EarlySend()
        e.arm(at: 0)
        _ = e.stopWasConfirmed(at: 0.1)
        e.drop()
        #expect(!e.isArmed)
        #expect(e.holdWasCompleted(at: 0.75) == .wait)
        #expect(e.draftSettled(at: 0.8) == .wait)
    }
}

@Suite struct SendRearmTests {
    @Test func aThumbsUpThatFlickersAfterTheSendDoesNotStartASecondHold() {
        let s = GestureSim()
        s.hold(.openPalm, for: 0.5)
        s.hold(.thumbsUp, for: 2)
        #expect(s.count(.sendRequested) == 1)
        s.hold(.openPalm, for: 1.0 / 30)           // one misread frame
        s.hold(.thumbsUp, for: 3)
        #expect(s.count(.sendRequested) == 1)
        #expect(s.machine.progress?.willAct == false)   // no bar filling again
        s.hold(.openPalm, for: 0.5)
        s.hold(.thumbsUp, for: 2)
        #expect(s.count(.sendRequested) == 2)       // a real new thumbs-up still sends
    }

    @Test func theThumbsUpThatStoppedADictationReportsItsHold() {
        let s = GestureSim()
        s.toggleTalk()
        s.hold(.thumbsUp, for: 0.5)
        #expect(!s.machine.talking)
        #expect(s.machine.holdingSendAfterStop)
        s.hold(.thumbsUp, for: 1.5)
        #expect(s.count(.sendRequested) == 1)
        #expect(!s.machine.holdingSendAfterStop)    // fired
    }
}
