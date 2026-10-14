import Testing
@testable import ClutchCore

@Suite struct CoverDetectorTests {
    private func run(_ d: CoverDetector, luma: Double, std: Double = 0.01, from: Double, for seconds: Double, step: Double = 0.1) -> [(t: Double, state: Bool)] {
        var changes: [(Double, Bool)] = []
        var t = from
        while t <= from + seconds + 1e-9 {
            if let s = d.push(FrameLight(t: t, meanLuma: luma, lumaStdDev: std)) { changes.append((t, s)) }
            t += step
        }
        return changes
    }

    @Test func coversAfterOneAndAHalfSeconds() {
        let d = CoverDetector()
        #expect(run(d, luma: 0.02, from: 0, for: 1.4).isEmpty)
        #expect(!d.covered)
        let changes = run(d, luma: 0.02, from: 1.5, for: 2)
        #expect(changes.count == 1)
        #expect(changes[0].state)
        #expect(abs(changes[0].t - 1.5) < 0.11)
        #expect(d.covered)
    }

    @Test func uncoversAfterOneSecondOfLight() {
        let d = CoverDetector()
        _ = run(d, luma: 0.02, from: 0, for: 2)
        #expect(d.covered)
        #expect(run(d, luma: 0.4, from: 2.1, for: 0.8).isEmpty)
        #expect(d.covered)
        let changes = run(d, luma: 0.4, from: 2.9, for: 1)
        #expect(changes.count == 1 && changes[0].state == false)
        #expect(!d.covered)
    }

    @Test func darkRoomWithDetailIsNotCovered() {
        let d = CoverDetector()
        #expect(run(d, luma: 0.05, std: 0.1, from: 0, for: 5).isEmpty)
        #expect(!d.covered)
    }

    @Test func brightFrameResetsTheDarkTimer() {
        let d = CoverDetector()
        _ = run(d, luma: 0.02, from: 0, for: 1.0)
        _ = run(d, luma: 0.5, from: 1.1, for: 0.1)
        #expect(run(d, luma: 0.02, from: 1.3, for: 1.0).isEmpty)
        #expect(!d.covered)
    }

    @Test func dimLightBetweenThresholdsHoldsTheState() {
        let d = CoverDetector()
        _ = run(d, luma: 0.02, from: 0, for: 2)
        #expect(run(d, luma: 0.10, std: 0.01, from: 2.1, for: 5).isEmpty)
        #expect(d.covered)
    }

    @Test func briefLightDuringCoverDoesNotUncover() {
        let d = CoverDetector()
        _ = run(d, luma: 0.02, from: 0, for: 2)
        _ = run(d, luma: 0.5, from: 2.1, for: 0.5)
        _ = run(d, luma: 0.02, from: 2.7, for: 0.5)
        _ = run(d, luma: 0.5, from: 3.3, for: 0.5)
        #expect(d.covered)
    }
}
