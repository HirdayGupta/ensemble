import Testing
@testable import EnsembleCore

@Suite struct ScrollGlideTests {
    private func drain(_ g: inout ScrollGlide, pinchHeld: Bool = false, input: Double = 5, limit: Int = 600) -> (frames: Int, total: Double) {
        var frames = 0, total = 0.0
        while frames < limit, let step = g.nextStep(pinchHeld: pinchHeld, secondsSinceInput: input, hasTarget: true) {
            total += g.take(step)
            frames += 1
        }
        return (frames, total)
    }

    @Test func upwardStrokesCountMoreThanDownwardOnes() {
        #expect(ScrollGlide.shaped(handDy: 100) == 160)
        #expect(ScrollGlide.shaped(handDy: -100) == -100)
        #expect(ScrollGlide.shaped(handDy: 0) == 0)
    }

    @Test func flushMovesPendingDistanceOnce() {
        var g = ScrollGlide()
        do { let r = g.flush(); #expect(!r) }
        g.add(40, at: 1)
        do { let r = g.flush(); #expect(r) }
        do { let r = g.flush(); #expect(!r) }
    }

    @Test func glideDeliversTheWholeDistanceInWholePixels() {
        var g = ScrollGlide()
        g.add(300, at: 1); g.add(-20, at: 1.01)
        do { let r = g.flush(); #expect(r) }
        let (frames, total) = drain(&g)
        #expect(frames > 10 && frames < 120, "\(frames) frames")
        #expect(abs(total - 280) <= 1, "delivered \(total)")
    }

    @Test func eachFrameDeliversAFifthOfTheRemainder() throws {
        var g = ScrollGlide()
        g.add(100, at: 1); _ = g.flush()
        let first = g.nextStep(pinchHeld: false, secondsSinceInput: 5, hasTarget: true)
        let step = try #require(first)
        #expect(abs(step - 20) < 1e-9)
        let delivered = g.take(step)
        #expect(delivered == 20)
        let second = g.nextStep(pinchHeld: false, secondsSinceInput: 5, hasTarget: true)
        let next = try #require(second)
        #expect(abs(next - 16) < 1e-9)
    }

    @Test func tinyStepsStillMoveAWholePixelWithItsSign() {
        var g = ScrollGlide()
        g.add(-0.9, at: 1); _ = g.flush()
        let step = g.nextStep(pinchHeld: false, secondsSinceInput: 5, hasTarget: true)!
        #expect(g.take(step) == -1)
    }

    @Test func nothingLeftOrNoTargetStopsTheLoop() {
        var g = ScrollGlide()
        #expect(g.nextStep(pinchHeld: false, secondsSinceInput: 5, hasTarget: true) == nil)
        g.add(50, at: 1); _ = g.flush()
        #expect(g.nextStep(pinchHeld: false, secondsSinceInput: 5, hasTarget: false) == nil)
        #expect(g.nextStep(pinchHeld: false, secondsSinceInput: 5, hasTarget: true) == nil)   // the distance was dropped
    }

    @Test func fastReleaseCoastsAndSlowReleaseStopsDead() {
        var fast = ScrollGlide()
        for i in 0..<4 { fast.add(150, at: 10 + Double(i) * 0.02) }          // 600 points in 0.08 s
        #expect(fast.release(at: 10.1, canCoast: true) == 5000)
        var slow = ScrollGlide()
        slow.add(10, at: 10)
        #expect(slow.release(at: 10.05, canCoast: true) == nil)
        #expect(slow.inertia == 0)
    }

    @Test func outputOlderThanTheWindowDoesNotCount() {
        var g = ScrollGlide()
        for i in 0..<4 { g.add(150, at: 10 + Double(i) * 0.02) }
        #expect(g.release(at: 10.3, canCoast: true) == nil)
    }

    @Test func flickIsCappedAndNeedsATargetToCoast() {
        var g = ScrollGlide()
        g.add(5000, at: 10)
        #expect(g.release(at: 10.05, canCoast: true) == 15000)
        var none = ScrollGlide()
        none.add(5000, at: 10)
        #expect(none.release(at: 10.05, canCoast: false) == nil)
        #expect(none.inertia == 0)
    }

    @Test func momentumDecaysAndEventuallyStops() {
        var g = ScrollGlide()
        g.add(1000, at: 10)
        #expect(g.release(at: 10.05, canCoast: true) == 8333.333333333334)
        let (frames, total) = drain(&g)
        #expect(frames > 60 && frames < 600, "\(frames) frames")
        #expect(total > 500)
        #expect(g.inertia == 0)
    }

    @Test func aHeldPinchOrTheKeyboardStopsMomentum() {
        for (held, input) in [(true, 5.0), (false, 0.1)] {
            var g = ScrollGlide()
            g.add(5000, at: 10)
            _ = g.release(at: 10.05, canCoast: true)
            #expect(g.nextStep(pinchHeld: held, secondsSinceInput: input, hasTarget: true) == nil)
            #expect(g.inertia == 0)
        }
    }

    @Test func aNewDragCatchesTheCoastingPage() {
        var g = ScrollGlide()
        g.add(5000, at: 10)
        _ = g.release(at: 10.05, canCoast: true)
        g.catchPage()
        #expect(g.inertia == 0)
    }

    @Test func resetDropsEverything() {
        var g = ScrollGlide()
        g.add(500, at: 10); _ = g.flush()
        g.add(500, at: 10.01)
        g.reset()
        do { let r = g.flush(); #expect(!r) }
        #expect(g.nextStep(pinchHeld: false, secondsSinceInput: 5, hasTarget: true) == nil)
    }
}
