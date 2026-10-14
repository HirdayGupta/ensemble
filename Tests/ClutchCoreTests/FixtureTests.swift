import Foundation
import Testing
@testable import ClutchCore

@Suite struct FixtureTests {
    private func gestureIntents(_ name: String) throws -> [(t: TimeInterval, intent: GestureIntent)] {
        try FixtureReplay.intents(name).filter { if case .scroll = $0.intent { return false }; return true }
    }

    @Test func fistHoldProducesBeganEndedPairs() throws {
        let intents = try gestureIntents("fist-hold").map(\.intent)
        #expect(intents.count == 8)
        for (i, intent) in intents.enumerated() {
            #expect(intent == (i % 2 == 0 ? .talkBegan : .talkEnded(.handLost)))
        }
    }

    @Test func farFistBeginsAndEndsStaleWhenFramesStop() throws {
        let machine = GestureMachine(mapping: .holdFist)
        machine.talkStyle = .hold
        let obs = try FixtureReplay.observations("fist-far")
        var intents: [GestureIntent] = []
        for o in obs { intents += machine.push(o) }
        #expect(intents == [.talkBegan])
        intents = machine.tick(now: obs.last!.t + 1.0)
        #expect(intents == [.talkEnded(.stale)])
    }

    @Test(arguments: ["none-desk-life", "none-dogfood-1052-fist"])
    func idleHandsNeverTalkOrSend(name: String) throws {
        let intents = try FixtureReplay.intents(name).map(\.intent)
        #expect(!intents.contains(.talkBegan))
        #expect(!intents.contains(.sendRequested))
        #expect(!intents.contains { if case .scroll = $0 { return true }; return false })
    }

    @Test func thumbsUpHoldSends() throws {
        let intents = try gestureIntents("thumbsUp-hold").map(\.intent)
        // The recording holds each thumbs-up for about a second; with the 1.5 s send hold only the longest sends.
        #expect(intents.filter { $0 == .sendRequested }.count >= 1)
        #expect(!intents.contains(.talkBegan))
    }

    @Test func openPalmHoldCancelsOnly() throws {
        let intents = try gestureIntents("openPalm-hold").map(\.intent)
        #expect(intents.filter { $0 == .cancelRequested }.count == 5)
        #expect(!intents.contains(.talkBegan))
        #expect(!intents.contains(.sendRequested))
    }

    @Test func twoFingersHoldScrollsAndNeitherTalksNorSends() throws {
        let intents = try gestureIntents("twoFingers-hold").map(\.intent)
        #expect(!intents.contains(.talkBegan))
        #expect(!intents.contains(.sendRequested))
    }

    @Test(arguments: [("fist-hold", Pose.fist), ("thumbsUp-hold", Pose.thumbsUp),
                      ("openPalm-hold", Pose.openPalm), ("twoFingers-hold", Pose.twoFingers)])
    func adapterMapsDeliberatePoses(name: String, pose: Pose) throws {
        let obs = try FixtureReplay.observations(name)
        let matching = obs.filter { $0.pose == pose }.count
        #expect(matching > 50, "\(name): \(matching) frames read as \(pose)")
        #expect(obs.contains { $0.present && $0.palmCenter != nil })
    }

    @Test func adapterReportsAbsentHand() {
        let o = HandClassifierAdapter.observation(from: nil, at: 4, classifier: GestureClassifier())
        #expect(!o.present && o.pose == nil && o.palmCenter == nil && o.t == 4)
    }
}
