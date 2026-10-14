import CoreGraphics
import Foundation
import Testing
@testable import EnsembleCore

@Suite struct NonFiniteInputTests {
    @Test func filterIgnoresNaNAndInfinityAndKeepsWorking() {
        var f = OneEuroFilter()
        _ = f.filter(1, at: 0)
        let held = f.filter(1, at: 0.05)
        #expect(f.filter(.nan, at: 0.1) == held)
        #expect(f.filter(.infinity, at: 0.15) == held)
        #expect(f.filter(2, at: .nan) == held)
        let next = f.filter(2, at: 0.2)
        #expect(next.isFinite && next > 1)
    }

    @Test func pointerDropsNonFiniteHeadReadingsWithoutPoisoningTheFilter() {
        let p = NosePointer()
        let samples = [(-0.25, -0.15), (0, 0), (0.25, 0.15), (-0.25, 0.15), (0.25, -0.15), (0, 0.15)].map {
            CalibrationSample(yaw: $0.0, pitch: $0.1, target: CGPoint(x: 2400 * $0.0 + 960, y: 2000 * $0.1 + 540))
        }
        #expect(p.fit(samples))
        #expect(p.point(for: HeadObservation(t: 0, yaw: 0, pitch: 0, faceCount: 1)) != nil)
        #expect(p.point(for: HeadObservation(t: 0.05, yaw: .nan, pitch: 0, faceCount: 1)) == nil)
        #expect(p.point(for: HeadObservation(t: 0.06, yaw: 0, pitch: .infinity, faceCount: 1)) == nil)
        #expect(p.point(for: HeadObservation(t: .nan, yaw: 0, pitch: 0, faceCount: 1)) == nil)
        let after = p.point(for: HeadObservation(t: 0.1, yaw: 0.1, pitch: 0.05, faceCount: 1))
        #expect(after.map { $0.x.isFinite && $0.y.isFinite } == true)
    }

    @Test func gestureMachineTreatsNonFiniteHandReadingsAsMissing() {
        let m = GestureMachine()
        m.mapping = GestureMapping()
        var intents: [GestureIntent] = []
        var t = 0.0
        for i in 0..<30 {
            let palm = CGPoint(x: i % 2 == 0 ? Double.nan : 0.5, y: 0.5)
            intents += m.push(HandObservation(t: t, present: true, pose: nil, palmCenter: palm, pinch: i % 3 == 0 ? .nan : 0.04))
            t += 1.0 / 30
        }
        intents += m.push(HandObservation(t: .nan, present: true, pose: nil, palmCenter: nil, pinch: 0.5))
        for intent in intents {
            if case .dragScroll(let dy) = intent { #expect(dy.isFinite) }
        }
        let after = m.push(HandObservation(t: t, present: true, pose: nil, palmCenter: CGPoint(x: 0.5, y: 0.6), pinch: 0.5))
        for intent in after { if case .dragScroll(let dy) = intent { #expect(dy.isFinite) } }
    }
}
