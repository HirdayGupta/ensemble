import Foundation
import Testing
@testable import EnsembleCore

@Suite struct FaceFrameSlotTests {
    @Test func aFrameIsHandedOutOnceUnderItsNumber() {
        let slot = FaceFrameSlot()
        let n = slot.put(Data([1, 2, 3, 4]))
        #expect(slot.take(n) == Data([1, 2, 3, 4]))
        #expect(slot.take(n) == nil)
    }

    @Test func aNewerFrameReplacesOneNotYetFetched() {
        let slot = FaceFrameSlot()
        let old = slot.put(Data([1]))
        let new = slot.put(Data([2]))
        #expect(new != old)
        #expect(slot.take(old) == nil)
        #expect(slot.take(new) == Data([2]))
    }

    @Test func clearingDropsTheWaitingFrame() {
        let slot = FaceFrameSlot()
        let n = slot.put(Data([9]))
        slot.clear()
        #expect(slot.take(n) == nil)
    }

    @Test func theSentFrameIs320WideInTheCameraProportion() {
        func size(_ w: Int, _ h: Int) -> [Int] {
            let s = FaceFrameSlot.size(cameraWidth: w, cameraHeight: h)
            return [s.width, s.height]
        }
        #expect(size(640, 480) == [320, 240])
        #expect(size(1280, 720) == [320, 180])
        #expect(size(1920, 1080) == [320, 180])
        #expect(size(0, 0) == [320, 240])
        #expect(size(10_000, 1) == [320, 2])
    }

    @Test func framePathsRoundTripAndOtherPathsAreNotFrames() {
        #expect(FaceFrameSlot.number(inPath: FaceFrameSlot.path(for: 42)) == 42)
        #expect(FaceFrameSlot.number(inPath: "/head.js") == nil)
        #expect(FaceFrameSlot.number(inPath: "/frame/") == nil)
        #expect(FaceFrameSlot.number(inPath: "/frame/x") == nil)
    }
}
