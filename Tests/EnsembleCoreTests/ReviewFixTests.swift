import CoreGraphics
import Testing
@testable import EnsembleCore

@Suite struct ReviewFixTests {
    private func sim() -> GestureSim { GestureSim(mapping: GestureMapping()) }

    @Test func abortedTalkLetsTheNextDoubleTapStartAgain() {
        let s = sim()
        s.pinch(0.6, for: 0.5)
        s.tap(); s.tap()
        #expect(s.count(.talkBegan) == 1)
        s.machine.abortTalk()
        #expect(!s.machine.talking)
        s.pinch(0.6, for: 1)
        s.tap(); s.tap()
        #expect(s.count(.talkBegan) == 2)
        #expect(s.count(.talkEnded(.released)) == 0)
    }

    @Test func abortedTalkEmitsNothingAndDropsAHalfFinishedTap() {
        let s = sim()
        s.pinch(0.6, for: 0.5)
        s.tap()
        s.machine.abortTalk()
        #expect(!s.machine.awaitingSecondTap)
        s.tap()
        #expect(s.count(.talkBegan) == 0)
    }

    @Test func resetClearsAPinchDragInProgress() {
        let s = sim()
        s.pinch(0.6, for: 0.3)
        s.pinch(0.04, for: 0.2)
        for i in 0..<10 {
            _ = s.machine.push(HandObservation(t: s.t, present: true, pose: nil, palmCenter: CGPoint(x: 0.5, y: 0.5 + 0.03 * Double(i)), pinch: 0.04))
            s.t += 1 / s.fps
        }
        #expect(s.machine.isDragging)
        s.machine.reset()
        #expect(!s.machine.isDragging)
    }

    @Test func resetForgetsTheToggleCooldown() {
        let s = sim()
        s.pinch(0.6, for: 0.5)
        s.tap(); s.tap()
        #expect(s.count(.talkBegan) == 1)
        s.machine.reset()
        s.pinch(0.6, for: 0.5)
        s.tap(); s.tap()
        #expect(s.count(.talkBegan) == 2)
    }
}
