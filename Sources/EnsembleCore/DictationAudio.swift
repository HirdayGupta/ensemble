import Foundation

/// What Ensemble does with sound around a dictation. Allowlist model: Ensemble never lowers the output volume, so
/// every sound Claude or Ensemble makes plays at the owner's volume; only other apps' media is paused, with the
/// play/pause key.
///
/// Claude plays its own dictation sounds (enter and exit voice mode) from a web audio context that Chromium lets
/// start only after a real user gesture. Ensemble's Accessibility press is not one, so after an Ensemble start
/// Claude's sounds usually stay silent; Ensemble then plays the same sound itself, unless more of Claude's processes
/// are seen sending audio out right after the press than before it.
public enum DictationAudio {
    public enum StartStep: Equatable, Sendable {
        /// The play/pause key for media on speakers, checked to have stopped before the microphone opens.
        case pauseOtherMedia
        case pressMicrophone
        /// The start sound, once the microphone is confirmed on.
        case startSound
    }

    /// The order of a start. Media is paused before the press, so neither it nor the pause is transcribed; nothing
    /// that could silence the output comes between the press and the start sound.
    public static func startSteps(pauseMedia: Bool, mediaPlayingOnSpeakers: Bool, sound: Bool) -> [StartStep] {
        var steps: [StartStep] = []
        if pauseMedia && mediaPlayingOnSpeakers { steps.append(.pauseOtherMedia) }
        steps.append(.pressMicrophone)
        if sound { steps.append(.startSound) }
        return steps
    }

    /// The start sound is due when the microphone is confirmed on and the dictation goes on, or stops only because
    /// the hand opened during the press (that stop then has its own sound). A start stopped because Ensemble was
    /// switched off, or one never confirmed, gets none.
    public static func startSoundDue(after: DictationRules.AfterStart, soundsOn: Bool) -> Bool {
        guard soundsOn else { return false }
        switch after {
        case .keepListening, .stopReleased: return true
        case .stopSwitchedOff, .notStarted: return false
        }
    }

    /// How long after the confirmation Claude's own sound is looked for.
    public static let claudeSoundWindow: TimeInterval = 0.15

    /// Ensemble plays its sound unless Claude's output rose after the press: more of Claude's processes sending
    /// audio out than just before it, so Claude's own sound is playing and a second would double it. Claude already
    /// sending audio before the press no longer means Ensemble plays regardless: only a rise counts, from silent or
    /// from already playing. An unreadable process list, before or after, counts as no rise.
    public static func ensemblePlays(claudeOutputsBefore: Int?, claudeOutputsAfter: Int?) -> Bool {
        guard let before = claudeOutputsBefore, let after = claudeOutputsAfter else { return true }
        return after <= before
    }

    /// Opening a Bluetooth headset's microphone switches it to its call profile, and a sound played during the
    /// switch (and the switch back at the stop) is dropped; the sound waits it out. Not yet measured: the owner's
    /// check by hand settles it.
    public static let bluetoothDelay: TimeInterval = 0.35

    /// When a dictation sound plays, counted from the confirmation: never before Claude's sound has been looked for.
    public static func soundDelay(outputIsBluetooth: Bool) -> TimeInterval {
        max(claudeSoundWindow, outputIsBluetooth ? bluetoothDelay : 0)
    }
}
