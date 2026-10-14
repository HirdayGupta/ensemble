import Foundation
import Testing
@testable import EnsembleCore

struct FrameRatePlannerTests {
    /// Runs a 30 fps camera for `seconds` and counts what ran. `face` says whether a face is seen on every frame.
    private func simulate(_ p: inout FrameRatePlanner, from t0: TimeInterval = 0, seconds: Double, face: Bool, force: Bool = false,
                          hand: (TimeInterval) -> Bool = { _ in false }) -> (hand: Int, face: Int, light: Int) {
        var counts = (hand: 0, face: 0, light: 0)
        var lastFace: TimeInterval? = face ? t0 : nil
        let frames = Int(seconds * 30)
        for i in 0..<frames {
            let t = t0 + Double(i) / 30
            if face { lastFace = t }
            let plan = p.plan(now: t, forceFull: force, lastFaceSeenAt: lastFace)
            if plan.runHand { counts.hand += 1; p.noteHand(present: hand(t), at: t) }
            if plan.runFace { counts.face += 1 }
            if plan.runLight { counts.light += 1 }
        }
        return counts
    }

    @Test func facePresentNoHandProbesHandAtAboutEightHz() {
        var p = FrameRatePlanner()
        let c = simulate(&p, seconds: 10, face: true)
        #expect((70...95).contains(c.hand))        // ~8 Hz, quantized to camera frames
        #expect((145...155).contains(c.face))      // ~15 Hz: every second frame
        #expect((95...105).contains(c.light))      // ~10 Hz
    }

    @Test func handInViewRunsEveryFrameAndHoldsAfterItLeaves() {
        var p = FrameRatePlanner()
        _ = simulate(&p, seconds: 2, face: true)
        // Hand appears at t = 2 s and stays 2 s: found by the next probe, then every frame.
        let during = simulate(&p, from: 2, seconds: 2, face: true, hand: { _ in true })
        #expect(during.hand >= 2 * 30 - 4)
        // Hand gone at t = 4 s: still full rate for the 1 s hold, then back to the probe.
        let after = simulate(&p, from: 4, seconds: 1, face: true)
        #expect(after.hand >= 28)
        let later = simulate(&p, from: 5, seconds: 5, face: true)
        #expect(later.hand <= 5 * 8 + 5)
    }

    @Test func forcedFullKeepsEveryHandFrameWithoutAHand() {
        var p = FrameRatePlanner()
        let c = simulate(&p, seconds: 5, face: true, force: true)
        #expect(c.hand == 150)
    }

    @Test func noFaceForSecondsDropsBothToAboutTwoHz() {
        var p = FrameRatePlanner()
        _ = simulate(&p, seconds: 1, face: true)
        _ = simulate(&p, from: 1, seconds: 3, face: false)           // the 3 s grace
        let idle = simulate(&p, from: 4, seconds: 10, face: false)
        #expect((18...25).contains(idle.hand))
        #expect((18...25).contains(idle.face))
    }

    @Test func forcedFullCancelsTheIdleSlowdown() {
        var p = FrameRatePlanner()
        _ = simulate(&p, seconds: 8, face: false)
        let c = simulate(&p, from: 8, seconds: 3, face: false, force: true)
        #expect(c.hand == 90)
        #expect((43...47).contains(c.face))
    }

    @Test func aFaceReturningRestoresFullRateWithinOneFrame() {
        var p = FrameRatePlanner()
        _ = simulate(&p, seconds: 10, face: false)
        let plan = p.plan(now: 10.2, forceFull: false, lastFaceSeenAt: 10.2)
        #expect(plan.runFace)
        #expect(plan.runHand)
        let next = p.plan(now: 10.2 + 1.0 / 30, forceFull: false, lastFaceSeenAt: 10.2)
        #expect(!next.runFace)
    }

    @Test func theVeryFirstFrameRunsEverything() {
        var p = FrameRatePlanner()
        #expect(p.plan(now: 100, forceFull: false, lastFaceSeenAt: nil) == .init(runHand: true, runFace: true, runLight: true))
    }
}
