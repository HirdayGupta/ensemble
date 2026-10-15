import CoreGraphics
import Testing
@testable import EnsembleCore

@Suite struct HandsBusyTests {
    private let never = -Double.infinity
    private let rest = CGPoint(x: 500, y: 400)

    /// One reading with nothing but the pointer at rest, unless a field is given.
    private func read(_ s: inout HandsBusy, _ now: Double, key: Double? = nil, click: Double? = nil, scroll: Double? = nil,
                      move: Double? = nil, at p: CGPoint? = nil, ownKey: Double? = nil, ownPointer: Double? = nil,
                      ownFocus: Double? = nil) -> Bool {
        s.update(now: now, keyAt: key ?? never, clickAt: click ?? never, scrollAt: scroll ?? never, moveAt: move ?? never,
                 pointer: p ?? rest, ownKeyAt: ownKey ?? never, ownPointerAt: ownPointer ?? never, ownFocusAt: ownFocus ?? never)
    }

    /// Typing at 10.04 pauses; the reading at 12.05 resumes (the 2 s quiet time has passed).
    private func pausedThenResumed() -> HandsBusy {
        var s = HandsBusy()
        _ = read(&s, 10)
        _ = read(&s, 10.05, key: 10.04)
        _ = read(&s, 12.05, key: 10.04)
        return s
    }

    @Test func nothingTouchedNeverPauses() {
        var s = HandsBusy()
        let p1 = read(&s, 10)
        #expect(!p1)
        let p2 = read(&s, 10.05)
        #expect(!p2)
    }

    @Test func typingPausesAndResumesAfterTheQuietTime() {
        var s = HandsBusy()
        _ = read(&s, 10)
        let p3 = read(&s, 10.05, key: 10.04)
        #expect(p3)
        let p4 = read(&s, 11.9, key: 10.04)
        #expect(p4)
        let p5 = read(&s, 12.1, key: 10.04)
        #expect(!p5)
    }

    @Test func clicksAndScrollsPause() {
        var s = HandsBusy()
        let p6 = read(&s, 10, click: 9.99)
        #expect(p6)
        var t = HandsBusy()
        let p7 = t.update(now: 10, keyAt: never, clickAt: never, scrollAt: 9.98, moveAt: never, pointer: rest)
        #expect(p7)
    }

    @Test func aKeyEnsembleHeldBackOrPostedDoesNotPause() {
        var s = HandsBusy()
        // The Return that stops a dictation, read a few milliseconds after the key watch saw it.
        let p8 = read(&s, 10.05, key: 10.0, ownKey: 10.01)
        #expect(!p8)
        // A real key typed well after it does.
        let p9 = read(&s, 11.0, key: 10.95, ownKey: 10.01)
        #expect(p9)
    }

    @Test func theQuietTimeIsAdjustable() {
        var s = HandsBusy(quiet: 4)
        let p10 = read(&s, 10, key: 10)
        #expect(p10)
        let p11 = read(&s, 13.5, key: 10)
        #expect(p11)
        let p12 = read(&s, 14.1, key: 10)
        #expect(!p12)
    }

    @Test func aNudgedMouseUnderTheThresholdDoesNotPause() {
        var s = HandsBusy()
        _ = read(&s, 10)
        let p13 = read(&s, 10.05, move: 10.04, at: CGPoint(x: 502, y: 401))
        #expect(!p13)
    }

    @Test func pointerMovementPauses() {
        var s = HandsBusy()
        _ = read(&s, 10)
        let p14 = read(&s, 10.05, move: 10.04, at: CGPoint(x: 540, y: 400))
        #expect(p14)
    }

    @Test func continuousMovementKeepsItPaused() {
        var s = HandsBusy()
        _ = read(&s, 10)
        var x = 500.0
        var t = 10.0
        // Three seconds of slow, steady movement (2 pt a tick): longer than the quiet time, still paused throughout.
        while t < 13 {
            t += 0.05; x += 2
            let paused = read(&s, t, move: t - 0.01, at: CGPoint(x: x, y: 400))
            if t > 10.2 { #expect(paused) }
        }
        let p15 = read(&s, t + 1.5, move: t - 0.01, at: CGPoint(x: x, y: 400))
        #expect(p15)
        let p16 = read(&s, t + 2.1, move: t - 0.01, at: CGPoint(x: x, y: 400))
        #expect(!p16)
    }

    @Test func aPointerJumpWithoutHardwareMovementIsNotUse() {
        var s = HandsBusy()
        _ = read(&s, 10, move: 5)
        // Ensemble's own scroll moved the pointer and put it back slightly off: no hardware movement since.
        let p17 = read(&s, 10.05, move: 5, at: CGPoint(x: 900, y: 100))
        #expect(!p17)
        let p18 = read(&s, 10.1, move: 5, at: CGPoint(x: 900, y: 100))
        #expect(!p18)
    }

    @Test func movementRightAfterEnsemblesOwnScrollIsNotUse() {
        var s = HandsBusy()
        _ = read(&s, 10)
        let p19 = read(&s, 10.05, move: 10.04, at: CGPoint(x: 700, y: 400), ownPointer: 10.03)
        #expect(!p19)
        // Once that window has passed, the pointer at its new place is the new rest.
        let p20 = read(&s, 10.3, move: 10.04, at: CGPoint(x: 700, y: 400), ownPointer: 10.03)
        #expect(!p20)
    }

    @Test func inputBeforeTheFirstReadingStillCountsOnce() {
        var s = HandsBusy()
        let p21 = read(&s, 10, key: 9.5)
        #expect(p21)
        let p22 = read(&s, 11.6, key: 9.5)
        #expect(!p22)
    }

    @Test func ensemblesOwnDividerKeysAreNotTyping() {
        var own = OwnInputWindows()
        own.begin(at: 10)
        own.end(at: 10.5)
        // A key read inside the window is Ensemble's own, even if a reading ever mixed it into the hardware state.
        let ownKey = HandsBusy.ownKeyAt(keys: own, keyAt: 10.3, other: never)
        #expect(ownKey == 10.3)
        var s = HandsBusy()
        _ = read(&s, 10)
        let p23 = read(&s, 10.4, key: 10.3, ownKey: ownKey)
        #expect(!p23)
        // A key after the window is yours; the other own key still counts as before.
        #expect(HandsBusy.ownKeyAt(keys: own, keyAt: 11, other: 9) == 9)
        var t = HandsBusy()
        let p24 = read(&t, 11.1, key: 11, ownKey: HandsBusy.ownKeyAt(keys: own, keyAt: 11, other: never))
        #expect(p24)
    }

    @Test func oneStrayReadingRightAfterAResumeDoesNotPauseAgain() {
        var s = pausedThenResumed()
        let first = read(&s, 12.3, click: 12.28)
        #expect(!first)
        // The same click read again is not a second reading.
        let again = read(&s, 12.35, click: 12.28)
        #expect(!again)
        let later = read(&s, 13.5, click: 12.28)
        #expect(!later)
    }

    @Test func twoReadingsRightAfterAResumePauseAgain() {
        var s = pausedThenResumed()
        let first = read(&s, 12.3, key: 12.28)
        #expect(!first)
        let second = read(&s, 12.35, key: 12.33)
        #expect(second)
        #expect(s.lastInputKind == .key)
    }

    @Test func aSecondReadingTooLongAfterTheFirstStartsOver() {
        var s = pausedThenResumed()
        let first = read(&s, 12.2, key: 12.18)
        #expect(!first)
        // 0.7 s later: still inside the guard, but too far from the first to confirm it.
        let second = read(&s, 12.9, key: 12.88)
        #expect(!second)
        let third = read(&s, 12.95, key: 12.94)
        #expect(third)
    }

    @Test func pastTheGuardOneReadingPauses() {
        var s = pausedThenResumed()
        let p = read(&s, 13.2, key: 13.19)
        #expect(p)
    }

    @Test func oneReadingRightAfterEnsembleMovedFocusDoesNotPause() {
        var s = HandsBusy()
        _ = read(&s, 20)
        let first = read(&s, 20.1, move: 20.09, at: CGPoint(x: 540, y: 400), ownFocus: 19.9)
        #expect(!first)
        // Real use goes on: the next reading confirms it.
        let second = read(&s, 20.15, move: 20.14, at: CGPoint(x: 580, y: 400), ownFocus: 19.9)
        #expect(second)
        #expect(s.lastInputKind == .move)
    }

    @Test func thePauseNamesTheKindOfInput() {
        var s = HandsBusy()
        _ = read(&s, 10, scroll: 9.99)
        #expect(s.lastInputKind == .scroll)
        var t = HandsBusy()
        _ = read(&t, 10, click: 9.99)
        #expect(t.lastInputKind == .click)
    }
}
