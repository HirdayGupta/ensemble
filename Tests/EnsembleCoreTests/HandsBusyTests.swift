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
        #expect(!read(&s, 10))
        #expect(!read(&s, 10.05))
    }

    @Test func typingPausesAndResumesAfterTheQuietTime() {
        var s = HandsBusy()
        _ = read(&s, 10)
        #expect(read(&s, 10.05, key: 10.04))
        #expect(read(&s, 11.9, key: 10.04))
        #expect(!read(&s, 12.1, key: 10.04))
    }

    @Test func clicksAndScrollsPause() {
        var s = HandsBusy()
        #expect(read(&s, 10, click: 9.99))
        var t = HandsBusy()
        #expect(t.update(now: 10, keyAt: never, clickAt: never, scrollAt: 9.98, moveAt: never, pointer: rest))
    }

    @Test func aKeyEnsembleHeldBackOrPostedDoesNotPause() {
        var s = HandsBusy()
        // The Return that stops a dictation, read a few milliseconds after the key watch saw it.
        #expect(!read(&s, 10.05, key: 10.0, ownKey: 10.01))
        // A real key typed well after it does.
        #expect(read(&s, 11.0, key: 10.95, ownKey: 10.01))
    }

    @Test func theQuietTimeIsAdjustable() {
        var s = HandsBusy(quiet: 4)
        #expect(read(&s, 10, key: 10))
        #expect(read(&s, 13.5, key: 10))
        #expect(!read(&s, 14.1, key: 10))
    }

    @Test func aNudgedMouseUnderTheThresholdDoesNotPause() {
        var s = HandsBusy()
        _ = read(&s, 10)
        #expect(!read(&s, 10.05, move: 10.04, at: CGPoint(x: 502, y: 401)))
    }

    @Test func pointerMovementPauses() {
        var s = HandsBusy()
        _ = read(&s, 10)
        #expect(read(&s, 10.05, move: 10.04, at: CGPoint(x: 540, y: 400)))
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
        #expect(read(&s, t + 1.5, move: t - 0.01, at: CGPoint(x: x, y: 400)))
        #expect(!read(&s, t + 2.1, move: t - 0.01, at: CGPoint(x: x, y: 400)))
    }

    @Test func aPointerJumpWithoutHardwareMovementIsNotUse() {
        var s = HandsBusy()
        _ = read(&s, 10, move: 5)
        // Ensemble's own scroll moved the pointer and put it back slightly off: no hardware movement since.
        #expect(!read(&s, 10.05, move: 5, at: CGPoint(x: 900, y: 100)))
        #expect(!read(&s, 10.1, move: 5, at: CGPoint(x: 900, y: 100)))
    }

    @Test func movementRightAfterEnsemblesOwnScrollIsNotUse() {
        var s = HandsBusy()
        _ = read(&s, 10)
        #expect(!read(&s, 10.05, move: 10.04, at: CGPoint(x: 700, y: 400), ownPointer: 10.03))
        // Once that window has passed, the pointer at its new place is the new rest.
        #expect(!read(&s, 10.3, move: 10.04, at: CGPoint(x: 700, y: 400), ownPointer: 10.03))
    }

    @Test func inputBeforeTheFirstReadingStillCountsOnce() {
        var s = HandsBusy()
        #expect(read(&s, 10, key: 9.5))
        #expect(!read(&s, 11.6, key: 9.5))
    }
}
