import Foundation
import Testing
@testable import EnsembleCore

@Suite struct OwnPointerEventsTests {
    @Test func ensemblesOwnDragIsNotTheOwnersClick() {
        var own = OwnPointerEvents()
        own.begin(at: 100)
        own.end(at: 100.4)
        // Read at 100.5: the last click of any origin was the drag's press 0.5 s ago; the owner last clicked 30 s ago.
        #expect(own.ownerClickAge(combined: 0.5, hardware: 30, now: 100.5) == 30)
    }

    @Test func whileTheDragRunsItsPressIsStillOwn() {
        var own = OwnPointerEvents()
        own.begin(at: 100)
        #expect(own.ownerClickAge(combined: 0.1, hardware: .infinity, now: 100.2) == .infinity)
    }

    @Test func aRealClickDuringTheDragStillCounts() {
        var own = OwnPointerEvents()
        own.begin(at: 100)
        own.end(at: 100.4)
        // The owner clicked at 100.2: the hardware state saw it, so it wins even though the combined reading is ours.
        #expect(own.ownerClickAge(combined: 0.3, hardware: 0.3, now: 100.5) == 0.3)
    }

    @Test func aClickAfterTheDragCounts() {
        var own = OwnPointerEvents()
        own.begin(at: 100)
        own.end(at: 100.4)
        #expect(own.ownerClickAge(combined: 0.2, hardware: 0.2, now: 101) == 0.2)
        // Even when the hardware state disagrees, a click outside every window is taken as read.
        #expect(own.ownerClickAge(combined: 0.2, hardware: 9, now: 101) == 0.2)
    }

    @Test func aClickBeforeAnyDragCounts() {
        let own = OwnPointerEvents()
        #expect(own.ownerClickAge(combined: 1, hardware: 50, now: 100) == 1)
    }

    @Test func onlyTheRecentWindowsAreKept() {
        var own = OwnPointerEvents()
        for i in 0..<20 { own.begin(at: Double(i)); own.end(at: Double(i) + 0.4) }
        #expect(!own.isOwn(0.2))
        #expect(own.isOwn(19.2))
    }

    @Test func nonFiniteReadingsAreTakenAsRead() {
        var own = OwnPointerEvents()
        own.begin(at: .nan)
        own.begin(at: 100)
        #expect(own.ownerClickAge(combined: .infinity, hardware: 5, now: 100.1) == .infinity)
        #expect(!own.isOwn(.nan))
    }
}
