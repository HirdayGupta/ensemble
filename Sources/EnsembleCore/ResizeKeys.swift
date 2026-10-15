import Foundation

/// Where the keyboard goes around a pane resize. A resize gives one of Claude's pane dividers the keyboard, so the
/// arrows, Home and End it posts move that divider; the owner's own keys must never land there, and once it ends the
/// keyboard goes back to the message box only if a divider of that row still holds it, so a box the owner clicked
/// into meanwhile keeps it.
public enum ResizeKeys {
    public enum Refocus: Equatable, Sendable {
        /// A divider still holds the keyboard: give it back to the session's message box now.
        case now
        /// Claude is not in front: look again when it next comes to the front.
        case whenClaudeReturns
        /// The keyboard is somewhere else (the owner put it there), or nothing was ever asked of a divider.
        case leave
    }

    /// After a resize. `askedDivider`: a divider was asked to take the keyboard at any point, whether or not a key
    /// followed. `keyboardOnDivider`: Claude's focused element is one of that row's dividers, nil when it could not
    /// be read (counted as not, so a box the owner chose is never taken from them).
    public static func refocus(askedDivider: Bool, claudeInFront: Bool, keyboardOnDivider: Bool?) -> Refocus {
        guard askedDivider else { return .leave }
        guard claudeInFront else { return .whenClaudeReturns }
        return keyboardOnDivider == true ? .now : .leave
    }

    /// While a resize may have a divider holding the keyboard, every key that is not one Ensemble posted itself is
    /// held back (and the resize stopped), so an arrow, Home or End the owner types never moves a divider.
    public static func holds(resizing: Bool, ownKey: Bool) -> Bool { resizing && !ownKey }

    /// Held keys go out again once the resize has ended and the keyboard was put back: only where they cannot move a
    /// divider, which is with another app in front or with Claude's keyboard known to be off every divider of the row.
    public static func replayHeld(claudeInFront: Bool, keyboardOnDivider: Bool?) -> Bool {
        !claudeInFront || keyboardOnDivider == false
    }
}
