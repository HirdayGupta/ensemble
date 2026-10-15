import Testing
@testable import EnsembleCore

@Suite struct DictationAudioTests {
    @Test func mediaIsPausedBeforeTheMicrophoneAndTheSoundComesLast() {
        #expect(DictationAudio.startSteps(pauseMedia: true, mediaPlayingOnSpeakers: true, sound: true)
                == [.pauseOtherMedia, .pressMicrophone, .startSound])
    }

    @Test func nothingSilencingRunsBetweenThePressAndTheSound() {
        for pause in [true, false] {
            for playing in [true, false] {
                let steps = DictationAudio.startSteps(pauseMedia: pause, mediaPlayingOnSpeakers: playing, sound: true)
                let press = steps.firstIndex(of: .pressMicrophone)!
                #expect(steps.last == .startSound)
                #expect(!steps[press...].contains(.pauseOtherMedia))
            }
        }
    }

    @Test func nothingIsPausedWhenNothingPlaysOrTheSettingIsOff() {
        #expect(DictationAudio.startSteps(pauseMedia: true, mediaPlayingOnSpeakers: false, sound: true) == [.pressMicrophone, .startSound])
        #expect(DictationAudio.startSteps(pauseMedia: false, mediaPlayingOnSpeakers: true, sound: true) == [.pressMicrophone, .startSound])
        #expect(DictationAudio.startSteps(pauseMedia: true, mediaPlayingOnSpeakers: true, sound: false) == [.pauseOtherMedia, .pressMicrophone])
    }

    @Test func theSoundIsDueOnceTheMicrophoneIsConfirmedOn() {
        #expect(DictationAudio.startSoundDue(after: .keepListening, soundsOn: true))
        #expect(DictationAudio.startSoundDue(after: .stopReleased, soundsOn: true))
        #expect(!DictationAudio.startSoundDue(after: .stopSwitchedOff, soundsOn: true))
        #expect(!DictationAudio.startSoundDue(after: .notStarted, soundsOn: true))
    }

    @Test func thePlaySoundsSettingSilencesIt() {
        #expect(!DictationAudio.startSoundDue(after: .keepListening, soundsOn: false))
    }

    @Test func claudesOwnSoundIsNeverDoubled() {
        #expect(!DictationAudio.ensemblePlays(claudeOutputsBefore: 0, claudeOutputsAfter: 1))
    }

    @Test func aRiseWhileClaudeAlreadyPlaysIsClaudesSoundToo() {
        // Claude was already sending audio before the press: a rise after it is still its own sound.
        #expect(!DictationAudio.ensemblePlays(claudeOutputsBefore: 1, claudeOutputsAfter: 2))
    }

    @Test func ensemblePlaysWhenClaudeOutputDoesNotRiseOrCannotBeTold() {
        #expect(DictationAudio.ensemblePlays(claudeOutputsBefore: 0, claudeOutputsAfter: 0))
        #expect(DictationAudio.ensemblePlays(claudeOutputsBefore: 1, claudeOutputsAfter: 1))
        #expect(DictationAudio.ensemblePlays(claudeOutputsBefore: 2, claudeOutputsAfter: 1))
        #expect(DictationAudio.ensemblePlays(claudeOutputsBefore: nil, claudeOutputsAfter: 1))
        #expect(DictationAudio.ensemblePlays(claudeOutputsBefore: 0, claudeOutputsAfter: nil))
    }

    @Test func theSoundWaitsForTheCheckAndABluetoothProfileSwitch() {
        #expect(DictationAudio.soundDelay(outputIsBluetooth: false) == DictationAudio.claudeSoundWindow)
        #expect(DictationAudio.soundDelay(outputIsBluetooth: true) == DictationAudio.bluetoothDelay)
        #expect(DictationAudio.claudeSoundWindow <= DictationAudio.bluetoothDelay)
        #expect(DictationAudio.bluetoothDelay < 0.5)
    }
}
