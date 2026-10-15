import CoreGraphics
import Foundation

/// Plans the divider drags that resize the side-by-side session panes of one Claude window.
///
/// Claude resizes its pane columns only through the divider between two panes (an `AXSplitter` labelled
/// "Resize pane columns", whose value is the split of that one pair). A drag moves one divider at a time, so a
/// layout change is a sequence of drags, planned one at a time from the layout read back after the last one.
/// Which divider goes next: one whose move leaves the pane it shrinks no narrower than that pane's target (its far
/// edge is already where it belongs), so Claude never has to squeeze a pane past its minimum while a neighbour
/// still holds the width. Among those, the pane with the most to give goes first. Maximizing then runs from the
/// outer dividers in toward the session and evening out from the big session outward, three drags for four panes.
public enum PaneWidths {
    public enum Goal: Equatable, Sendable {
        /// The pane at this index takes the width the others give up by going down to `narrowWidth`.
        case maximize(Int)
        /// Every pane gets the same width.
        case evenOut
        /// Each pane gets the width at its index (`SessionFit.widths`), planned once from the layout at the start.
        case widths([Double])
    }

    /// What a minimized pane is sized to. Claude's own minimum may be larger: its drag stops there and the
    /// divider counts as done (see `stuck`).
    public static let narrowWidth: Double = 300
    /// A divider this close to its target is left alone.
    public static let tolerance: Double = 6
    /// One drag's length, and the curve it follows (`SmoothCurve`).
    public static let dragDuration: Double = 0.3

    /// Target width of each pane. `available` is the row's width without the gaps between panes.
    public static func targets(count: Int, available: Double, goal: Goal) -> [Double] {
        guard count > 0, available > 0 else { return [] }
        if case .widths(let w) = goal { return w.count == count ? w : [] }
        let even = Array(repeating: available / Double(count), count: count)
        guard case .maximize(let k) = goal, (0..<count).contains(k), count > 1 else { return even }
        let rest = Double(count - 1) * narrowWidth
        // Too narrow a window to leave the others at the narrow width: even shares is the most it can do.
        guard available - rest > available / Double(count) else { return even }
        return (0..<count).map { $0 == k ? available - rest : narrowWidth }
    }

    /// The next divider to drag and where to, or nil when the layout is done.
    /// `panes`: each pane's frame, left to right, one row. `dividers`: the x of each divider's centre, one fewer
    /// than the panes. `stuck`: dividers whose last drag did not move them; Claude's minimum stopped them.
    public static func nextMove(panes: [CGRect], dividers: [Double], goal: Goal,
                                stuck: Set<Int> = []) -> (divider: Int, toX: Double)? {
        let n = panes.count
        guard n >= 2, dividers.count == n - 1, panes.allSatisfy({ $0.width > 0 && $0.minX.isFinite && $0.maxX.isFinite }),
              dividers.allSatisfy(\.isFinite) else { return nil }
        let (widths, gap) = layout(panes: panes, dividers: dividers)
        let left = Double(panes[0].minX), right = Double(panes[n - 1].maxX)
        let available = right - left - Double(n - 1) * gap
        let want = targets(count: n, available: available, goal: goal)
        guard want.count == n else { return nil }
        let bounds = [left - gap / 2] + dividers + [right + gap / 2]
        var best: (divider: Int, toX: Double, clean: Bool, excess: Double)?
        var edge = left - gap / 2
        for j in 0..<(n - 1) {
            edge += want[j] + gap
            let target = edge
            guard !stuck.contains(j), abs(dividers[j] - target) > tolerance else { continue }
            // Moving left takes width from the pane on the left, moving right from the pane on the right; that pane
            // ends between the target and its own far edge.
            let movingLeft = target < dividers[j]
            let giver = movingLeft ? j : j + 1
            let after = movingLeft ? target - bounds[j] - gap : bounds[j + 2] - target - gap
            let clean = after >= want[giver] - tolerance
            let excess = widths[giver] - want[giver]
            if let b = best, (b.clean && !clean) || (b.clean == clean && excess <= b.excess) { continue }
            best = (j, target, clean, excess)
        }
        return best.map { ($0.divider, $0.toX) }
    }

    /// Each pane's width as the dividers place it, and the gap between panes. Pane i spans from boundary i to
    /// boundary i+1, less one gap; the outer boundaries sit half a gap outside the row. The caller checks that
    /// there is one divider fewer than panes.
    public static func layout(panes: [CGRect], dividers: [Double]) -> (widths: [Double], gap: Double) {
        let n = panes.count
        guard n >= 2, dividers.count == n - 1 else { return (panes.map { Double($0.width) }, 0) }
        let gaps = (0..<(n - 1)).map { max(0, Double(panes[$0 + 1].minX - panes[$0].maxX)) }
        let gap = min(gaps.reduce(0, +) / Double(n - 1), 24)
        let bounds = [Double(panes[0].minX) - gap / 2] + dividers + [Double(panes[n - 1].maxX) + gap / 2]
        return ((0..<n).map { bounds[$0 + 1] - bounds[$0] - gap }, gap)
    }

    /// Pairs each divider between neighbouring panes with the splitter frame nearest the gap between them.
    /// nil when any pair has no splitter within `reach` of its gap, or a splitter is not beside the row.
    public static func dividers(between panes: [CGRect], splitters: [CGRect], reach: Double = 24) -> [Double]? {
        guard panes.count >= 2 else { return nil }
        var out: [Double] = []
        for j in 0..<(panes.count - 1) {
            let a = panes[j], b = panes[j + 1]
            let gapX = Double(a.maxX + b.minX) / 2
            let beside = splitters.filter { $0.minY < max(a.maxY, b.maxY) && $0.maxY > min(a.minY, b.minY) && $0.height >= 100 }
            guard let s = beside.min(by: { abs(Double($0.midX) - gapX) < abs(Double($1.midX) - gapX) }),
                  abs(Double(s.midX) - gapX) <= reach else { return nil }
            out.append(Double(s.midX))
        }
        return out
    }

    /// The panes in one row with `target`: same window, overlapping it vertically, left to right.
    public static func row(of target: ClaudeSession, in sessions: [ClaudeSession]) -> [ClaudeSession] {
        sessions.filter { $0.windowNumber == target.windowNumber && $0.frame.minY < target.frame.maxY && $0.frame.maxY > target.frame.minY }
            .sorted { $0.frame.minX < $1.frame.minX }
    }
}

/// The app's one motion curve: a critically damped spring, the curve SwiftUI's `.smooth` uses, with the response
/// equal to the duration. It never overshoots, so a dragged divider never swings past its target.
public enum SmoothCurve {
    /// Fraction of the way from start to end after `t` seconds of a `duration`-second move, 0...1. The spring
    /// covers 98.6 percent by `duration`; scaling by that keeps it continuous and ends it exactly on time.
    public static func progress(t: Double, duration: Double) -> Double {
        guard duration > 0, t.isFinite else { return 1 }
        if t <= 0 { return 0 }
        if t >= duration { return 1 }
        func spring(_ x: Double) -> Double { 1 - (1 + 2 * Double.pi * x) * exp(-2 * Double.pi * x) }
        return spring(t / duration) / spring(1)
    }
}
