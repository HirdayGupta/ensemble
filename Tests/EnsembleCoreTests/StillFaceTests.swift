import Foundation
import Testing
@testable import EnsembleCore

struct StillFaceTests {
    private static let frame = 1.0 / 30

    /// Feeds one change value per 30 fps frame; the tracker answers each sent frame at once. Returns the decisions.
    private func run(_ s: inout StillFace, changes: [Double?], from t0: TimeInterval = 0, force: (Int) -> Bool = { _ in false })
        -> [StillFace.Decision] {
        var out: [StillFace.Decision] = []
        var lastReading: TimeInterval? = t0 - Self.frame
        for (i, change) in changes.enumerated() {
            let t = t0 + Double(i) * Self.frame
            let d = s.decide(change: change, now: t, forceFull: force(i), lastReadingAt: lastReading)
            if d == .send { s.sent(at: t); lastReading = t }
            out.append(d)
        }
        return out
    }

    private func sends(_ d: [StillFace.Decision]) -> Int { d.filter { $0 == .send }.count }

    @Test func aStillHeadSkipsAfterThreeStillFrames() {
        var s = StillFace()
        let d = run(&s, changes: Array(repeating: 0.5, count: 10))
        #expect(Array(d.prefix(2)) == [.send, .send])
        #expect(d[2] != .send)
        #expect(sends(d) == 2)
    }

    @Test func theFirstMovingFrameAfterStillnessIsSentAtOnce() {
        var s = StillFace()
        var changes: [Double?] = Array(repeating: 0.5, count: 20)
        changes[12] = 9
        let d = run(&s, changes: changes)
        #expect(d[11] != .send)
        #expect(d[12] == .send)
        // Stillness has to build up again before the next skip.
        #expect(d[13] == .send && d[14] == .send && d[15] != .send)
    }

    @Test func aChangeAtTheThresholdCountsAsMovement() {
        var s = StillFace()
        let d = run(&s, changes: Array(repeating: s.threshold, count: 10))
        #expect(sends(d) == 10)
    }

    @Test func movementKeepsEveryFrame() {
        var s = StillFace()
        let d = run(&s, changes: (0..<60).map { $0 % 2 == 0 ? 0.5 : 12 })
        // A still frame between moving ones never builds the run of three.
        #expect(sends(d) == 60)
    }

    @Test func forcedFullRateSendsEveryFrameAndEndsTheRun() {
        var s = StillFace()
        let d = run(&s, changes: Array(repeating: 0.5, count: 30), force: { (10..<20).contains($0) })
        #expect(d[9] != .send)
        #expect((10..<20).allSatisfy { d[$0] == .send })
        #expect(d[20] == .send && d[21] == .send && d[22] != .send)
    }

    @Test func noComparisonFrameSends() {
        var s = StillFace()
        let d = run(&s, changes: Array(repeating: nil, count: 10))
        #expect(sends(d) == 10)
    }

    @Test func aStillHeadStillGetsARealReadingEverySecond() {
        var s = StillFace()
        let d = run(&s, changes: Array(repeating: 0.5, count: 300))   // 10 s
        #expect((11...13).contains(sends(d)))
    }

    @Test func reusedReadingsAreHandedOnAboutTenTimesASecond() {
        var s = StillFace()
        let d = run(&s, changes: Array(repeating: 0.5, count: 300))
        let emitted = d.filter { $0 == .reuse(emit: true) }.count
        #expect((90...105).contains(emitted + sends(d)))
    }

    @Test func nothingIsReusedFromATrackerThatStoppedAnswering() {
        var s = StillFace()
        var t = 0.0
        var decisions: [StillFace.Decision] = []
        for _ in 0..<90 {
            // The tracker answered once at 0 and never again.
            let d = s.decide(change: 0.5, now: t, forceFull: false, lastReadingAt: 0)
            if d == .send { s.sent(at: t) }
            decisions.append(d)
            t += Self.frame
        }
        // Past the reading age every frame goes to the tracker again.
        #expect(decisions.suffix(30).allSatisfy { $0 == .send })
    }

    @Test func noReadingYetSends() {
        var s = StillFace()
        #expect(s.decide(change: 0, now: 1, forceFull: false, lastReadingAt: nil) == .send)
    }

    @Test func changeIsTheLargestCellDifference() {
        #expect(StillFace.change([10, 20, 30], [11, 20, 25]) == 5)
        #expect(StillFace.change([10, 20], [10, 20]) == 0)
        #expect(StillFace.change([10, 20], [10]) == nil)
        #expect(StillFace.change([], []) == nil)
    }

    @Test func resetForgetsTheRun() {
        var s = StillFace()
        _ = run(&s, changes: Array(repeating: 0.5, count: 5))
        s.reset()
        let d = run(&s, changes: [0.5], from: 5)
        #expect(d == [.send])
    }
}
