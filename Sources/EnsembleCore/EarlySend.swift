import Foundation

/// A thumbs-up made while dictating, as one motion. The dictation is stopped as soon as the thumbs-up is recognised
/// and the transcript settles while the hold runs, so Send can be pressed the moment the hold completes instead of
/// the stop and the settle starting only then (0.8 s after the bar filled, 2026-10-15). The hold itself is unchanged:
/// nothing is sent before it completes, and a hand that drops first leaves the text in the box, unsent.
///
/// The order this enforces: Send is pressed only once all three of stop confirmed, draft stable and hold completed
/// have happened, in whatever order they arrive. Every send rule is checked again by the caller before the press.
public struct EarlySend: Sendable {
    /// The send pose may be lost this long (a dropped hand frame, a misread pose) before the send is given up.
    public static let poseGrace: TimeInterval = 0.3

    public enum Outcome: Equatable, Sendable {
        /// Nothing to do yet.
        case wait
        /// Every step is done: check the send rules again and press Send now.
        case press
        /// The hand dropped before the hold completed: the dictation stays stopped and its text unsent.
        case keptNotSent
        /// The send is off (the stop was not confirmed, or it was dropped); the caller has already said why or says nothing.
        case dropped
    }

    public private(set) var armedAt: TimeInterval?
    public private(set) var stopConfirmed = false
    public private(set) var draftStable = false
    public private(set) var holdCompleted = false
    private var poseLostAt: TimeInterval?
    /// When each step happened, for the log line that measures the motion.
    public private(set) var marks: [(step: String, at: TimeInterval)] = []

    public init() {}

    public var isArmed: Bool { armedAt != nil }

    /// The thumbs-up was recognised while dictating and the stop begins now.
    public mutating func arm(at t: TimeInterval) {
        self = EarlySend()
        armedAt = t
        marks = [("thumbs-up recognised, stopping", t)]
    }

    public mutating func stopWasConfirmed(at t: TimeInterval) -> Outcome {
        guard isArmed, !stopConfirmed else { return .wait }
        stopConfirmed = true
        marks.append(("stop confirmed", t))
        return .wait
    }

    /// The stop could not be confirmed: nothing is sent.
    public mutating func stopFailed() -> Outcome {
        guard isArmed else { return .wait }
        self = EarlySend()
        return .dropped
    }

    /// The draft has not changed for the settle quiet time (or the settle wait ran out). Only after a confirmed stop.
    public mutating func draftSettled(at t: TimeInterval) -> Outcome {
        guard isArmed, stopConfirmed, !draftStable else { return .wait }
        draftStable = true
        marks.append(("draft stable", t))
        return finishIfReady(at: t)
    }

    public mutating func holdWasCompleted(at t: TimeInterval) -> Outcome {
        guard isArmed, !holdCompleted else { return .wait }
        holdCompleted = true
        poseLostAt = nil
        marks.append(("hold complete", t))
        return finishIfReady(at: t)
    }

    /// Called on every tick while armed: `holding` is whether the send pose is still held toward the send.
    /// Once the hold has completed the hand may drop freely.
    public mutating func observe(holding: Bool, at t: TimeInterval) -> Outcome {
        guard isArmed, !holdCompleted else { return .wait }
        if holding { poseLostAt = nil; return .wait }
        let lost = poseLostAt ?? t
        poseLostAt = lost
        guard t - lost >= Self.poseGrace else { return .wait }
        self = EarlySend()
        return .keptNotSent
    }

    /// Sleep, a lock, switching off or an interrupted dictation: forget the send without a word.
    public mutating func drop() { self = EarlySend() }

    private mutating func finishIfReady(at t: TimeInterval) -> Outcome {
        guard stopConfirmed, draftStable, holdCompleted else { return .wait }
        marks.append(("send pressing", t))
        return .press
    }

    /// "thumbs-up recognised, stopping +0 ms, stop confirmed +412 ms, ..." for the log; events and times only.
    public func timeline() -> String {
        guard let start = armedAt else { return "" }
        return marks.map { "\($0.step) +\(Int((($0.at - start) * 1000).rounded())) ms" }.joined(separator: ", ")
    }
}
