import Foundation

/// Why nobody can be at the Mac right now. While any reason holds, the camera is off and nothing acts on Claude.
public enum AwayReason: String, CaseIterable, Sendable {
    case systemSleep, displaySleep, session, locked, screenSaver
}

/// The reasons set by macOS's "going" notifications and cleared by the matching "back" ones. A "back" that never
/// arrives must not leave the camera off for good, so `reconcile` clears what the current facts disprove.
public struct AwayState: Equatable {
    public private(set) var reasons: Set<AwayReason> = []

    public init() {}

    public var isAway: Bool { !reasons.isEmpty }

    /// Applies one notification. Returns true when being away started or ended.
    @discardableResult
    public mutating func set(_ reason: AwayReason, _ on: Bool) -> Bool {
        let was = isAway
        if on { reasons.insert(reason) } else { reasons.remove(reason) }
        return was != isAway
    }

    /// Called about once a second while away. Code running with the session unlocked, on the console and with the
    /// display awake disproves sleep, a locked or inactive session and a sleeping display; recent keyboard or mouse
    /// use disproves the screen saver, which any input ends. Returns true when being away ended.
    @discardableResult
    public mutating func reconcile(sessionLockedOrInactive: Bool, displayAsleep: Bool, secondsSinceInput: Double) -> Bool {
        guard isAway else { return false }
        if !sessionLockedOrInactive, !displayAsleep {
            reasons.subtract([.systemSleep, .displaySleep, .session, .locked])
            if secondsSinceInput < 2 { reasons.remove(.screenSaver) }
        }
        return !isAway
    }
}
