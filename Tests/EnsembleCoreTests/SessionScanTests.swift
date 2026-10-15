import CoreGraphics
import Testing
@testable import EnsembleCore

@Suite struct SessionScanTests {
    // MARK: When to walk Claude's tree

    @Test func unchangedWindowsReuseTheCache() {
        #expect(!SessionScan.needsFullWalk(cached: 3, windowsChanged: false, cachedAnswer: true, sinceFullWalk: 1))
        #expect(!SessionScan.needsFullWalk(cached: 3, windowsChanged: false, cachedAnswer: true, sinceFullWalk: 9.9))
    }

    @Test func anyDoubtWalksAgain() {
        #expect(SessionScan.needsFullWalk(cached: 0, windowsChanged: false, cachedAnswer: true, sinceFullWalk: 1))
        #expect(SessionScan.needsFullWalk(cached: 3, windowsChanged: true, cachedAnswer: true, sinceFullWalk: 1))
        #expect(SessionScan.needsFullWalk(cached: 3, windowsChanged: false, cachedAnswer: false, sinceFullWalk: 1))
        #expect(SessionScan.needsFullWalk(cached: 3, windowsChanged: false, cachedAnswer: true, sinceFullWalk: 10))
        #expect(SessionScan.needsFullWalk(cached: 3, windowsChanged: false, cachedAnswer: true, sinceFullWalk: .infinity))
        #expect(SessionScan.needsFullWalk(cached: 3, windowsChanged: false, cachedAnswer: true, sinceFullWalk: .nan))
    }

    // MARK: One empty scan

    /// Measured: "found 0" between two "found 3" a second apart with Claude in front.
    @Test func oneEmptyScanKeepsTheSessions() {
        var hold = SessionListHold()
        #expect(hold.keepPrevious(found: 0, walkComplete: true, previous: 3, previousAnswer: true))
    }

    @Test func twoEmptyScansInARowDropThem() {
        var hold = SessionListHold()
        #expect(hold.keepPrevious(found: 0, walkComplete: true, previous: 3, previousAnswer: true))
        #expect(!hold.keepPrevious(found: 0, walkComplete: true, previous: 3, previousAnswer: true))
    }

    @Test func aGoodScanBetweenResetsTheCount() {
        var hold = SessionListHold()
        #expect(hold.keepPrevious(found: 0, walkComplete: true, previous: 3, previousAnswer: true))
        #expect(!hold.keepPrevious(found: 3, walkComplete: true, previous: 3, previousAnswer: true))
        #expect(hold.doubtfulInARow == 0)
        #expect(hold.keepPrevious(found: 0, walkComplete: true, previous: 3, previousAnswer: true))
    }

    @Test func sessionsThatNoLongerAnswerAreDroppedAtOnce() {
        var hold = SessionListHold()
        #expect(!hold.keepPrevious(found: 0, walkComplete: true, previous: 3, previousAnswer: false))
    }

    @Test func aWalkCutShortIsDoubtfulToo() {
        var hold = SessionListHold()
        #expect(hold.keepPrevious(found: 1, walkComplete: false, previous: 3, previousAnswer: true))
        #expect(!hold.keepPrevious(found: 1, walkComplete: false, previous: 3, previousAnswer: true))
    }

    @Test func nothingBeforeNothingToKeep() {
        var hold = SessionListHold()
        #expect(!hold.keepPrevious(found: 0, walkComplete: true, previous: 0, previousAnswer: true))
        #expect(hold.doubtfulInARow == 0)
        var reset = SessionListHold()
        #expect(reset.keepPrevious(found: 0, walkComplete: true, previous: 2, previousAnswer: true))
        reset.reset()
        #expect(reset.keepPrevious(found: 0, walkComplete: true, previous: 2, previousAnswer: true))
    }

    // MARK: Which window

    static let main = CGRect(x: 0, y: 30, width: 2560, height: 1327)
    /// Claude keeps hidden windows; measured: an 800 x 600 one off screen beside the main window.
    static let hidden = WindowCandidate(number: 942, bounds: CGRect(x: 880, y: 394, width: 800, height: 600), onScreen: false)

    @Test func theWindowNumberDecides() {
        let windows = [WindowCandidate(number: 181, bounds: Self.main, onScreen: true), Self.hidden]
        // Even with frames apart for a moment (a resize in flight), the number still names the window.
        let moved = CGRect(x: 40, y: 60, width: 1200, height: 900)
        #expect(WindowMatch.match(axNumber: 181, axFrame: moved, among: windows)?.number == 181)
        #expect(WindowMatch.match(axNumber: 942, axFrame: Self.main, among: windows)?.onScreen == false)
    }

    @Test func anOnScreenWindowWinsOverAHiddenTwin() {
        let twin = WindowCandidate(number: 7, bounds: Self.main, onScreen: false)
        let shown = WindowCandidate(number: 8, bounds: Self.main.offsetBy(dx: 1, dy: 1), onScreen: true)
        #expect(WindowMatch.match(axNumber: nil, axFrame: Self.main, among: [twin, shown])?.number == 8)
        // Only the hidden one fits: it is reported as hidden, so its sessions are skipped.
        #expect(WindowMatch.match(axNumber: nil, axFrame: Self.main, among: [twin])?.onScreen == false)
    }

    @Test func framesBrieflyApartStillMatchTheWindow() {
        let windows = [WindowCandidate(number: 181, bounds: Self.main, onScreen: true), Self.hidden]
        let mid = CGRect(x: 0, y: 30, width: 2540, height: 1320)
        #expect(WindowMatch.match(axNumber: nil, axFrame: mid, among: windows)?.number == 181)
    }

    @Test func noGuessBetweenTwoLookalikes() {
        let a = WindowCandidate(number: 1, bounds: CGRect(x: 0, y: 0, width: 1000, height: 800), onScreen: true)
        let b = WindowCandidate(number: 2, bounds: CGRect(x: 10, y: 10, width: 1000, height: 800), onScreen: true)
        let between = CGRect(x: 5, y: 5, width: 1000, height: 800)
        #expect(WindowMatch.match(axNumber: nil, axFrame: between, among: [a, b]) == nil)
        // An unknown number falls back to the frames.
        #expect(WindowMatch.match(axNumber: 99, axFrame: a.bounds, among: [a, b])?.number == 1)
        #expect(WindowMatch.match(axNumber: nil, axFrame: .zero, among: [a, b]) == nil)
    }
}
