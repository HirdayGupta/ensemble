import Testing
@testable import EnsembleCore

@Suite struct MultiFaceDetectorTests {
    private func feed(_ d: inout MultiFaceDetector, counts: [Int], from start: Double = 0, fps: Double = 30) -> Double {
        var t = start
        for c in counts { d.record(faceCount: c, at: t); t += 1 / fps }
        return t - 1 / fps
    }

    @Test func oneStrayReadingNeverCounts() {
        var d = MultiFaceDetector()
        var counts = [Int](repeating: 1, count: 150)
        counts[60] = 2
        let end = feed(&d, counts: counts)
        #expect(!d.isActive(now: end))
        #expect(!d.isActive(now: 2.05))
    }

    @Test func fourReadingsInOneSecondStillDoNotCount() {
        var d = MultiFaceDetector()
        let end = feed(&d, counts: [1, 2, 1, 2, 1, 2, 1, 2] + [Int](repeating: 1, count: 20))
        #expect(!d.isActive(now: end))
    }

    @Test func fiveReadingsInOneSecondCount() {
        var d = MultiFaceDetector()
        let end = feed(&d, counts: [1, 2, 1, 2, 2, 1, 2, 2] + [Int](repeating: 1, count: 5))
        #expect(d.isActive(now: end))
    }

    @Test func aSecondPersonStandingThereCountsFromTheFifthReading() {
        var d = MultiFaceDetector()
        var t = 0.0
        var firstActive: Double?
        for _ in 0..<60 {
            d.record(faceCount: 2, at: t)
            if firstActive == nil, d.isActive(now: t) { firstActive = t }
            t += 1 / 30
        }
        #expect(abs((firstActive ?? 99) - 4.0 / 30) < 1e-9)
    }

    @Test func clearsOnceTheReadingsAgeOutOfTheWindow() {
        var d = MultiFaceDetector()
        let end = feed(&d, counts: [Int](repeating: 2, count: 30))
        #expect(d.isActive(now: end))
        #expect(!d.isActive(now: end + 1.2))
        let later = feed(&d, counts: [Int](repeating: 1, count: 30), from: end + 1 / 30)
        #expect(!d.isActive(now: later))
    }

    @Test func zeroFaceReadingsAreNotSecondFaces() {
        var d = MultiFaceDetector()
        let end = feed(&d, counts: [Int](repeating: 0, count: 60))
        #expect(!d.isActive(now: end))
    }
}
