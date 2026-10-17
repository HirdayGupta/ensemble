import Testing
@testable import EnsembleCore

@Suite struct GrantRelaunchTests {
    @Test func aCopyThatStartedWithoutTheGrantRelaunchesWhenItArrives() {
        var rule = GrantRelaunch(startedWithGrant: false)
        let before = rule.shouldRelaunch(granted: false)
        let after = rule.shouldRelaunch(granted: true)
        #expect(before == false)
        #expect(after)
    }

    @Test func itRelaunchesOnlyOnce() {
        var rule = GrantRelaunch(startedWithGrant: false)
        let first = rule.shouldRelaunch(granted: true)
        let second = rule.shouldRelaunch(granted: true)
        #expect(first)
        #expect(second == false)
    }

    @Test func aCopyThatStartedWithTheGrantNeverRelaunches() {
        var rule = GrantRelaunch(startedWithGrant: true)
        let readings = [true, false, true].map { rule.shouldRelaunch(granted: $0) }
        #expect(readings == [false, false, false])
    }

    @Test func aGrantThatNeverArrivesNeverRelaunches() {
        var rule = GrantRelaunch(startedWithGrant: false)
        var any = false
        for _ in 0..<100 where rule.shouldRelaunch(granted: false) { any = true }
        #expect(any == false)
    }
}
