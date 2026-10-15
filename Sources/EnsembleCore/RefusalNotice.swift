import Foundation

/// A refusal shown in the menu bar panel. The panel's status line is always the live state; a refusal is a short-lived
/// note about one attempt, so it never outlives the moment it describes. It goes after `lifetime` seconds, as soon as
/// a dictation starts, as soon as the owner types or clicks (he is using Claude, nothing is wrong), and, for a
/// refusal about where the nose points, as soon as the nose is back on a Claude session.
public struct RefusalNotice: Equatable {
    public static let lifetime: TimeInterval = 6
    /// Input this soon after the refusal is the input that caused it ("You just typed or clicked"), not new use.
    public static let inputGrace: TimeInterval = 0.5

    public enum Resolves: Equatable {
        /// Only time, a dictation starting or new input clear it.
        case byTime
        /// Also cleared once the nose is on a Claude session again.
        case whenOnSession
    }

    public let text: String
    public let shownAt: TimeInterval
    public let resolves: Resolves

    public init(text: String, shownAt: TimeInterval, resolves: Resolves = .byTime) {
        self.text = text
        self.shownAt = shownAt
        self.resolves = resolves
    }

    /// True once the condition the refusal describes no longer holds or it has been up long enough.
    /// `lastInputAt`: when the owner last typed or clicked, on the same clock as `now`.
    public func isStale(now: TimeInterval, lastInputAt: TimeInterval, dictating: Bool, onSession: Bool) -> Bool {
        if now - shownAt >= Self.lifetime { return true }
        if dictating { return true }
        if lastInputAt > shownAt + Self.inputGrace { return true }
        if resolves == .whenOnSession, onSession { return true }
        return false
    }
}
