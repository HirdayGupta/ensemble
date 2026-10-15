import Testing
@testable import EnsembleCore

@Suite struct UpdatePolicyTests {
    @Test func checksHourly() {
        #expect(UpdatePolicy.checkInterval == 3600)
    }

    @Test func checksAtLaunchOnlyWhenTurnedOnAndSetUp() {
        #expect(UpdatePolicy.checksAtLaunch(configured: true, automatic: true))
        #expect(!UpdatePolicy.checksAtLaunch(configured: true, automatic: false))
        #expect(!UpdatePolicy.checksAtLaunch(configured: false, automatic: true))
    }

    @Test func buttonOffersTheNewVersion() {
        #expect(UpdatePolicy.buttonTitle(available: "0.2.11", showingUpToDate: false) == "Update to 0.2.11")
        #expect(UpdatePolicy.buttonTitle(available: "0.2.11", showingUpToDate: true) == "Update to 0.2.11")
    }

    @Test func buttonSaysUpToDateBrieflyThenChecks() {
        #expect(UpdatePolicy.buttonTitle(available: nil, showingUpToDate: true) == "Up to date")
        #expect(UpdatePolicy.buttonTitle(available: nil, showingUpToDate: false) == "Check for Updates")
    }
}
