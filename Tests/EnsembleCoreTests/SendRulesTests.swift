import Testing
@testable import EnsembleCore

@Suite struct SendRulesTests {
    @Test func nothingDictatedRefuses() {
        #expect(SendRules.refusal(spokenAgo: nil, inputAge: 100) == "Nothing dictated in the last 30 seconds")
    }

    @Test func theWindowIsThirtySeconds() {
        #expect(SendRules.refusal(spokenAgo: 30, inputAge: 100) == nil)
        #expect(SendRules.refusal(spokenAgo: 30.5, inputAge: 100) == "Nothing dictated in the last 30 seconds")
    }

    @Test func inputSinceDictationRefuses() {
        #expect(SendRules.refusal(spokenAgo: 10, inputAge: 4) == "Typed or clicked since dictation; not sending")
        #expect(SendRules.refusal(spokenAgo: 10, inputAge: 10) == nil)
        #expect(SendRules.typedRefusal(spokenAgo: 10, inputAge: 9.9) != nil)
        #expect(SendRules.typedRefusal(spokenAgo: 10, inputAge: 10.1) == nil)
        #expect(SendRules.typedRefusal(spokenAgo: 40, inputAge: 5) != nil)     // the window is not this check's business
    }
}
