import CoreGraphics
import Foundation

/// Reads the side-by-side session panes of one Claude window: which panes share a row, where the divider between
/// each pair sits, and each pane's width as the dividers place it. `PaneKeys` plans the presses that change them.
public enum PaneWidths {
    /// The narrowest a fit leaves another pane (`SessionFit`), or Claude's own minimum when that is larger.
    public static let narrowWidth: Double = 300
    /// A pane this close to its target width is left alone.
    public static let tolerance: Double = 6

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
