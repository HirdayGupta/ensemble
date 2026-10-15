import Foundation

/// What Ensemble does with sound around a dictation start. Allowlist model: Ensemble never lowers the output
/// volume, so every sound Claude or Ensemble makes plays at the owner's volume; only other apps' media is paused,
/// with the play/pause key.
///
/// Claude desktop's composer dictation plays no start sound of its own (Claude 2.37337: its renderer's dictation
/// code plays no audio, and its only sound files belong to voice mode), so Ensemble's start cue is the one heard.
public enum DictationAudio {
    public enum StartStep: Equatable, Sendable {
        /// The play/pause key for media on speakers, checked to have stopped before the microphone opens.
        case pauseOtherMedia
        case pressMicrophone
        /// Ensemble's start cue, once the microphone is confirmed on.
        case startCue
    }

    /// Set to true only once Claude is confirmed to play its own start tone, so the two never double up.
    public static let claudePlaysStartTone = false

    /// The order of a start. Media is paused before the press, so neither it nor the pause is transcribed; nothing
    /// that could silence the output comes between the press and the start cue.
    public static func startSteps(pauseMedia: Bool, mediaPlayingOnSpeakers: Bool, cue: Bool) -> [StartStep] {
        var steps: [StartStep] = []
        if pauseMedia && mediaPlayingOnSpeakers { steps.append(.pauseOtherMedia) }
        steps.append(.pressMicrophone)
        if cue { steps.append(.startCue) }
        return steps
    }

    /// The start cue plays when the microphone is confirmed on and the dictation goes on, or stops only because the
    /// hand opened during the press (that stop then has its own cue). A start stopped because Ensemble was switched
    /// off, or one never confirmed, gets no start cue.
    public static func startCue(after: DictationRules.AfterStart, soundsOn: Bool,
                                claudeTone: Bool = claudePlaysStartTone) -> Bool {
        guard soundsOn, !claudeTone else { return false }
        switch after {
        case .keepListening, .stopReleased: return true
        case .stopSwitchedOff, .notStarted: return false
        }
    }

    /// Opening a Bluetooth headset's microphone switches it to its call profile, and a sound played during the
    /// switch is dropped; the cue waits it out. Not yet measured: the owner's check by hand settles it.
    public static let bluetoothCueDelay: TimeInterval = 0.35

    public static func startCueDelay(outputIsBluetooth: Bool) -> TimeInterval {
        outputIsBluetooth ? bluetoothCueDelay : 0
    }
}
