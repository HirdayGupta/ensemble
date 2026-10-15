import CoreGraphics
import Testing
@testable import EnsembleCore

/// The 1 s check driven by Claude's own notifications instead of reading every pane frame and walking on every window
/// move (`SessionScan.plan`, `ClaudeChanges`, `ChangeCoalescer`).
@Suite struct ClaudeChangesTests {
    static let main = CGRect(x: 0, y: 30, width: 2560, height: 1327)
    static let shown = WindowCandidate(number: 181, bounds: main, onScreen: true)
    static let hidden = WindowCandidate(number: 942, bounds: CGRect(x: 880, y: 394, width: 800, height: 600), onScreen: false)

    private func plan(cached: Int = 4, set: Bool = false, bounds: Bool = false, changes: ClaudeChanges = [],
                      observing: Bool = true, since: Double = 1) -> SessionScan.Plan {
        SessionScan.plan(cached: cached, windowSetChanged: set, boundsChanged: bounds, changes: changes,
                         observing: observing, sinceFullWalk: since)
    }

    // MARK: What the check reads

    @Test func quietClaudeReadsOnlyTheCheckboxes() {
        #expect(plan() == .reread(frames: false))
        #expect(plan(since: 14.9) == .reread(frames: false))
    }

    @Test func aMoveOrDividerReadsTheFramesWithoutAWalk() {
        #expect(plan(changes: .frames) == .reread(frames: true))
        // The window server saw a move the notifications missed.
        #expect(plan(bounds: true) == .reread(frames: true))
    }

    @Test func somethingOpenedOrClosedWalks() {
        #expect(plan(changes: .structure) == .walk)
        #expect(plan(changes: [.frames, .structure]) == .walk)
        #expect(plan(set: true) == .walk)
        #expect(plan(cached: 0) == .walk)
    }

    @Test func theSafetyWalkStillRuns() {
        #expect(plan(since: 15) == .walk)
        #expect(plan(since: .infinity) == .walk)
        #expect(plan(since: .nan) == .walk)
    }

    @Test func withoutNotificationsItBehavesAsBefore() {
        #expect(plan(observing: false) == .reread(frames: true))
        #expect(plan(bounds: true, observing: false) == .walk)
        #expect(plan(set: true, observing: false) == .walk)
        #expect(plan(observing: false, since: 10) == .walk)
        #expect(plan(cached: 0, observing: false) == .walk)
        // Reported changes are ignored without the observer: every check reads everything anyway.
        #expect(plan(changes: .structure, observing: false) == .reread(frames: true))
    }

    // MARK: Windows

    @Test func aMoveIsNotANewWindow() {
        let moved = WindowCandidate(number: 181, bounds: Self.main.offsetBy(dx: 40, dy: 0), onScreen: true)
        #expect(!SessionScan.windowSetChanged([Self.shown, Self.hidden], [moved, Self.hidden]))
        #expect(SessionScan.windowMoved(181, from: [Self.shown, Self.hidden], to: [moved, Self.hidden]))
        #expect(!SessionScan.windowMoved(942, from: [Self.shown, Self.hidden], to: [moved, Self.hidden]))
    }

    @Test func openingClosingOrLeavingTheScreenIsANewSet() {
        #expect(SessionScan.windowSetChanged([Self.shown], [Self.shown, Self.hidden]))
        #expect(SessionScan.windowSetChanged([Self.shown, Self.hidden], [Self.shown]))
        // Another Space or a full-screen app took the window off screen.
        var away = Self.shown
        away.onScreen = false
        #expect(SessionScan.windowSetChanged([Self.shown], [away]))
        #expect(SessionScan.windowSetChanged(nil, [Self.shown]))
        #expect(!SessionScan.windowSetChanged([Self.hidden, Self.shown], [Self.shown, Self.hidden]))
    }

    @Test func aWindowMissingFromEitherListCountsAsMoved() {
        #expect(SessionScan.windowMoved(181, from: nil, to: [Self.shown]))
        #expect(SessionScan.windowMoved(181, from: [Self.shown], to: []))
        #expect(SessionScan.windowMoved(0, from: [Self.shown], to: [Self.shown]))
    }

    // MARK: Panes laid out again

    @Test func aPaneThatChangedInsideAStillWindowMeansANewLayout() {
        let pane = CGRect(x: 300, y: 80, width: 560, height: 1200)
        #expect(SessionScan.retiled(cachedFrame: pane, frame: CGRect(x: 300, y: 80, width: 420, height: 1200), windowMoved: false))
        #expect(SessionScan.retiled(cachedFrame: pane, frame: pane.offsetBy(dx: 140, dy: 0), windowMoved: false))
    }

    @Test func aWindowMoveOrHalfAPointIsNot() {
        let pane = CGRect(x: 300, y: 80, width: 560, height: 1200)
        #expect(!SessionScan.retiled(cachedFrame: pane, frame: pane.offsetBy(dx: 200, dy: 50), windowMoved: true))
        #expect(!SessionScan.retiled(cachedFrame: pane, frame: pane.offsetBy(dx: 0.5, dy: 0), windowMoved: false))
        #expect(!SessionScan.retiled(cachedFrame: pane, frame: pane, windowMoved: false))
    }

    // MARK: Notifications

    @Test func notificationsMapToWhatTheyMean() {
        #expect(ClaudeChanges(notification: "AXUIElementDestroyed") == .structure)
        for name in ["AXWindowMoved", "AXWindowResized", "AXValueChanged", "AXLayoutChanged", "AXFocusedWindowChanged",
                     "AXMainWindowChanged", "AXWindowCreated", "AXWindowMiniaturized", "AXWindowDeminiaturized"] {
            #expect(ClaudeChanges(notification: name) == .frames)
        }
        // Measured: Claude creates a hidden window about every 22 s; it alone is never a reason to walk.
        #expect(!ClaudeChanges(notification: "AXWindowCreated").contains(.structure))
        #expect(ClaudeChanges(notification: "AXTitleChanged").isEmpty)
        #expect(ClaudeChanges(notification: "AXSelectedTextChanged").isEmpty)
    }

    // MARK: Folding a burst

    private func note(_ c: inout ChangeCoalescer, _ change: ClaudeChanges) -> Bool { c.note(change) }
    private func take(_ c: inout ChangeCoalescer) -> ClaudeChanges { c.take() }

    @Test func aBurstSchedulesOneRefresh() {
        var c = ChangeCoalescer()
        #expect(note(&c, .frames) == true)
        for _ in 0..<40 { #expect(note(&c, .frames) == false) }
        #expect(note(&c, .structure) == false)
        #expect(c.pending == [.frames, .structure])
        c.fired()
        #expect(take(&c) == [.frames, .structure])
        #expect(c.pending.isEmpty)
        #expect(note(&c, .frames) == true)
    }

    @Test func aRefreshThatCouldNotRunKeepsTheChanges() {
        var c = ChangeCoalescer()
        _ = note(&c, .structure)
        c.fired()
        // The refresh was skipped (one in flight, or dictating): the next one still sees the change.
        #expect(c.pending == .structure)
        #expect(note(&c, .frames) == true)
        #expect(take(&c) == [.frames, .structure])
    }

    @Test func nothingToReportSchedulesNothing() {
        var c = ChangeCoalescer()
        #expect(note(&c, []) == false)
        #expect(!c.scheduled)
        #expect(c.pending.isEmpty)
    }
}
