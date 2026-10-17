import Testing
@testable import EnsembleCore

@Suite struct GrantRelaunchTests {
    @Test func aCopyThatStartedWithoutTheGrantRelaunchesWhenItArrives() {
        var rule = GrantRelaunch(startedWithGrant: false)
        #expect(rule.shouldRelaunch(granted: false) == false)
        #expect(rule.shouldRelaunch(granted: true))
    }

    @Test func itRelaunchesOnlyOnce() {
        var rule = GrantRelaunch(startedWithGrant: false)
        #expect(rule.shouldRelaunch(granted: true))
        #expect(rule.shouldRelaunch(granted: true) == false)
    }

    @Test func aCopyThatStartedWithTheGrantNeverRelaunches() {
        var rule = GrantRelaunch(startedWithGrant: true)
        #expect(rule.shouldRelaunch(granted: true) == false)
        #expect(rule.shouldRelaunch(granted: false) == false)
        #expect(rule.shouldRelaunch(granted: true) == false)
    }

    @Test func aGrantThatNeverArrivesNeverRelaunches() {
        var rule = GrantRelaunch(startedWithGrant: false)
        for _ in 0..<100 { #expect(rule.shouldRelaunch(granted: false) == false) }
    }
}
