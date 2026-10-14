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
        s.tap(); s.pinch(0.6, for: 1.2); s.tap()
        #expect(s.count(.talkBegan) == 0)
    }

    @Test func heldPinchIsNotATap() {
        let s = sim()
        s.tap(closedFor: 2.5); s.tap(closedFor: 2.5)
        #expect(s.count(.talkBegan) == 0)
    }

    @Test func slowPinchesStillCount() {
        let s = sim()
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
