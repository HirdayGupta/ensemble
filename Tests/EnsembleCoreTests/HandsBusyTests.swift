import CoreGraphics
import Testing
@testable import EnsembleCore

@Suite struct HandsBusyTests {
    private let never = -Double.infinity
    private let rest = CGPoint(x: 500, y: 400)

    /// One reading with nothing but the pointer at rest, unless a field is given.
    private func read(_ s: inout HandsBusy, _ now: Double, key: Double? = nil, click: Double? = nil, scroll: Double? = nil,
                      move: Double? = nil, at p: CGPoint? = nil, ownKey: Double? = nil, ownPointer: Double? = nil) -> Bool {
        s.update(now: now, keyAt: key ?? never, clickAt: click ?? never, scrollAt: scroll ?? never, moveAt: move ?? never,
                 pointer: p ?? rest, ownKeyAt: ownKey ?? never, ownPointerAt: ownPointer ?? never)
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

    @Test func aHardwareKeyDuringAResizeIsTypingAndPauses() {
        // The hardware key state never holds the divider keys Ensemble posts, so a key it reports while a resize
        // runs is the owner's own hand: only a held-back Return or play/pause key is passed as Ensemble's own.
        var s = HandsBusy()
        _ = read(&s, 10)
        let p23 = read(&s, 10.4, key: 10.3, ownKey: never)
        #expect(p23)
        var t = HandsBusy()
        _ = read(&t, 10)
        let p24 = read(&t, 10.4, key: 10.3, ownKey: 10.3)
        #expect(!p24)
    }
}
