import Foundation

/// Plans the key presses that resize the side-by-side session panes of one Claude window.
///
/// Claude's divider between two panes (an `AXSplitter` labelled "Resize pane columns") moves with the keyboard once
/// it holds keyboard focus: an arrow moves it 8 pt, Shift and an arrow 32 pt, Home and End to the pair's limit (the
/// pane on that side down to Claude's minimum width). Setting its value through Accessibility is accepted and
/// ignored. A press changes only the two panes beside that divider, so width reaches a pane two places away by
/// moving every divider in between, the outer one first. Measured on the owner's Claude on 2026-10-15: presses 10 ms
/// apart all landed with one focus, and the frames read back about 170 ms after a press.
///
/// Widths here are the panes' own widths without the gaps between them; a press keeps the pair's sum.
public enum PaneKeys {
    public enum Key: Equatable, Sendable {
        case left, right, shiftLeft, shiftRight, home, end

        /// How far the divider moves, in points, right positive; nil for Home and End, which go to a limit.
        public var step: Double? {
            switch self {
            case .left: return -arrow
            case .right: return arrow
            case .shiftLeft: return -shiftArrow
            case .shiftRight: return shiftArrow
            case .home, .end: return nil
            }
        }
    }

    public struct Press: Equatable, Sendable {
        public let divider: Int
        public let key: Key
        public init(_ divider: Int, _ key: Key) { self.divider = divider; self.key = key }
    }

    public static let arrow: Double = 8
    public static let shiftArrow: Double = 32
    /// One press per display frame while a divider glides, so each step shows.
    public static let interval: Double = 1.0 / 60
    /// The fastest pace: presses 10 ms apart all landed (16 in a row, measured 2026-10-15).
    public static let fastestInterval: Double = 0.01
    /// A layout glides for at most this long; a longer one goes faster, down to `fastestInterval`, and past that
    /// jumps with Home and End for the bulk and steps only the rest.
    public static let animateBudget: Double = 0.4
    /// Claude's minimum pane width when its dividers report no limits (the limits read 24 percent of a 1320 pt pair).
    public static let fallbackMinimum: Double = 316

    /// Claude's minimum pane width from its dividers. Each reports its pair's limits in whole percent of the pair's
    /// width; the largest reading is used so a planned width is never one Claude refuses.
    public static func minimum(pairWidths: [Double], minPercents: [Double?]) -> Double {
        let readings = zip(pairWidths, minPercents).compactMap { w, p -> Double? in
            guard let p, p > 0, p < 50, w.isFinite, w > 0 else { return nil }
            return w * p / 100
        }
        return readings.max() ?? fallbackMinimum
    }

    /// Pane `k` as wide as Claude allows, every other pane in its row at Claude's minimum.
    public static func maximizeWidths(_ widths: [Double], focus k: Int, minimum: Double) -> [Double]? {
        guard widths.count >= 2, widths.indices.contains(k), valid(widths), minimum.isFinite, minimum > 0 else { return nil }
        let total = widths.reduce(0, +)
        let rest = Double(widths.count - 1) * minimum
        guard total - rest > minimum else { return nil }
        return widths.indices.map { $0 == k ? total - rest : minimum }
    }

    /// Every pane the same width.
    public static func evenWidths(_ widths: [Double]) -> [Double]? {
        guard widths.count >= 2, valid(widths) else { return nil }
        return Array(repeating: widths.reduce(0, +) / Double(widths.count), count: widths.count)
    }

    /// The presses that take the row from `widths` to `target`. Steps (a glide) when they fit `animateBudget` at the
    /// fastest pace, otherwise Home and End for the bulk of each move where that saves presses, and steps for the rest. Empty when nothing needs to move or
    /// the input does not describe one row (counts differ, totals differ, non-finite).
    public static func plan(from widths: [Double], to target: [Double], minimum: Double) -> [Press] {
        let glide = plan(from: widths, to: target, minimum: minimum, jumps: false)
        if duration(glide) <= animateBudget { return glide }
        return plan(from: widths, to: target, minimum: minimum, jumps: true)
    }

    /// Seconds between presses: one a frame, faster when that would run past `animateBudget`.
    public static func pace(_ count: Int) -> Double {
        guard count > 0 else { return interval }
        return max(fastestInterval, min(interval, animateBudget / Double(count)))
    }

    /// How long the presses take at their `pace`.
    public static func duration(_ presses: [Press]) -> Double { Double(presses.count) * pace(presses.count) }

    /// What the presses do to a row whose panes cannot go below `minimum`, as Claude does it.
    public static func simulate(_ widths: [Double], minimum: Double, presses: [Press]) -> [Double] {
        var w = widths
        for p in presses where p.divider >= 0 && p.divider + 1 < w.count {
            let pair = w[p.divider] + w[p.divider + 1]
            guard pair >= 2 * minimum else { continue }
            let left: Double
            switch p.key {
            case .home: left = minimum
            case .end: left = pair - minimum
            default: left = min(max(w[p.divider] + (p.key.step ?? 0), minimum), pair - minimum)
            }
            w[p.divider] = left
            w[p.divider + 1] = pair - left
        }
        return w
    }

    static func plan(from widths: [Double], to target: [Double], minimum m: Double, jumps: Bool) -> [Press] {
        let n = widths.count
        guard n >= 2, target.count == n, valid(widths), valid(target), m.isFinite, m > 0,
              abs(widths.reduce(0, +) - target.reduce(0, +)) <= 1 else { return [] }
        var cur = widths
        var out: [Press] = []
        let goal = edges(target)
        // Each round moves one divider to within half an arrow of where it belongs, or as far as its pair allows;
        // a row of n panes never needs more than a few rounds per divider.
        for _ in 0..<(4 * n) {
            let at = edges(cur)
            var best: (j: Int, to: Double, lo: Double, hi: Double, clean: Bool, excess: Double)?
            for j in 0..<(n - 1) {
                let lo = (j == 0 ? 0 : at[j - 1]) + m
                let hi = at[j + 1] - m
                guard lo <= hi else { continue }
                let to = min(max(goal[j], lo), hi)
                guard abs(to - at[j]) > arrow / 2 else { continue }
                // Clean: the divider reaches its goal now. Moving it first never squeezes a pane that a neighbour
                // still has to pass width through. Among those, the pane with the most to give goes first.
                let clean = to == goal[j]
                let giver = to < at[j] ? j : j + 1
                let excess = cur[giver] - target[giver]
                if let b = best, (b.clean && !clean) || (b.clean == clean && excess <= b.excess) { continue }
                best = (j, to, lo, hi, clean, excess)
            }
            guard let b = best else { break }
            let keys = moveKeys(from: at[b.j], to: b.to, lo: b.lo, hi: b.hi, jumps: jumps).map { Press(b.j, $0) }
            guard !keys.isEmpty else { break }
            cur = simulate(cur, minimum: m, presses: keys)
            out += keys
        }
        return out
    }

    /// The keys that move one divider from `x` to `y`, its limits `lo` and `hi`. A move to a limit ends on Home or
    /// End, so it lands exactly where Claude's own minimum puts it whatever the estimate.
    static func moveKeys(from x: Double, to y: Double, lo: Double, hi: Double, jumps: Bool) -> [Key] {
        let d = y - x
        let atLimit: Key? = abs(y - hi) < 0.5 && d > 0 ? .end : abs(y - lo) < 0.5 && d < 0 ? .home : nil
        if let k = atLimit {
            if jumps { return [k] }
            // Glide in whole Shift steps, then let Home or End take the last few points.
            let n = Int(abs(d) / shiftArrow)
            return Array(repeating: d > 0 ? .shiftRight : .shiftLeft, count: max(0, n - 1)) + [k]
        }
        let steps = stepKeys(d)
        guard jumps else { return steps }
        let (jump, from) = d > 0 ? (Key.end, hi) : (Key.home, lo)
        let alt = [jump] + stepKeys(y - from)
        return alt.count < steps.count ? alt : steps
    }

    /// Shift steps for the bulk, arrows for the rest, rounded to the nearest arrow.
    static func stepKeys(_ d: Double) -> [Key] {
        let a = abs(d)
        var shifts = Int(a / shiftArrow)
        var arrows = Int(((a - Double(shifts) * shiftArrow) / arrow).rounded())
        if arrows * Int(arrow) >= Int(shiftArrow) { shifts += 1; arrows = 0 }
        return Array(repeating: d > 0 ? .shiftRight : .shiftLeft, count: shifts)
            + Array(repeating: d > 0 ? .right : .left, count: arrows)
    }

    /// Where each divider sits, measured from the row's left edge in pane widths only.
    static func edges(_ widths: [Double]) -> [Double] {
        var sum = 0.0
        return widths.map { sum += $0; return sum }
    }

    static func valid(_ w: [Double]) -> Bool { w.allSatisfy { $0.isFinite && $0 > 0 } }
}
