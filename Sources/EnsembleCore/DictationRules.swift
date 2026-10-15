import Foundation

/// What the facts about Claude's microphone permit. The app reads the facts (CoreAudio, Claude's checkbox, what is
/// in flight); these rules decide, so each one can be tested without Claude, a camera or a clock.
public enum DictationRules {
    /// Only a definite "not capturing" reading proves Claude's microphone is off. CoreAudio's process list is
    /// unreadable (nil) while the audio system restarts, which says nothing about Claude, so an unreadable state
    /// never deletes the safety record, never undoes the safety mute and never counts as a confirmed stop.
    public static func confirmedOff(capture: Bool?) -> Bool { capture == false }

    /// What a start press leads to once it has returned.
    public enum AfterStart: Equatable {
        /// The microphone is on and the pose is still held: keep listening.
        case keepListening
        /// The microphone is on but the hand opened while the press was in flight: stop with the usual tail.
        case stopReleased
        /// The microphone is on but Ensemble was switched off while the press was in flight: stop at once.
        case stopSwitchedOff
        /// The press was not confirmed on. Nothing is listening; the safety record stays for the standing check.
        case notStarted
    }

    /// Switching off wins over a held pose: a press that lands after the switch-off is stopped at once.
    public static func afterStart(confirmedOn: Bool, switchedOff: Bool, poseHeld: Bool) -> AfterStart {
        guard confirmedOn else { return .notStarted }
        if switchedOff { return .stopSwitchedOff }
        return poseHeld ? .keepListening : .stopReleased
    }

    /// How long switching off waits for a start, stop or send press in flight. A start press takes a focus, one
    /// press and up to 1.5 s of confirmation, and can queue behind a slow Accessibility walk.
    public static let disarmWait: TimeInterval = 8

    public enum DisarmStep: Equatable {
        /// A press is in flight and the wait is not over.
        case wait
        /// Nothing that could open the microphone is in flight: stop, confirm off, then clear the record.
        case proceed
        /// A start press is still in flight after the wait: leave the safety record in place and stop the
        /// dictation the moment the press lands. The standing check clears the record once capture is off.
        case stopWhenStarted
    }

    /// The safety record is never cleared while a start press could still open the microphone.
    public static func disarmStep(stepInFlight: Bool, startInFlight: Bool, waited: TimeInterval) -> DisarmStep {
        guard stepInFlight else { return .proceed }
        if waited < disarmWait { return .wait }
        return startInFlight ? .stopWhenStarted : .proceed
    }

    public enum StopAllVerdict: Equatable {
        /// Every session pane found shows the microphone confirmed off.
        case allOff
        /// No session pane was found, so nothing was pressed and nothing was confirmed.
        case nothingFound
        /// At least one pane did not confirm off.
        case notAllOff
    }

    /// `paneConfirmedOff` holds one entry per session pane found: whether its stop confirmed the microphone off.
    /// Finding no pane is not a confirmation: Claude's window may be closed while its microphone still records.
    public static func stopAll(paneConfirmedOff: [Bool]) -> StopAllVerdict {
        if paneConfirmedOff.isEmpty { return .nothingFound }
        return paneConfirmedOff.allSatisfy { $0 } ? .allOff : .notAllOff
    }
}
