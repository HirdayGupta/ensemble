import Foundation

/// When Ensemble itself was pressing the mouse button (the peace sign and scissors drag Claude's pane dividers), so
/// its own press never counts as the owner clicking. macOS's combined session state, which the "you just typed or
/// clicked" rules read, counts every posted click; the hardware state counts only the owner's own hands. A last
/// click that falls inside one of Ensemble's press windows is Ensemble's, so the owner's last click is the one the
/// hardware state saw. A real click during the drag lands in the hardware state too, so it still counts.
public struct OwnPointerEvents {
    /// Timestamps from the two event states and the clock can disagree by a frame or so.
    public static let slack = 0.05
    static let kept = 8

    private var windows: [(start: TimeInterval, end: TimeInterval?)] = []

    public init() {}

    /// Ensemble is about to post a press: everything from now until `end` is its own.
    public mutating func begin(at t: TimeInterval) {
        guard t.isFinite else { return }
        windows.append((t, nil))
        if windows.count > Self.kept { windows.removeFirst(windows.count - Self.kept) }
    }

    /// The button is released and nothing more will be posted for this drag.
    public mutating func end(at t: TimeInterval) {
        guard t.isFinite, let i = windows.lastIndex(where: { $0.end == nil }) else { return }
        windows[i].end = t
    }

    /// True when a click at `t` may have been one Ensemble posted.
    public func isOwn(_ t: TimeInterval) -> Bool {
        guard t.isFinite else { return false }
        return windows.contains { t >= $0.start - Self.slack && t <= ($0.end ?? .infinity) + Self.slack }
    }

    /// Seconds since the owner last clicked. `combined`: since the last click of any origin; `hardware`: since the
    /// last click of the owner's own hands. Both on the clock of `now`, which is when they were read.
    public func ownerClickAge(combined: TimeInterval, hardware: TimeInterval, now: TimeInterval) -> TimeInterval {
        guard combined.isFinite, isOwn(now - combined) else { return combined }
        return max(combined, hardware)
    }
}
