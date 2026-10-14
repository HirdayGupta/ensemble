import Testing
@testable import ClutchCore

extension GestureMapping {
    /// The original hold-a-fist mapping, used by the rule and fixture tests written for it.
    static var holdFist: GestureMapping { var m = GestureMapping(); m.talk = .fist; m.scrollUp = .pointUp; m.scrollDown = .pointDown; return m }
}

@Suite struct GatherBloomTests {
    private func sim() -> GestureSim { GestureSim(mapping: GestureMapping(), style: .gatherBloom) }

    @Test func gatherStartsAndOpeningAfterwardDoesNotStop() {
        let s = sim()
        s.hold(.openPalm, for: 0.5)
        s.hold(.gather, for: 0.5)
        #expect(s.count(.talkBegan) == 1)
        s.hold(.openPalm, for: 1)          // relaxing the hand right after starting
        s.absent(for: 5)                    // hand dropped out of view while speaking
        #expect(s.machine.talking)
        #expect(s.count(.talkEnded(.released)) == 0)
        #expect(s.count(.talkEnded(.handLost)) == 0)
    }

    @Test func gatherThenBloomStops() {
        let s = sim()
        s.hold(.openPalm, for: 0.5)
        s.hold(.gather, for: 0.5)
        s.absent(for: 3)
        s.hold(.gather, for: 0.5)          // come back gathered...
        let cancelsBefore = s.count(.cancelRequested)
        s.hold(.openPalm, for: 0.6)        // ...and bloom
        #expect(s.count(.talkEnded(.released)) == 1)
        #expect(!s.machine.talking)
        #expect(s.count(.cancelRequested) == cancelsBefore)   // the bloom is not also a cancel
    }

    @Test func bloomWithoutAFreshGatherDoesNotStop() {
        let s = sim()
        s.hold(.openPalm, for: 0.5)
        s.hold(.gather, for: 0.5)
        s.absent(for: 2)
        s.hold(.openPalm, for: 2)
        #expect(s.machine.talking)
    }

    @Test func gatherArrivingClosedDoesNotStart() {
        let s = sim()
        s.absent(for: 2)
        s.hold(.gather, for: 1)
        #expect(s.count(.talkBegan) == 0)
    }

    @Test func thumbsUpWhileTalkingStopsThenSendsAfterTheFullHold() {
        let s = sim()
        s.hold(.openPalm, for: 0.5)
        s.hold(.gather, for: 0.5)
        s.absent(for: 2)
        s.hold(.thumbsUp, for: 2)
        #expect(s.count(.talkEnded(.released)) == 1)
        #expect(s.count(.sendRequested) == 1)
    }
}
