import Foundation

/// What the Return key does while an Ensemble dictation runs in Claude: the first press stops the dictation (text
/// kept), and a second press sends. Outside a dictation started by Ensemble, with another app in front, or with a
/// modifier held, the key is never touched.
public struct ReturnKeys {
    /// A second Return this soon after the first, even once the stop is confirmed, still means "stop and send".
    public static let doubleWindow: TimeInterval = 0.5
    /// A stop that has not resolved by now is given up on: the key passes through again and any send is dropped.
    public static let stopLimit: TimeInterval = 5

    public enum Decision: Equatable, Sendable {
        /// Leave the key alone; Claude gets it.
        case pass
        /// Keep the key from Claude and do nothing else.
        case swallow
        /// Keep the key from Claude and stop the dictation the normal way, with the usual tail.
        case swallowAndStop
        /// Keep the key from Claude and send the draft once the stop is confirmed and the transcript settled.
        case swallowAndSendAfterStop
        /// Keep the key from Claude and send the draft now (the stop is already confirmed).
        case swallowAndSend
    }

    private enum Phase: Equatable {
        case idle
        case stopping(firstAt: TimeInterval, sendAfter: Bool)
        case stopped(firstAt: TimeInterval)
    }

    private var phase: Phase = .idle
    /// When a key other than a plain Return was last pressed while this watched the keyboard.
    public private(set) var lastOtherKeyAt: TimeInterval = -.infinity

    public init() {}

    /// True while a Return press is waiting on its stop, so the key watch must stay on after the dictation ends.
    public var awaitingStop: Bool {
        if case .stopping = phase { return true }
        return false
    }

    /// True while a second Return may still count as "send" after the stop was confirmed.
    public func inDoubleWindow(now: TimeInterval) -> Bool {
        if case .stopped(let first) = phase { return now - first <= Self.doubleWindow }
        return false
    }

    /// One key press. `isReturn` is Return or keypad Enter; `modified` any of Shift, Control, Option or Command
    /// held; `dictating` an Ensemble dictation is on (or its start or stop is in flight).
    public mutating func press(isReturn: Bool, modified: Bool, isRepeat: Bool, claudeInFront: Bool,
                               dictating: Bool, now: TimeInterval) -> Decision {
        expire(now: now)
        guard isReturn, !modified else {
            if dictating || phase != .idle { lastOtherKeyAt = now }
            return .pass
        }
        // Acting only on Claude: with another app in front the key is that app's.
        guard claudeInFront else { return .pass }
        switch phase {
        case .idle:
            guard dictating else { return .pass }
            // A held Return repeating into a dictation started later is not a press.
            if isRepeat { return .pass }
            phase = .stopping(firstAt: now, sendAfter: false)
            return .swallowAndStop
        case .stopping(let first, let sendAfter):
            // The key held down auto-repeats; only a fresh press asks to send.
            if isRepeat || sendAfter { return .swallow }
            phase = .stopping(firstAt: first, sendAfter: true)
            return .swallowAndSendAfterStop
        case .stopped(let first):
            phase = .idle
            if isRepeat { return now - first <= Self.doubleWindow ? .swallow : .pass }
            return now - first <= Self.doubleWindow ? .swallowAndSend : .pass
        }
    }

    /// The dictation stopped and it was confirmed off, by any route.
    public mutating func stopConfirmed(now: TimeInterval) {
        if case .stopping(let first, _) = phase {
            phase = now - first <= Self.doubleWindow ? .stopped(firstAt: first) : .idle
        }
    }

    /// The stop could not be confirmed, or the dictation was dropped. Returns true when a Return had asked to send,
    /// so the caller says "Not sent".
    @discardableResult
    public mutating func stopFailed() -> Bool {
        defer { phase = .idle }
        if case .stopping(_, true) = phase { return true }
        return false
    }

    public mutating func reset() { phase = .idle }

    /// The key watch was off for a while (macOS disabled it after a slow callback): keys may have gone by unseen, so
    /// they count as typed now and a Return send is refused by the usual "typed since" rule.
    public mutating func noteUnseenKeys(now: TimeInterval) { lastOtherKeyAt = now }

    /// Gives up on a stop that never resolved, and closes the double window once it has passed. Returns true when a
    /// send that was asked for is dropped by this.
    @discardableResult
    public mutating func expire(now: TimeInterval) -> Bool {
        switch phase {
        case .stopping(let first, let sendAfter) where now - first > Self.stopLimit:
            phase = .idle
            return sendAfter
        case .stopped(let first) where now - first > Self.doubleWindow:
            phase = .idle
        default: break
        }
        return false
    }

    /// Once Ensemble has turned Claude's dictation on, the session's message box should hold the keyboard so a key
    /// lands in it. Never with another app in front, and not again when the box already has focus.
    public static func focusComposerAfterStart(claudeInFront: Bool, composerFocused: Bool?) -> Bool {
        claudeInFront && composerFocused != true
    }

    /// The input age the send rules see for a send asked for by Return: the Return presses themselves are the
    /// request, so only clicks and other keys count as "typed or clicked since".
    public static func inputAge(clickAge: TimeInterval, lastOtherKeyAt: TimeInterval, now: TimeInterval) -> TimeInterval {
        min(clickAge, now - lastOtherKeyAt)
    }
}
