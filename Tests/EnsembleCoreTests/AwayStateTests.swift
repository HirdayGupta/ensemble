import Testing
@testable import EnsembleCore

@Suite struct AwayStateTests {
    @Test func awayUntilEveryReasonIsCleared() {
        var s = AwayState()
        let started = s.set(.locked, true)
        let second = s.set(.displaySleep, true)
        #expect(started)
        #expect(!second)
        #expect(s.isAway)
        let unlocked = s.set(.locked, false)
        #expect(!unlocked)      // the display still sleeps
        #expect(s.isAway)
        let woke = s.set(.displaySleep, false)
        #expect(woke)
        #expect(!s.isAway)
    }

    @Test func aBackWithoutAGoingChangesNothing() {
        var s = AwayState()
        let changed = s.set(.systemSleep, false)
        #expect(!changed)
        #expect(!s.isAway)
    }

    @Test func reconcileClearsWhatTheFactsDisprove() {
        var s = AwayState()
        s.set(.systemSleep, true)
        s.set(.locked, true)
        // Still locked: nothing is cleared.
        let whileLocked = s.reconcile(sessionLockedOrInactive: true, displayAsleep: false, secondsSinceInput: 0)
        #expect(!whileLocked)
        #expect(s.isAway)
        // Unlocked and awake: a missed "back" no longer leaves the camera off.
        let back = s.reconcile(sessionLockedOrInactive: false, displayAsleep: false, secondsSinceInput: 100)
        #expect(back)
        #expect(!s.isAway)
    }

    @Test func theScreenSaverEndsOnlyWithInputOrItsOwnNotification() {
        var s = AwayState()
        s.set(.screenSaver, true)
        let idle = s.reconcile(sessionLockedOrInactive: false, displayAsleep: false, secondsSinceInput: 60)
        #expect(!idle)
        #expect(s.isAway)
        let typed = s.reconcile(sessionLockedOrInactive: false, displayAsleep: false, secondsSinceInput: 0.5)
        #expect(typed)
        #expect(!s.isAway)
    }

    @Test func aSleepingDisplayKeepsEverything() {
        var s = AwayState()
        s.set(.displaySleep, true)
        let asleep = s.reconcile(sessionLockedOrInactive: false, displayAsleep: true, secondsSinceInput: 0)
        #expect(!asleep)
        #expect(s.isAway)
    }
}
