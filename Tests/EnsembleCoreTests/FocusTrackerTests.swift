import CoreGraphics
import Testing
@testable import EnsembleCore

@Suite struct FocusTrackerTests {
    private let left = ClaudeSession(id: "L", frame: CGRect(x: 0, y: 0, width: 500, height: 500), windowNumber: 1)
    private let right = ClaudeSession(id: "R", frame: CGRect(x: 500, y: 0, width: 500, height: 500), windowNumber: 2)

    @Test func theFrontSessionUnderTheNoseIsChosen() {
        let s = FocusTracker.session(at: CGPoint(x: 700, y: 250), in: [left, right], current: nil) { _ in true }
        #expect(s?.id == "R")
        #expect(FocusTracker.session(at: CGPoint(x: 700, y: 900), in: [left, right], current: nil) { _ in true } == nil)
    }

    @Test func aCoveredSessionIsNotUnderTheNose() {
        let s = FocusTracker.session(at: CGPoint(x: 700, y: 250), in: [left, right], current: nil) { $0.id == "L" }
        #expect(s == nil)
    }

    @Test func nearTheBorderTheCurrentSessionStays() {
        let nearBorder = CGPoint(x: 510, y: 250)             // inside R, but less than the margin from L
        let stay = FocusTracker.session(at: nearBorder, in: [left, right], current: left) { _ in true }
        #expect(stay?.id == "L")
        let deep = CGPoint(x: 560, y: 250)                   // well inside R
        #expect(FocusTracker.session(at: deep, in: [left, right], current: left) { _ in true }?.id == "R")
        let far = CGPoint(x: 700, y: 250)                    // R, and too far from L to hold on
        #expect(FocusTracker.session(at: far, in: [left, right], current: left) { _ in true }?.id == "R")
    }

    @Test func targetMovesOnlyAfterTheDwell() {
        var f = FocusTracker()
        #expect(f.observe(under: left, at: 10, held: false, listening: false) == nil)
        #expect(f.target == nil)
        #expect(f.observe(under: left, at: 10.05, held: false, listening: false) == nil)
        #expect(f.observe(under: left, at: 10.08, held: false, listening: false)?.id == "L")
        #expect(f.target?.id == "L" && f.candidate == nil)
    }

    @Test func returningToTheTargetCancelsTheCandidate() {
        var f = FocusTracker()
        _ = f.observe(under: left, at: 10, held: false, listening: false)
        _ = f.observe(under: left, at: 10.1, held: false, listening: false)
        _ = f.observe(under: right, at: 11, held: false, listening: false)
        #expect(f.candidate?.session?.id == "R")
        _ = f.observe(under: left, at: 11.02, held: false, listening: false)
        #expect(f.candidate == nil && f.target?.id == "L")
    }

    @Test func dwellIsTwoSecondsWhileDictatingOnASession() {
        var f = FocusTracker()
        _ = f.observe(under: left, at: 10, held: false, listening: false)
        _ = f.observe(under: left, at: 10.1, held: false, listening: false)
        _ = f.observe(under: right, at: 20, held: false, listening: true)
        #expect(f.observe(under: right, at: 21.9, held: false, listening: true) == nil)
        #expect(f.observe(under: right, at: 22.0, held: false, listening: true)?.id == "R")
    }

    @Test func leavingEverySessionClearsTheTargetAfterTheShortDwellEvenWhileDictating() {
        var f = FocusTracker()
        _ = f.observe(under: left, at: 10, held: false, listening: false)
        _ = f.observe(under: left, at: 10.1, held: false, listening: false)
        _ = f.observe(under: nil, at: 20, held: false, listening: true)
        #expect(f.observe(under: nil, at: 20.08, held: false, listening: true) == nil)
        #expect(f.target == nil)
    }

    @Test func heldHandKeepsEverythingStill() {
        var f = FocusTracker()
        _ = f.observe(under: left, at: 10, held: false, listening: false)
        #expect(f.candidate != nil)
        #expect(f.observe(under: left, at: 11, held: true, listening: false) == nil)
        #expect(f.candidate == nil && f.target == nil)
    }

    @Test func coveredSessionIsRaisedAfterTheRestingDwell() {
        var f = FocusTracker()
        do { let r = f.noteCovered("L", at: 10); #expect(!r) }
        do { let r = f.noteCovered("L", at: 10.7); #expect(!r) }
        do { let r = f.noteCovered("L", at: 10.8); #expect(r) }
        do { let r = f.noteCovered("L", at: 11); #expect(r) } // still due until the caller clears it
        f.clearCovered()
        do { let r = f.noteCovered("L", at: 11.1); #expect(!r) }
        do { let r = f.noteCovered("R", at: 11.2); #expect(!r) } // another session restarts the clock
    }

    @Test func forgettingKeepsWhatItShouldKeep() {
        var f = FocusTracker()
        _ = f.observe(under: left, at: 10, held: false, listening: false)
        _ = f.observe(under: left, at: 10.1, held: false, listening: false)
        _ = f.observe(under: right, at: 11, held: false, listening: false)
        f.forgetTarget()
        #expect(f.target == nil && f.candidate != nil)
        f.forgetTargetAndCandidate()
        #expect(f.candidate == nil)
    }
}

@Suite struct NoseDotTests {
    @Test func firstReadingPlacesTheDotOnTheNose() {
        #expect(NoseDot.follow(nil, nose: CGPoint(x: 5, y: 6)) == CGPoint(x: 5, y: 6))
    }

    @Test func wobbleInsideTheLeashDoesNotMoveIt() {
        let d = CGPoint(x: 100, y: 100)
        #expect(NoseDot.follow(d, nose: CGPoint(x: 110, y: 110)) == d)
    }

    @Test func beyondTheLeashTheDotTrailsByExactlyTheLeash() {
        let p = NoseDot.follow(CGPoint(x: 0, y: 0), nose: CGPoint(x: 100, y: 0))
        #expect(abs(p.x - 76) < 1e-9 && p.y == 0)
    }
}

@Suite struct FocusPolicyTests {
    private let s = ClaudeSession(id: "A", frame: .zero, windowNumber: 1)

    private func action(last: String? = nil, front: Bool = true, busy: Bool = false, input: Double = 5, listening: String? = nil) -> FocusAction {
        FocusPolicy.action(for: s, lastFocusedId: last, claudeInFront: front, busy: busy, secondsSinceInput: input, inputQuiet: 1.5, listeningId: listening)
    }

    @Test func aSessionThatAlreadyHasFocusIsLeftAlone() {
        #expect(action(last: "A") == .none)
        #expect(action(last: "A", front: false) == .focusNow)
        #expect(action(last: "B") == .focusNow)
    }

    @Test func busyOrTypingDefersFocus() {
        #expect(action(busy: true) == .retryLater)
        #expect(action(input: 1.0) == .retryLater)
        #expect(action(input: 1.5) == .focusNow)
    }

    @Test func whileDictatingElsewhereDictationStopsFirst() {
        #expect(action(listening: "B") == .stopDictationFirst)
        #expect(action(listening: "A") == .none)
    }

    @Test func theFrontCheckRunsOnlyWhenTheIdsMatch() {
        var asked = 0
        _ = FocusPolicy.action(for: s, lastFocusedId: "B", claudeInFront: { asked += 1; return true }(), busy: false,
                               secondsSinceInput: 5, inputQuiet: 1.5, listeningId: nil)
        #expect(asked == 0)
    }
}
