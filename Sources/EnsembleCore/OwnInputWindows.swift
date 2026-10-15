import Foundation

/// When Ensemble itself was posting keys (the arrows, Home and End that move Claude's pane dividers), so its own keys
/// never count as the owner typing. macOS's combined session state, which the "you just typed or clicked" rules read,
/// counts every posted key; the hardware state counts only the owner's own hands. A last key that falls inside one
/// of Ensemble's windows is Ensemble's, so the owner's last key is the one the hardware state saw. A real key typed
/// inside the window lands in the hardware state too, so it still counts.
public struct OwnInputWindows {
    /// Timestamps from the two event states and the clock can disagree by a frame or so.
    public static let slack = 0.05
    static let kept = 8

    private var windows: [(start: TimeInterval, end: TimeInterval?)] = []

    public init() {}

    /// Ensemble is about to post: everything from now until `end` is its own.
    public mutating func begin(at t: TimeInterval) {
        guard t.isFinite else { return }
        windows.append((t, nil))
        if windows.count > Self.kept { windows.removeFirst(windows.count - Self.kept) }
    }

    /// Nothing more will be posted in this window.
    public mutating func end(at t: TimeInterval) {
        guard t.isFinite, let i = windows.lastIndex(where: { $0.end == nil }) else { return }
        windows[i].end = t
    }

    /// True when an event at `t` may have been one Ensemble posted.
    public func isOwn(_ t: TimeInterval) -> Bool {
        guard t.isFinite else { return false }
        return windows.contains { t >= $0.start - Self.slack && t <= ($0.end ?? .infinity) + Self.slack }
    }

    /// Seconds since the owner's last event of this kind. `combined`: since the last one of any origin; `hardware`:
    /// since the last one of the owner's own hands. Both on the clock of `now`, which is when they were read.
    public func ownerAge(combined: TimeInterval, hardware: TimeInterval, now: TimeInterval) -> TimeInterval {
        guard combined.isFinite, isOwn(now - combined) else { return combined }
        return max(combined, hardware)
    }
}
