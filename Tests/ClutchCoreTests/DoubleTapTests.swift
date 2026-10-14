import CoreGraphics
import Testing
@testable import ClutchCore

@Suite struct DoubleTapTests {
    private func sim() -> GestureSim { GestureSim(mapping: GestureMapping(), style: .doubleTap) }

    @Test func doubleTapStartsAndAnotherStops() {
        let s = sim()
        s.pinch(0.6, for: 0.5)
        s.tap(); s.tap()
        #expect(s.count(.talkBegan) == 1)
        s.absent(for: 5)                          // hand away while talking: keeps listening
        #expect(s.machine.talking)
        s.pinch(0.6, for: 1)
        s.tap(); s.tap()
        #expect(s.count(.talkEnded(.released)) == 1)
        #expect(!s.machine.talking)
    }

    @Test func singleTapDoesNothing() {
        let s = sim()
        s.pinch(0.6, for: 0.5)
        s.tap()
        s.pinch(0.6, for: 2)
        #expect(s.count(.talkBegan) == 0)
    }

    @Test func tapsTooFarApartDoNothing() {
        let s = sim()
        s.tap(); s.pinch(0.6, for: 1.6); s.tap()
        #expect(s.count(.talkBegan) == 0)
    }

    @Test func heldPinchIsNotATap() {
        let s = sim()
        s.tap(closedFor: 2.5); s.tap(closedFor: 2.5)
        #expect(s.count(.talkBegan) == 0)
    }

    @Test func slowPinchesStillCount() {
        let s = sim()
        s.pinch(0.6, for: 0.5)
        s.tap(closedFor: 1.4); s.tap(closedFor: 1.4)
        #expect(s.count(.talkBegan) == 1)
    }

    @Test func oneFrameSpikeInsideAHeldPinchIsNotATap() {
        let s = sim()
        s.pinch(0.2, for: 0.2)
        s.pinch(0.07, for: 0.5); s.pinch(0.3, for: 1.0 / 30); s.pinch(0.07, for: 0.5)
        s.pinch(0.2, for: 1)
        #expect(s.count(.talkBegan) == 0)
    }

    @Test func tapsMoreThanTheGapApartReset() {
        let s = sim()
        s.pinch(0.6, for: 0.5)
        s.tap(); s.pinch(0.2, for: 1.4); s.tap()
        #expect(s.count(.talkBegan) == 0)
    }

    /// 2026-10-14: lowering a thumbs-up after a send brushed thumb and index together twice and started dictation.
    @Test func loweringAThumbsUpIsNotADoubleTap() {
        let s = sim()
        s.pinch(0.6, for: 1.0, pose: .thumbsUp)
        s.tap(); s.tap()
        #expect(s.count(.talkBegan) == 0)
        s.pinch(0.6, for: 1.5)
        s.tap(); s.tap()
        #expect(s.count(.talkBegan) == 1)
    }

    /// 2026-10-14: a pinch made as the hand came up was swallowed, so a deliberate pair needed a third pinch.
    @Test func pinchAsTheHandArrivesCounts() {
        let s = sim()
        s.absent(for: 1)
        s.pinch(0.04, for: 0.15); s.pinch(0.2, for: 0.1); s.tap()
        #expect(s.count(.talkBegan) == 1)
    }

    /// Akshay's natural rhythm: about a second between letting go and the next touch.
    @Test func slowRhythmPairCounts() {
        let s = sim()
        s.pinch(0.6, for: 0.5)
        s.tap(closedFor: 0.35); s.pinch(0.2, for: 1.0); s.tap(closedFor: 0.35)
        #expect(s.count(.talkBegan) == 1)
    }

    @Test func tripleTapTogglesOnlyOnce() {
        let s = sim()
        s.tap(); s.tap(); s.tap()
        s.pinch(0.6, for: 1)
        #expect(s.count(.talkBegan) == 1)
        #expect(s.count(.talkEnded(.released)) == 0)
    }
}

@Suite struct DoubleTapOnTouchTests {
    @Test func secondPinchActsOnTouchEvenIfHeld() {
        let s = GestureSim(mapping: GestureMapping(), style: .doubleTap)
        s.pinch(0.6, for: 0.5)
        s.tap()
        s.pinch(0.2, for: 0.1)
        s.pinch(0.04, for: 0.1)                 // second pinch just touched
        #expect(s.count(.talkBegan) == 1)
        s.pinch(0.04, for: 3)                   // and is held
        s.pinch(0.2, for: 0.5)
        #expect(s.count(.talkBegan) == 1)
        #expect(s.machine.talking)
    }
}

@Suite struct DoubleTapExpiryTests {
    @Test func halfwayStateExpiresAfterTheGap() {
        let s = GestureSim(mapping: GestureMapping(), style: .doubleTap)
        s.pinch(0.6, for: 0.5)
        s.tap()
        #expect(s.machine.awaitingSecondTap)
        s.pinch(0.2, for: 1.5)
        #expect(!s.machine.awaitingSecondTap)
        #expect(s.machine.progress == nil)
    }
}

@Suite struct PinchArcScrollTests {
    @Test func anArcScrollsByDistanceTravelled() {
        let m = GestureMachine(mapping: GestureMapping()); m.talkStyle = .doubleTap
        var t = 10.0, total = 0.0
        func push(_ x: Double, _ y: Double, _ pinch: Double) {
            for i in m.push(HandObservation(t: t, present: true, pose: nil, palmCenter: CGPoint(x: x, y: y), pinch: pinch)) {
                if case .dragScroll(let d) = i { total += d }
            }
            t += 1.0 / 30
        }
        push(0.5, 0.5, 0.2); push(0.5, 0.5, 0.2)
        for _ in 0..<5 { push(0.5, 0.5, 0.04) }            // pinch closes
        // A quarter arc: mostly sideways at first, upward at the end. Vertical rise is 0.1; path is about 0.16.
        for k in 1...30 {
            let a = Double(k) / 30 * Double.pi / 2
            push(0.5 + 0.1 * (1 - cos(a)) + 0.0, 0.5 + 0.1 * sin(a), 0.04)
        }
        #expect(total > 0.1 * GestureMachine.dragPointsPerFrameHeight)   // more than the vertical rise alone gives
    }
}

@Suite struct PinchScrollDirectionTests {
    private func run(_ path: [(Double, Double)]) -> [Double] {
        let m = GestureMachine(mapping: GestureMapping()); m.talkStyle = .doubleTap
        var t = 10.0, out: [Double] = []
        func push(_ x: Double, _ y: Double, _ pinch: Double) {
            for i in m.push(HandObservation(t: t, present: true, pose: nil, palmCenter: CGPoint(x: x, y: y), pinch: pinch)) {
                if case .dragScroll(let d) = i { out.append(d) }
            }
            t += 1.0 / 30
        }
        push(0.5, 0.5, 0.2); push(0.5, 0.5, 0.2)
        for _ in 0..<5 { push(0.5, 0.5, 0.04) }
        for (x, y) in path { push(x, y, 0.04) }
        return out
    }

    @Test func jitteryUpwardStrokeNeverScrollsTheOtherWay() {
        var path: [(Double, Double)] = []
        for k in 1...40 { path.append((0.5 + (k % 2 == 0 ? 0.01 : -0.01), 0.5 + Double(k) * 0.004 + (k % 3 == 0 ? -0.006 : 0))) }
        let out = run(path)
        #expect(out.reduce(0, +) > 0)                                   // net: upward
        let up: Double = out.filter { $0 > 0 }.reduce(0, +)
        let down: Double = -out.filter { $0 < 0 }.reduce(0, +)
        #expect(up > 3 * down)
    }

    @Test func upThenDownPastTheStartEndsBelowWhereItBegan() {
        var path: [(Double, Double)] = []
        for k in 1...20 { path.append((0.5, 0.5 + Double(k) * 0.005)) }      // up 0.1
        for k in 1...40 { path.append((0.5, 0.6 - Double(k) * 0.005)) }      // down 0.2: 0.1 below the start
        let out = run(path)
        let total = out.reduce(0, +)
        #expect(total < 0)                                               // net displacement is downward
    }

    @Test func aClearMoveBackReverses() {
        var path: [(Double, Double)] = []
        for k in 1...20 { path.append((0.5, 0.5 + Double(k) * 0.005)) }      // up 0.1
        for k in 1...30 { path.append((0.5, 0.6 - Double(k) * 0.005)) }      // back down 0.15
        let out = run(path)
        #expect(out.first! > 0 && out.last! < 0)
    }
}

@Suite struct PinchReleaseStopsScrollTests {
    @Test func slightlyOpeningTheFingersEndsTheDragImmediately() {
        let m = GestureMachine(mapping: GestureMapping()); m.talkStyle = .doubleTap
        var t = 10.0
        var afterRelease = 0, ended = 0
        var released = false
        func push(_ y: Double, _ pinch: Double) {
            for i in m.push(HandObservation(t: t, present: true, pose: nil, palmCenter: CGPoint(x: 0.5, y: y), pinch: pinch)) {
                if case .dragScroll = i, released { afterRelease += 1 }
                if case .dragScrollEnded = i { ended += 1 }
            }
            t += 1.0 / 30
        }
        push(0.5, 0.2); push(0.5, 0.2)
        for _ in 0..<5 { push(0.5, 0.05) }
        for k in 1...20 { push(0.5 + Double(k) * 0.005, 0.05) }        // dragging up
        released = true
        for k in 1...20 { push(0.6 + Double(k) * 0.005, 0.14) }        // fingers parted a little, hand keeps moving
        #expect(ended == 1)
        #expect(afterRelease == 0)
    }
}
