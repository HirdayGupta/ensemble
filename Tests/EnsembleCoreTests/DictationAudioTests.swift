import Testing
@testable import EnsembleCore

@Suite struct DictationAudioTests {
    @Test func mediaIsPausedBeforeTheMicrophoneAndTheCueComesLast() {
        #expect(DictationAudio.startSteps(pauseMedia: true, mediaPlayingOnSpeakers: true, cue: true)
                == [.pauseOtherMedia, .pressMicrophone, .startCue])
    }

    @Test func nothingSilencingRunsBetweenThePressAndTheCue() {
        for pause in [true, false] {
            for playing in [true, false] {
                let steps = DictationAudio.startSteps(pauseMedia: pause, mediaPlayingOnSpeakers: playing, cue: true)
                let press = steps.firstIndex(of: .pressMicrophone)!
                #expect(steps.last == .startCue)
                #expect(!steps[press...].contains(.pauseOtherMedia))
            }
        }
    }

    @Test func nothingIsPausedWhenNothingPlaysOrTheSettingIsOff() {
        #expect(DictationAudio.startSteps(pauseMedia: true, mediaPlayingOnSpeakers: false, cue: true) == [.pressMicrophone, .startCue])
        #expect(DictationAudio.startSteps(pauseMedia: false, mediaPlayingOnSpeakers: true, cue: true) == [.pressMicrophone, .startCue])
        #expect(DictationAudio.startSteps(pauseMedia: true, mediaPlayingOnSpeakers: true, cue: false) == [.pauseOtherMedia, .pressMicrophone])
    }

    @Test func theCuePlaysOnceTheMicrophoneIsConfirmedOn() {
        #expect(DictationAudio.startCue(after: .keepListening, soundsOn: true))
        #expect(DictationAudio.startCue(after: .stopReleased, soundsOn: true))
        #expect(!DictationAudio.startCue(after: .stopSwitchedOff, soundsOn: true))
        #expect(!DictationAudio.startCue(after: .notStarted, soundsOn: true))
    }

    @Test func theSoundsSettingSilencesTheCue() {
        #expect(!DictationAudio.startCue(after: .keepListening, soundsOn: false))
    }

    @Test func claudesOwnToneIsNeverDoubled() {
        #expect(!DictationAudio.claudePlaysStartTone)
        #expect(!DictationAudio.startCue(after: .keepListening, soundsOn: true, claudeTone: true))
    }

    @Test func theCueWaitsOutABluetoothProfileSwitchOnly() {
        #expect(DictationAudio.startCueDelay(outputIsBluetooth: false) == 0)
        #expect(DictationAudio.startCueDelay(outputIsBluetooth: true) == DictationAudio.bluetoothCueDelay)
        #expect(DictationAudio.bluetoothCueDelay < 0.5)
    }
}
