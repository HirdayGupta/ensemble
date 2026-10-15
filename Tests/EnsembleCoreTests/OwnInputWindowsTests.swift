import Foundation
import Testing
@testable import EnsembleCore

@Suite struct OwnInputWindowsTests {
    @Test func ensemblesOwnKeysAreNotTheOwnerTyping() {
        var own = OwnInputWindows()
        own.begin(at: 100)
        own.end(at: 100.4)
        // Read at 100.5: the last key of any origin was a divider key 0.5 s ago; the owner last typed 30 s ago.
        #expect(own.ownerAge(combined: 0.5, hardware: 30, now: 100.5) == 30)
    }

    @Test func whileTheKeysRunTheyAreStillOwn() {
        var own = OwnInputWindows()
        own.begin(at: 100)
        #expect(own.ownerAge(combined: 0.1, hardware: .infinity, now: 100.2) == .infinity)
    }

    @Test func aRealKeyDuringTheResizeStillCounts() {
        var own = OwnInputWindows()
        own.begin(at: 100)
        own.end(at: 100.4)
        // The owner typed at 100.2: the hardware state saw it, so it wins even though the combined reading is ours.
        #expect(own.ownerAge(combined: 0.3, hardware: 0.3, now: 100.5) == 0.3)
    }

    @Test func aKeyAfterTheResizeCounts() {
        var own = OwnInputWindows()
        own.begin(at: 100)
        own.end(at: 100.4)
        #expect(own.ownerAge(combined: 0.2, hardware: 0.2, now: 101) == 0.2)
        // Even when the hardware state disagrees, a key outside every window is taken as read.
        #expect(own.ownerAge(combined: 0.2, hardware: 9, now: 101) == 0.2)
    }

    @Test func aKeyBeforeAnyResizeCounts() {
        let own = OwnInputWindows()
        #expect(own.ownerAge(combined: 1, hardware: 50, now: 100) == 1)
    }

    @Test func onlyTheRecentWindowsAreKept() {
        var own = OwnInputWindows()
        for i in 0..<20 { own.begin(at: Double(i)); own.end(at: Double(i) + 0.4) }
        #expect(!own.isOwn(0.2))
        #expect(own.isOwn(19.2))
    }

    @Test func nonFiniteReadingsAreTakenAsRead() {
        var own = OwnInputWindows()
        own.begin(at: .nan)
        own.begin(at: 100)
        #expect(own.ownerAge(combined: .infinity, hardware: 5, now: 100.1) == .infinity)
        #expect(!own.isOwn(.nan))
    }
}
