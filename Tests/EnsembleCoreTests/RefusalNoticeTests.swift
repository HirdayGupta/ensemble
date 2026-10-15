import Testing
@testable import EnsembleCore

@Suite struct RefusalNoticeTests {
    private let quiet = -Double.infinity

    @Test func staysWhileNothingChanged() {
        let n = RefusalNotice(text: "No face in view", shownAt: 10)
        #expect(!n.isStale(now: 12, lastInputAt: quiet, dictating: false, onSession: false))
    }

    @Test func expiresAfterItsLifetime() {
        let n = RefusalNotice(text: "No face in view", shownAt: 10)
        #expect(!n.isStale(now: 10 + RefusalNotice.lifetime - 0.1, lastInputAt: quiet, dictating: false, onSession: false))
        #expect(n.isStale(now: 10 + RefusalNotice.lifetime, lastInputAt: quiet, dictating: false, onSession: false))
    }

    @Test func dictationStartingClearsIt() {
        let n = RefusalNotice(text: "No face in view", shownAt: 10)
        #expect(n.isStale(now: 11, lastInputAt: quiet, dictating: true, onSession: false))
    }

    @Test func typingAfterTheRefusalClearsIt() {
        let n = RefusalNotice(text: "Your nose is not on a Claude session", shownAt: 10, resolves: .whenOnSession)
        #expect(n.isStale(now: 11, lastInputAt: 10.8, dictating: false, onSession: false))
    }

    @Test func theInputThatCausedTheRefusalDoesNotClearIt() {
        let n = RefusalNotice(text: "You just typed or clicked", shownAt: 10)
        #expect(!n.isStale(now: 11, lastInputAt: 9.8, dictating: false, onSession: false))
        #expect(!n.isStale(now: 11, lastInputAt: 10.2, dictating: false, onSession: false))
    }

    @Test func noseBackOnASessionClearsAPointingRefusal() {
        let n = RefusalNotice(text: "Your nose is not on a Claude session", shownAt: 10, resolves: .whenOnSession)
        #expect(!n.isStale(now: 11, lastInputAt: quiet, dictating: false, onSession: false))
        #expect(n.isStale(now: 11, lastInputAt: quiet, dictating: false, onSession: true))
    }

    @Test func noseOnASessionLeavesOtherRefusals() {
        let n = RefusalNotice(text: "Send is off in Settings", shownAt: 10)
        #expect(!n.isStale(now: 11, lastInputAt: quiet, dictating: false, onSession: true))
    }
}
