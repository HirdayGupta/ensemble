import CoreGraphics
import Foundation

/// Which Claude session the nose is on, and for how long. Focus follows the nose almost at once; the margin
/// between neighbouring panes and the longer dwell while dictating keep it from flipping. Pure: time comes
/// from the caller.
public struct FocusTracker {
    /// 0.075 s (2026-10-14: 0.6 s felt slow): focus follows the nose almost at once.
    public static let switchDwell = 0.075
    /// Moving from one session to another, the nose must be this far inside the new one.
    public static let switchMargin: CGFloat = 28
    /// While dictating, the nose must stay on another session this long before focus moves there.
    public static let listeningSwitchDwell = 2.0
    /// A session covered by another app's window is raised after the nose has rested on it this long.
    public static let raiseDwell = 0.8

    public private(set) var target: ClaudeSession?
    /// A session (or none) the nose moved onto, waiting out its dwell before the target follows.
    public private(set) var candidate: (session: ClaudeSession?, since: TimeInterval)?
    private var covered: (id: String, since: TimeInterval)?
    private var lastObserved: TimeInterval?

    public init() {}

    /// The session whose window is in front under the nose. Near the border between the current session and
    /// another, the current one stays: no flip-flopping between two panes.
    public static func session(at p: CGPoint, in sessions: [ClaudeSession], current: ClaudeSession?,
                               isInFront: (ClaudeSession) -> Bool) -> ClaudeSession? {
        var under = sessions.first { $0.frame.contains(p) && isInFront($0) }
        if let u = under, let t = current, u.id != t.id,
           !u.frame.insetBy(dx: switchMargin, dy: switchMargin).contains(p),
           let still = sessions.first(where: { $0.id == t.id }),
           still.frame.insetBy(dx: -switchMargin, dy: -switchMargin).contains(p) {
            under = still
        }
        return under
    }

    /// Feeds one reading. Returns the session the target just moved onto; nil when it did not move or moved
    /// to nothing. `held` (a pinch or scroll in progress) holds everything still. `speaking` (only meaningful
    /// while listening) freezes a running switch dwell: the time spent speaking does not count.
    public mutating func observe(under: ClaudeSession?, at t: TimeInterval, held: Bool, listening: Bool, speaking: Bool = false) -> ClaudeSession? {
        defer { lastObserved = t }
        if held {
            candidate = nil
        } else if under?.id == target?.id {
            candidate = nil
        } else if let c = candidate, c.session?.id == under?.id {
            let dwell = listening && under != nil ? Self.listeningSwitchDwell : Self.switchDwell
            if listening, speaking, under != nil, let last = lastObserved {
                candidate = (c.session, c.since + max(0, t - last))
                return nil
            }
            if t - c.since >= dwell { target = under; candidate = nil; return under }
        } else {
            candidate = (under, t)
        }
        return nil
    }

    /// The nose rests on a session hidden behind another window. True once it has rested for `raiseDwell`.
    public mutating func noteCovered(_ id: String, at t: TimeInterval) -> Bool {
        if covered?.id != id { covered = (id, t); return false }
        guard let c = covered else { return false }
        return t - c.since >= Self.raiseDwell
    }

    public mutating func clearCovered() { covered = nil }
    public mutating func forgetTarget() { target = nil }
    public mutating func forgetTargetAndCandidate() { target = nil; candidate = nil }
    public mutating func forgetAll() { target = nil; candidate = nil; covered = nil }
}

/// The drawn dot follows the filtered nose on a leash, so small head wobble never moves it.
public enum NoseDot {
    public static let leash: CGFloat = 24

    public static func follow(_ dot: CGPoint?, nose p: CGPoint) -> CGPoint {
        guard let d = dot else { return p }
        let dist = hypot(p.x - d.x, p.y - d.y)
        guard dist > leash else { return d }
        let k = (dist - leash) / dist
        return CGPoint(x: d.x + (p.x - d.x) * k, y: d.y + (p.y - d.y) * k)
    }
}

public enum FocusAction: Equatable {
    case none                  // nothing to do (already focused, or already the dictating session)
    case retryLater            // the user is busy or typing; try again from the tick
    case stopDictationFirst    // dictating elsewhere: stop, keep the text, then move focus
    case focusNow
}

public enum FocusPolicy {
    /// What to do now that the nose settled on `session`. Coming back to the session that already has focus
    /// (after the target dropped for a moment) is not a switch.
    public static func action(for session: ClaudeSession, lastFocusedId: String?, claudeInFront: @autoclosure () -> Bool,
                              busy: Bool, secondsSinceInput: TimeInterval, inputQuiet: TimeInterval,
                              listeningId: String?) -> FocusAction {
        if session.id == lastFocusedId, claudeInFront() { return .none }
        guard !busy, secondsSinceInput >= inputQuiet else { return .retryLater }
        if let listening = listeningId { return listening == session.id ? .none : .stopDictationFirst }
        return .focusNow
    }
}
