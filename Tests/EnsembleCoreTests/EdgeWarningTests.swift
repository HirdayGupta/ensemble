import CoreGraphics
import Testing
@testable import EnsembleCore

@Suite struct EdgeWarningTests {
    // Three panes in a row, 0..400, 400..800 and a lower one 0..400 at y 600..1000; plus a gap-less top row.
    let a = ClaudeSession(id: "a", frame: CGRect(x: 0, y: 0, width: 400, height: 500), windowNumber: 1)
    let b = ClaudeSession(id: "b", frame: CGRect(x: 400, y: 0, width: 400, height: 500), windowNumber: 2)
    let c = ClaudeSession(id: "c", frame: CGRect(x: 0, y: 500, width: 400, height: 500), windowNumber: 3)
    var all: [ClaudeSession] { [a, b, c] }

    @Test func innerPartWarnsNothing() {
        #expect(EdgeWarnings.warning(nose: CGPoint(x: 200, y: 250), dictating: a, sessions: all) == nil)
        #expect(EdgeWarnings.warning(nose: CGPoint(x: 339, y: 250), dictating: a, sessions: all) == nil)
    }

    @Test func proximityGrowsThroughTheBandThenCrosses() throws {
        // Band is 60 wide: 340...400 on the right.
        let mid = try #require(EdgeWarnings.warning(nose: CGPoint(x: 370, y: 250), dictating: a, sessions: all))
        #expect(mid.side == .right && mid.neighbourId == "b" && !mid.crossed)
        #expect(abs(mid.proximity - 0.5) < 1e-9)
        let edge = try #require(EdgeWarnings.warning(nose: CGPoint(x: 399, y: 250), dictating: a, sessions: all))
        #expect(edge.proximity > 0.98 && !edge.crossed)
        let out = try #require(EdgeWarnings.warning(nose: CGPoint(x: 420, y: 250), dictating: a, sessions: all))
        #expect(out.crossed && out.proximity == 1 && out.neighbourId == "b")
    }

    @Test func seamIsTheSharedStretchOfTheEdge() throws {
        let tall = ClaudeSession(id: "t", frame: CGRect(x: 400, y: 200, width: 400, height: 900), windowNumber: 4)
        let w = try #require(EdgeWarnings.warning(nose: CGPoint(x: 380, y: 300), dictating: a, sessions: [a, tall]))
        #expect(w.neighbourId == "t" && w.seamStart == 200 && w.seamEnd == 500)
        let (p, q) = w.seam(in: a.frame)
        #expect(p == CGPoint(x: 400, y: 200) && q == CGPoint(x: 400, y: 500))
    }

    @Test func belowIsTheLowerPane() throws {
        let w = try #require(EdgeWarnings.warning(nose: CGPoint(x: 200, y: 480), dictating: a, sessions: all))
        #expect(w.side == .bottom && w.neighbourId == "c" && w.seamStart == 0 && w.seamEnd == 400)
    }

    @Test func nothingBeyondIsNotClaude() throws {
        let left = try #require(EdgeWarnings.warning(nose: CGPoint(x: 10, y: 250), dictating: a, sessions: all))
        #expect(left.side == .left && left.neighbourId == nil && left.seamStart == 0 && left.seamEnd == 500)
        let top = try #require(EdgeWarnings.warning(nose: CGPoint(x: 200, y: -30), dictating: a, sessions: all))
        #expect(top.side == .top && top.neighbourId == nil && top.crossed)
    }

    @Test func noseOutsideEveryNeighboursStretchIsNotClaude() throws {
        let short = ClaudeSession(id: "s", frame: CGRect(x: 400, y: 0, width: 400, height: 100), windowNumber: 5)
        let w = try #require(EdgeWarnings.warning(nose: CGPoint(x: 390, y: 400), dictating: a, sessions: [a, short]))
        #expect(w.neighbourId == nil)
    }

    @Test func nearestNeighbourWinsAndItselfIsNeverANeighbour() throws {
        let far = ClaudeSession(id: "far", frame: CGRect(x: 900, y: 0, width: 400, height: 500), windowNumber: 6)
        let w = try #require(EdgeWarnings.warning(nose: CGPoint(x: 380, y: 250), dictating: a, sessions: [far, a, b]))
        #expect(w.neighbourId == "b")
    }

    @Test func deeperCrossingNeedsFifteenPercentOfTheNeighbour() {
        // b is 400 wide: the nose must be 60 inside it.
        #expect(!EdgeWarnings.restsDeepInside(nose: CGPoint(x: 430, y: 250), neighbour: b.frame, dictating: a.frame))
        #expect(EdgeWarnings.restsDeepInside(nose: CGPoint(x: 460, y: 250), neighbour: b.frame, dictating: a.frame))
        // c is below and 500 tall: 75 inside.
        #expect(!EdgeWarnings.restsDeepInside(nose: CGPoint(x: 200, y: 560), neighbour: c.frame, dictating: a.frame))
        #expect(EdgeWarnings.restsDeepInside(nose: CGPoint(x: 200, y: 575), neighbour: c.frame, dictating: a.frame))
        // A neighbour on the left measures from its right edge.
        let left = CGRect(x: -400, y: 0, width: 400, height: 500)
        #expect(!EdgeWarnings.restsDeepInside(nose: CGPoint(x: -30, y: 250), neighbour: left, dictating: a.frame))
        #expect(EdgeWarnings.restsDeepInside(nose: CGPoint(x: -60, y: 250), neighbour: left, dictating: a.frame))
    }
}

@Suite struct SpeechLockTests {
    @Test func inactiveUntilTheMeterReports() {
        let lock = SpeechLock()
        #expect(!lock.locked(at: 10))
    }

    @Test func locksWhileLoudAndReleasesAfterSixTenthsOfQuiet() {
        var lock = SpeechLock()
        lock.note(level: 0.8, at: 10)
        #expect(lock.locked(at: 10.5))
        lock.note(level: 0.05, at: 10.5)
        #expect(lock.locked(at: 10.59))
        #expect(!lock.locked(at: 10.61))
    }

    @Test func quietReadingsNeverLock() {
        var lock = SpeechLock()
        lock.note(level: 0.1, at: 1)
        #expect(!lock.locked(at: 1.1))
    }

    @Test func aStoppedMeterReleasesAtOnce() {
        var lock = SpeechLock()
        lock.note(level: 0.9, at: 1)
        lock.meterStopped()
        #expect(!lock.locked(at: 1.1))
    }
}

@Suite struct SpeakingDwellTests {
    let a = ClaudeSession(id: "a", frame: CGRect(x: 0, y: 0, width: 400, height: 500), windowNumber: 1)
    let b = ClaudeSession(id: "b", frame: CGRect(x: 400, y: 0, width: 400, height: 500), windowNumber: 2)

    @Test func speakingFreezesTheDwellAndQuietResumesIt() {
        var t = FocusTracker()
        _ = t.observe(under: a, at: 0, held: false, listening: false)
        _ = t.observe(under: a, at: 0.075, held: false, listening: false)
        #expect(t.target?.id == "a")
        #expect(t.observe(under: b, at: 1.0, held: false, listening: true) == nil)      // candidate starts
        // Speaking for 3 s: the 2 s dwell must not complete.
        var now = 1.0
        for _ in 0..<30 { now += 0.1; #expect(t.observe(under: b, at: now, held: false, listening: true, speaking: true) == nil) }
        // Quiet again: the dwell resumes from where it stood (nothing counted yet), so 1.9 s is not enough.
        for _ in 0..<19 { now += 0.1; #expect(t.observe(under: b, at: now, held: false, listening: true) == nil) }
        now += 0.2
        #expect(t.observe(under: b, at: now, held: false, listening: true)?.id == "b")
    }

    @Test func speakingDoesNothingWhenNotListening() {
        var t = FocusTracker()
        _ = t.observe(under: a, at: 0, held: false, listening: false)
        _ = t.observe(under: a, at: 0.075, held: false, listening: false)
        _ = t.observe(under: b, at: 1, held: false, listening: false, speaking: true)
        #expect(t.observe(under: b, at: 1.1, held: false, listening: false, speaking: true)?.id == "b")
    }
}
