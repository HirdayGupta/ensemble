import CoreGraphics
import Foundation

/// How often Claude's session panes are looked for, and what a scan that finds nothing is worth. A full walk of
/// Claude's accessibility tree runs on Claude's own main thread (thousands of nodes per window), so the check that
/// runs every second re-reads only what the last walk cached, and walks again only when something says the layout
/// may have changed.
public enum SessionScan {
    /// A full walk runs at least this often, to find a pane opened inside a window that did not move.
    public static let fullWalkEvery: TimeInterval = 10

    /// `cached`: sessions the last walk found. `windowsChanged`: Claude's window list (numbers, frames, on screen)
    /// differs from the last walk's. `cachedAnswer`: every cached dictation checkbox and pane still answers.
    public static func needsFullWalk(cached: Int, windowsChanged: Bool, cachedAnswer: Bool,
                                     sinceFullWalk: TimeInterval) -> Bool {
        cached == 0 || windowsChanged || !cachedAnswer || !(sinceFullWalk < fullWalkEvery)
    }
}

/// Keeps the session list through one doubtful scan. Claude's tree can read empty for a moment while it re-renders
/// (seen as "found 0" between two "found 3" a second apart with Claude in front), and dropping every session for
/// that second refuses gestures and moves the highlight. A doubtful scan (nothing found, or a walk cut short) keeps
/// the previous sessions only while their own dictation checkboxes still answer, and never twice in a row.
public struct SessionListHold: Sendable {
    public private(set) var doubtfulInARow = 0

    public init() {}

    /// Returns true when the caller should keep the previous sessions instead of what this scan found.
    public mutating func keepPrevious(found: Int, walkComplete: Bool, previous: Int, previousAnswer: Bool) -> Bool {
        guard found == 0 || !walkComplete, previous > 0 else { doubtfulInARow = 0; return false }
        doubtfulInARow += 1
        return doubtfulInARow < 2 && previousAnswer
    }

    /// Claude quit or the list was cleared on purpose.
    public mutating func reset() { doubtfulInARow = 0 }
}

/// One of Claude's windows as the window server lists it.
public struct WindowCandidate: Equatable, Sendable {
    public var number: Int
    public var bounds: CGRect
    public var onScreen: Bool

    public init(number: Int, bounds: CGRect, onScreen: Bool) {
        self.number = number; self.bounds = bounds; self.onScreen = onScreen
    }
}

/// Which window-server window an accessibility window is. A session's id is built on the window number, so a wrong
/// or missing match changes every id in that window (and a stop or send looks its session up by id).
public enum WindowMatch {
    /// `axNumber`: the window number Accessibility gave for the window, when it gave one; it decides on its own.
    /// Otherwise the frames are compared, an on-screen window preferred over a hidden one with the same frame, and
    /// while a move or resize has the two frames briefly apart, the one on-screen window that shares at least 80%
    /// of both its own area and the frame's.
    public static func match(axNumber: Int?, axFrame: CGRect, among windows: [WindowCandidate]) -> WindowCandidate? {
        if let n = axNumber, n != 0, let w = windows.first(where: { $0.number == n }) { return w }
        let close = windows.filter { Self.close($0.bounds, axFrame) }
        if let w = close.first(where: \.onScreen) ?? close.first { return w }
        let area = axFrame.width * axFrame.height
        guard area > 0 else { return nil }
        let scored = windows.filter(\.onScreen).map { w -> (WindowCandidate, CGFloat) in
            let i = w.bounds.intersection(axFrame)
            let shared = i.isNull ? 0 : i.width * i.height
            return (w, min(shared / area, shared / max(1, w.bounds.width * w.bounds.height)))
        }
        // Two windows that both nearly cover the frame cannot be told apart: no match beats a wrong one.
        let near = scored.filter { $0.1 >= 0.8 }
        return near.count == 1 ? near[0].0 : nil
    }

    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 3 && abs(a.minY - b.minY) < 3 && abs(a.width - b.width) < 3 && abs(a.height - b.height) < 3
    }
}
