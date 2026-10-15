import Testing
@testable import EnsembleCore

@Suite struct ReturnKeysTests {
    private func ret(_ keys: inout ReturnKeys, at t: Double, dictating: Bool = true, claude: Bool = true,
                     modified: Bool = false, repeat isRepeat: Bool = false) -> ReturnKeys.Decision {
        keys.press(isReturn: true, modified: modified, isRepeat: isRepeat, claudeInFront: claude, dictating: dictating, now: t)
    }

    @Test func notDictatingPassesReturn() {
        var keys = ReturnKeys()
        #expect(ret(&keys, at: 1, dictating: false) == .pass)
        #expect(ret(&keys, at: 1.1, dictating: false) == .pass)
    }

    @Test func anotherAppInFrontPassesReturn() {
        var keys = ReturnKeys()
        #expect(ret(&keys, at: 1, claude: false) == .pass)
        #expect(!keys.awaitingStop)
    }

    @Test func modifiedReturnPasses() {
        var keys = ReturnKeys()
        #expect(ret(&keys, at: 1, modified: true) == .pass)
        #expect(!keys.awaitingStop)
    }

    @Test func otherKeysPassAndAreNoted() {
        var keys = ReturnKeys()
        #expect(keys.press(isReturn: false, modified: false, isRepeat: false, claudeInFront: true, dictating: true, now: 3) == .pass)
        #expect(keys.lastOtherKeyAt == 3)
        // Not dictating and nothing pending: the key is not this watch's business.
        var idle = ReturnKeys()
        #expect(idle.press(isReturn: false, modified: false, isRepeat: false, claudeInFront: true, dictating: false, now: 3) == .pass)
        #expect(idle.lastOtherKeyAt == -.infinity)
    }

    @Test func firstReturnWhileDictatingStops() {
        var keys = ReturnKeys()
        #expect(ret(&keys, at: 1) == .swallowAndStop)
        #expect(keys.awaitingStop)
    }

    @Test func secondReturnAfterTheStopPassesToClaude() {
        var keys = ReturnKeys()
        #expect(ret(&keys, at: 1) == .swallowAndStop)
        keys.stopConfirmed(now: 1.8)
        #expect(!keys.awaitingStop)
        #expect(ret(&keys, at: 3, dictating: false) == .pass)
        // And the one after that too: nothing pending.
        #expect(ret(&keys, at: 3.2, dictating: false) == .pass)
    }

    @Test func doubleReturnWhileTalkingSendsAfterTheStop() {
        var keys = ReturnKeys()
        #expect(ret(&keys, at: 1) == .swallowAndStop)
        #expect(ret(&keys, at: 1.3) == .swallowAndSendAfterStop)
        // A third press while the stop is in flight is kept from Claude and asks for nothing more.
        #expect(ret(&keys, at: 1.4) == .swallow)
        keys.stopConfirmed(now: 1.9)
        #expect(!keys.awaitingStop)
    }

    @Test func secondReturnWhileTheStopIsStillInFlightSendsAfterIt() {
        var keys = ReturnKeys()
        #expect(ret(&keys, at: 1) == .swallowAndStop)
        #expect(ret(&keys, at: 1.9) == .swallowAndSendAfterStop)
    }

    @Test func secondReturnInsideTheWindowAfterAQuickStopSends() {
        var keys = ReturnKeys()
        #expect(ret(&keys, at: 1) == .swallowAndStop)
        keys.stopConfirmed(now: 1.3)
        #expect(keys.inDoubleWindow(now: 1.4))
        #expect(ret(&keys, at: 1.45, dictating: false) == .swallowAndSend)
        #expect(ret(&keys, at: 1.48, dictating: false) == .pass)
    }

    @Test func theDoubleWindowCloses() {
        var keys = ReturnKeys()
        #expect(ret(&keys, at: 1) == .swallowAndStop)
        keys.stopConfirmed(now: 1.3)
        #expect(!keys.inDoubleWindow(now: 1.6))
        #expect(ret(&keys, at: 1.6, dictating: false) == .pass)
    }

    @Test func failedStopDropsTheSend() {
        var keys = ReturnKeys()
        #expect(ret(&keys, at: 1) == .swallowAndStop)
        #expect(ret(&keys, at: 1.2) == .swallowAndSendAfterStop)
        let dropped = keys.stopFailed()
        #expect(dropped)
        #expect(!keys.awaitingStop)
        var single = ReturnKeys()
        #expect(ret(&single, at: 1) == .swallowAndStop)
        let singleDropped = single.stopFailed()
        #expect(!singleDropped)
    }

    @Test func aStopThatNeverResolvesIsGivenUp() {
        var keys = ReturnKeys()
        #expect(ret(&keys, at: 1) == .swallowAndStop)
        #expect(ret(&keys, at: 1.2) == .swallowAndSendAfterStop)
        let early = keys.expire(now: 5.9)
        #expect(!early)
        let late = keys.expire(now: 6.1)
        #expect(late)
        #expect(!keys.awaitingStop)
        #expect(ret(&keys, at: 7, dictating: false) == .pass)
    }

    @Test func heldReturnRepeatsAreNotASecondPress() {
        var keys = ReturnKeys()
        #expect(ret(&keys, at: 1) == .swallowAndStop)
        #expect(ret(&keys, at: 1.3, repeat: true) == .swallow)
        keys.stopConfirmed(now: 2)
        #expect(!keys.awaitingStop)
        // A repeat already running when a dictation starts does not stop it.
        var fresh = ReturnKeys()
        #expect(ret(&fresh, at: 1, repeat: true) == .pass)
    }

    @Test func returnSendIgnoresOnlyTheReturns() {
        #expect(ReturnKeys.inputAge(clickAge: 50, lastOtherKeyAt: -.infinity, now: 10) == 50)
        #expect(ReturnKeys.inputAge(clickAge: 50, lastOtherKeyAt: 9, now: 10) == 1)
        #expect(ReturnKeys.inputAge(clickAge: 0.2, lastOtherKeyAt: -.infinity, now: 10) == 0.2)
        // Keys gone by unseen count as typing just now.
        var keys = ReturnKeys()
        keys.noteUnseenKeys(now: 8)
        #expect(keys.lastOtherKeyAt == 8)
    }

    @Test func messageBoxFocusOnlyWithClaudeInFront() {
        #expect(ReturnKeys.focusComposerAfterStart(claudeInFront: true, composerFocused: false))
        #expect(ReturnKeys.focusComposerAfterStart(claudeInFront: true, composerFocused: nil))
        #expect(!ReturnKeys.focusComposerAfterStart(claudeInFront: true, composerFocused: true))
        #expect(!ReturnKeys.focusComposerAfterStart(claudeInFront: false, composerFocused: false))
    }
}
