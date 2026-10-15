import Testing
@testable import EnsembleCore

@Suite("Headphone presses")
struct HeadphoneRulesTests {
    private let ok = HeadphoneConditions(settingOn: true, outputIsBluetooth: true, claudeRunning: true, otherAudioPlaying: false)

    @Test("All four conditions are needed to claim", arguments: [
        HeadphoneConditions(settingOn: false, outputIsBluetooth: true, claudeRunning: true, otherAudioPlaying: false),
        HeadphoneConditions(settingOn: true, outputIsBluetooth: false, claudeRunning: true, otherAudioPlaying: false),
        HeadphoneConditions(settingOn: true, outputIsBluetooth: true, claudeRunning: false, otherAudioPlaying: false),
        HeadphoneConditions(settingOn: true, outputIsBluetooth: true, claudeRunning: true, otherAudioPlaying: true),
    ])
    func eachConditionBlocks(_ c: HeadphoneConditions) {
        #expect(!c.allowsClaim)
        #expect(ok.allowsClaim)
    }

    @Test("Claim waits for two quiet polls")
    func claimWaits() {
        var gate = HeadphoneClaimGate()
        #expect(gate.update(ok) == false)
        #expect(gate.update(ok) == true)
        #expect(gate.update(ok) == true)
    }

    @Test("Release is immediate when music starts, and the claim has to be earned again")
    func releaseImmediate() {
        var gate = HeadphoneClaimGate()
        _ = gate.update(ok); _ = gate.update(ok)
        var playing = ok; playing.otherAudioPlaying = true
        #expect(gate.update(playing) == false)
        #expect(gate.held == false)
        #expect(gate.update(ok) == false)
        #expect(gate.update(ok) == true)
    }

    @Test("A single blocked poll between quiet polls restarts the count")
    func blockedPollResets() {
        var gate = HeadphoneClaimGate()
        _ = gate.update(ok)
        var off = ok; off.settingOn = false
        _ = gate.update(off)
        #expect(gate.update(ok) == false)
    }

    @Test("Commands map to presses", arguments: [
        (HeadphoneCommand.togglePlayPause, HeadphoneAction.press),
        (.play, .press), (.pause, .press), (.nextTrack, .doublePress),
    ])
    func mapping(_ command: HeadphoneCommand, _ action: HeadphoneAction) {
        #expect(HeadphoneInputFilter.action(for: command) == action)
        var f = HeadphoneInputFilter()
        #expect(f.accept(command, at: 100, lastSyntheticKeyAt: -.infinity) == action)
    }

    @Test("A command right after Ensemble's own play/pause key is ignored")
    func ownKeyIgnored() {
        var f = HeadphoneInputFilter()
        #expect(f.accept(.togglePlayPause, at: 10.5, lastSyntheticKeyAt: 10) == nil)
        #expect(f.accept(.nextTrack, at: 11.4, lastSyntheticKeyAt: 10) == nil)
        #expect(f.accept(.togglePlayPause, at: 11.6, lastSyntheticKeyAt: 10) == .press)
    }

    @Test("The same action twice within a quarter second is one press")
    func duplicates() {
        var f = HeadphoneInputFilter()
        #expect(f.accept(.play, at: 5, lastSyntheticKeyAt: -.infinity) == .press)
        #expect(f.accept(.togglePlayPause, at: 5.1, lastSyntheticKeyAt: -.infinity) == nil)
        #expect(f.accept(.togglePlayPause, at: 5.4, lastSyntheticKeyAt: -.infinity) == .press)
        #expect(f.accept(.nextTrack, at: 5.45, lastSyntheticKeyAt: -.infinity) == .doublePress)
    }

    @Test("A non-finite time is dropped")
    func nonFinite() {
        var f = HeadphoneInputFilter()
        #expect(f.accept(.play, at: .nan, lastSyntheticKeyAt: -.infinity) == nil)
    }
}

@Suite("Headphone start and the gesture machine")
struct HeadphoneGestureTests {
    @Test("A start from outside puts the machine in talking, and abortTalk undoes it")
    func externalStart() {
        let m = GestureMachine()
        m.beginTalkExternally()
        #expect(m.talking)
        m.abortTalk()
        #expect(!m.talking)
    }

    @Test("A stale camera ends an externally started dictation")
    func staleEnds() {
        let m = GestureMachine()
        _ = m.push(HandObservation(t: 1, present: false, pose: nil, palmCenter: nil))
        m.beginTalkExternally()
        #expect(m.tick(now: 2.5) == [.talkEnded(.stale)])
    }
}
