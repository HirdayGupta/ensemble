import CoreGraphics
import Foundation
import Testing
@testable import EnsembleCore

@Suite struct NosePointerTests {
    // Ground truth: x = 2400*yaw - 300*pitch + 960, y = 150*yaw + 2000*pitch + 540 (screen points).
    private func truth(_ yaw: Double, _ pitch: Double) -> CGPoint {
        CGPoint(x: 2400 * yaw - 300 * pitch + 960, y: 150 * yaw + 2000 * pitch + 540)
    }

    private func samples(noise: Double = 0) -> [CalibrationSample] {
        var rng = SystemRandomNumberGenerator()
        var out: [CalibrationSample] = []
        for yaw in [-0.25, 0, 0.25] {
            for pitch in [-0.15, 0, 0.15] {
                let p = truth(yaw, pitch)
                let jx = noise == 0 ? 0 : Double.random(in: -noise...noise, using: &rng)
                let jy = noise == 0 ? 0 : Double.random(in: -noise...noise, using: &rng)
                out.append(CalibrationSample(yaw: yaw, pitch: pitch, target: CGPoint(x: p.x + jx, y: p.y + jy)))
            }
        }
        return out
    }

    private func head(_ yaw: Double, _ pitch: Double, t: Double = 0) -> HeadObservation {
        HeadObservation(t: t, yaw: yaw, pitch: pitch, faceCount: 1)
    }

    @Test func uncalibratedReturnsNil() {
        let p = NosePointer()
        #expect(!p.isCalibrated)
        #expect(p.raw(for: head(0, 0)) == nil)
        #expect(p.point(for: head(0, 0)) == nil)
        #expect(p.calibration == nil)
    }

    @Test func exactFitRecoversTheAffineMap() {
        let p = NosePointer()
        #expect(p.fit(samples()))
        #expect(p.isCalibrated)
        let r = p.raw(for: head(0.1, -0.05))!
        let want = truth(0.1, -0.05)
        #expect(abs(r.x - want.x) < 1e-6 && abs(r.y - want.y) < 1e-6)
    }

    @Test func noisyFitStaysClose() {
        let p = NosePointer()
        #expect(p.fit(samples(noise: 8)))
        let r = p.raw(for: head(0.1, 0.1))!
        let want = truth(0.1, 0.1)
        #expect(abs(r.x - want.x) < 15 && abs(r.y - want.y) < 15)
    }

    @Test func rejectsTooFewSamples() {
        let p = NosePointer()
        #expect(!p.fit(Array(samples().prefix(4))))
        #expect(!p.isCalibrated)
    }

    @Test func rejectsDegenerateSamples() {
        let p = NosePointer()
        let sameYaw = samples().map { CalibrationSample(yaw: 0.1, pitch: $0.pitch, target: $0.target) }
        #expect(!p.fit(sameYaw))
        let collinear = samples().map { CalibrationSample(yaw: $0.pitch * 2, pitch: $0.pitch, target: $0.target) }
        #expect(!p.fit(collinear))
        let sameTarget = samples().map { CalibrationSample(yaw: $0.yaw, pitch: $0.pitch, target: CGPoint(x: 5, y: 5)) }
        #expect(!p.fit(sameTarget))
        #expect(!p.isCalibrated)
    }

    @Test func failedRefitKeepsOldModel() {
        let p = NosePointer()
        #expect(p.fit(samples()))
        #expect(!p.fit([]))
        #expect(p.isCalibrated)
    }

    @Test func filteredPointStartsAtRawAndHoldsSteady() {
        let p = NosePointer()
        _ = p.fit(samples())
        let first = p.point(for: head(0.05, 0.02, t: 0))!
        let raw = p.raw(for: head(0.05, 0.02))!
        #expect(abs(first.x - raw.x) < 1e-6 && abs(first.y - raw.y) < 1e-6)
        var last = first
        for i in 1...60 { last = p.point(for: head(0.05, 0.02, t: Double(i) / 30))! }
        #expect(abs(last.x - raw.x) < 1e-6)
    }

    @Test func filterReducesJitter() {
        let p = NosePointer()
        _ = p.fit(samples())
        var rng = SystemRandomNumberGenerator()
        var rawXs: [Double] = [], filtered: [Double] = []
        for i in 0..<150 {
            let h = head(0.05 + Double.random(in: -0.004...0.004, using: &rng), 0.02, t: Double(i) / 30)
            rawXs.append(Double(p.raw(for: h)!.x))
            filtered.append(Double(p.point(for: h)!.x))
        }
        func spread(_ v: [Double]) -> Double {
            let m = v.reduce(0, +) / Double(v.count)
            return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
        }
        #expect(spread(Array(filtered.dropFirst(30))) < spread(Array(rawXs.dropFirst(30))) * 0.6)
    }

    @Test func filterFollowsFastMovement() {
        let p = NosePointer()
        _ = p.fit(samples())
        _ = p.point(for: head(-0.2, 0, t: 0))
        var last = CGPoint.zero
        for i in 1...12 { last = p.point(for: head(0.2, 0, t: Double(i) / 30))! }
        let target = p.raw(for: head(0.2, 0))!
        let start = p.raw(for: head(-0.2, 0))!
        #expect(abs(last.x - target.x) < abs(target.x - start.x) * 0.25)
    }

    @Test func resetFilterRestartsFromNextSample() {
        let p = NosePointer()
        _ = p.fit(samples())
        _ = p.point(for: head(-0.2, 0, t: 0))
        p.resetFilter()
        let r = p.raw(for: head(0.2, 0))!
        let f = p.point(for: head(0.2, 0, t: 0.033))!
        #expect(abs(f.x - r.x) < 1e-6)
    }

    @Test func calibrationRoundTrips() throws {
        let a = NosePointer()
        _ = a.fit(samples())
        let data = try #require(a.calibration)
        let b = NosePointer()
        b.calibration = data
        #expect(b.isCalibrated)
        let h = head(-0.1, 0.07)
        #expect(a.raw(for: h) == b.raw(for: h))
        b.calibration = Data("not json".utf8)
        #expect(!b.isCalibrated)
    }
}

@Suite struct OneEuroFilterTests {
    @Test func firstSamplePassesThrough() {
        var f = OneEuroFilter()
        #expect(f.filter(3.5, at: 0) == 3.5)
    }

    @Test func slowSignalIsSmoothedFastSignalIsFollowed() {
        var slow = OneEuroFilter(minCutoff: 0.6, beta: 3, dCutoff: 1)
        _ = slow.filter(0, at: 0)
        let slowStep = slow.filter(0.01, at: 1 / 30)
        #expect(slowStep < 0.005)

        var fast = OneEuroFilter(minCutoff: 0.6, beta: 3, dCutoff: 1)
        _ = fast.filter(0, at: 0)
        var out = 0.0
        for i in 1...10 { out = fast.filter(1, at: Double(i) / 30) }
        #expect(out > 0.8)
    }

    @Test func ignoresNonAdvancingTime() {
        var f = OneEuroFilter()
        _ = f.filter(1, at: 1)
        #expect(f.filter(5, at: 1) == 1)
    }

    @Test func resetForgetsHistory() {
        var f = OneEuroFilter()
        _ = f.filter(1, at: 0)
        _ = f.filter(1, at: 0.1)
        f.reset()
        #expect(f.filter(9, at: 0.2) == 9)
    }
}
