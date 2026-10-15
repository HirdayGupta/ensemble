import CoreGraphics
import Foundation

/// Fitting the session you look at to Claude's chat column.
///
/// Claude's transcript text never grows past a fixed column (its `--max-content-width`, centred in the pane), so a
/// pane wider than that column only adds empty margins and a pane narrower wraps the text early. When focus settles
/// on a pane narrower than the column, the pane is widened to the column and the other panes in its row each give
/// an equal share of the width it takes, none going below `PaneWidths.narrowWidth`.
public enum SessionFit {
    /// How long focus must rest on one session before it is fitted, so a nose passing over a pane never resizes it.
    public static let settle: Double = 0.6
    /// Claude's chat column, used until one is measured: a 768 pt text measure plus a 32 pt gutter each side, read
    /// from the stylesheet of the Claude desktop app installed on the owner's Mac on 2026-10-15 (the default
    /// transcript width; Claude's wider settings use 960 and 1280).
    public static let fallbackColumn: Double = 832

    /// The width of every pane in the row so pane `focus` reaches `width`, the width it gains taken equally from
    /// the others and none of them below `minimum`, or below its own entry in `floors` (a pane fitted a moment ago
    /// keeps its fit). When the others cannot give it all, the pane gets what they can. nil when the pane is already
    /// within `PaneWidths.tolerance` of `width`, or the others have nothing to give.
    public static func widths(current: [Double], focus k: Int, width: Double,
                              minimum: Double = PaneWidths.narrowWidth, floors: [Double] = []) -> [Double]? {
        guard current.count >= 2, current.indices.contains(k), width.isFinite, current.allSatisfy(\.isFinite) else { return nil }
        let need = width - current[k]
        guard need > PaneWidths.tolerance else { return nil }
        var room = current.indices.map { i in
            max(0, current[i] - max(minimum, floors.indices.contains(i) && floors[i].isFinite ? floors[i] : 0))
        }
        room[k] = 0
        let total = room.reduce(0, +)
        guard total > PaneWidths.tolerance else { return nil }
        var left = min(need, total)
        var out = current
        out[k] += left
        // Equal shares; a pane that reaches its minimum gives what it has and the rest is shared by the others.
        var giving = current.indices.filter { room[$0] > 0 }
        while left > 0.001, !giving.isEmpty {
            let share = left / Double(giving.count)
            let short = giving.filter { room[$0] < share }
            if short.isEmpty {
                for i in giving { out[i] -= share }
                left = 0
            } else {
                for i in short { out[i] -= room[i]; left -= room[i]; room[i] = 0 }
                giving.removeAll { room[$0] == 0 }
            }
        }
        return out
    }

    /// Keeps fits from undoing each other. Four panes side by side cannot all reach the column, so without this every
    /// glance refitted the row and narrowed the pane fitted a moment before (four fits in 78 s, 2026-10-15). A pane a
    /// fit narrowed is not refitted for `window`; a pane fitted within `window` keeps its fitted width as a floor
    /// (`floors`), and a fit those floors keep from reaching the column is skipped (`allows`). Nothing is fitted in
    /// the first `afterCalibration` seconds after a calibration, while the nose is still settling.
    public struct Hold: Sendable {
        public static let window: TimeInterval = 180
        public static let afterCalibration: TimeInterval = 5

        private var fitted: [String: (width: Double, at: TimeInterval)] = [:]
        private var narrowed: [String: TimeInterval] = [:]

        public init() {}

        /// Why `id` must not be fitted now, or nil. `calibratedAt`: when a calibration last ran (-infinity if never).
        public func refusal(_ id: String, now: TimeInterval, calibratedAt: TimeInterval) -> String? {
            if now - calibratedAt < Self.afterCalibration { return "calibration just ended" }
            if let t = narrowed[id], now - t < Self.window { return "a fit narrowed it \(Int(now - t)) s ago" }
            return nil
        }

        /// The width each pane of the row keeps: its fitted width when it was fitted within `window`, else 0. The
        /// pane `focus` is about to be fitted itself and keeps nothing.
        public func floors(_ ids: [String], focus k: Int, now: TimeInterval) -> [Double] {
            ids.indices.map { i in
                guard i != k, let f = fitted[ids[i]], now - f.at < Self.window else { return 0 }
                return f.width
            }
        }

        /// Whether a planned fit is worth making: it reaches `width`, or no recently fitted pane held it back.
        public static func allows(planned: [Double], focus k: Int, width: Double, floors: [Double]) -> Bool {
            guard planned.indices.contains(k) else { return false }
            return planned[k] >= width - PaneWidths.tolerance || !floors.contains { $0 > 0 }
        }

        /// A fit of `id` to `width` ran; `narrowed` are the panes it took width from.
        public mutating func noteFit(_ id: String, width: Double, narrowed ids: [String], at now: TimeInterval) {
            fitted[id] = (width, now)
            narrowed[id] = nil
            for n in ids { narrowed[n] = now; fitted[n] = nil }
        }

        /// The owner asked for a layout (maximize, even out): earlier fits no longer hold anything.
        public mutating func reset() { fitted = [:]; narrowed = [:] }
    }

    /// Once per focus change, after focus has rested on one session for `settle`.
    public struct Trigger: Sendable {
        private var session: String?
        private var since: TimeInterval = 0
        private var fired = false

        public init() {}

        /// The session to fit now, or nil. Feed it the focused session on every tick; it answers once per focus
        /// change, and only after that session has been the focus for `settle` seconds.
        public mutating func observe(_ focused: String?, at t: TimeInterval) -> String? {
            if focused != session { session = focused; since = t; fired = false }
            guard let id = session, !fired, t - since >= SessionFit.settle else { return nil }
            fired = true
            return id
        }
    }
}

/// Claude's chat column, read from the accessibility tree.
///
/// In a pane wider than the column, the column is an element centred in the transcript with empty space on both
/// sides; in a narrower pane it fills the transcript and the column's own width cannot be seen. So the column is
/// read from whichever pane is wide enough to show it, remembered, and `SessionFit.fallbackColumn` stands in until
/// one is.
public enum ChatColumn {
    /// Wider than any text measure Claude offers (1280 pt plus gutters); larger readings are not the column.
    static let widest: Double = 1400
    /// Narrower than any Claude offers; smaller readings are a message bubble or a card, not the column.
    static let narrowest: Double = 600
    /// The column must leave at least this much empty transcript beside it, so a pane only a little wider than its
    /// column (where padding and the column are hard to tell apart) is never read.
    static let slack: Double = 96
    /// How far off the transcript's centre the column may sit (a scrollbar or uneven gutters).
    static let offCentre: Double = 12

    /// The column's width in one pane: the widest element under the transcript that is centred in it and leaves
    /// `slack` beside it. nil when the pane is not wide enough to show the column.
    public static func measure(transcript: CGRect, elements: [CGRect]) -> Double? {
        guard transcript.width > 0, transcript.minX.isFinite else { return nil }
        let fits = elements.filter { e in
            let w = Double(e.width)
            return w >= narrowest && w <= widest && Double(transcript.width) - w >= slack
                && abs(Double(e.midX - transcript.midX)) <= offCentre
        }
        return fits.map { Double($0.width) }.max()
    }

    /// How wide a pane must be for its transcript to show the whole column: the column plus whatever the pane holds
    /// beside its transcript (borders, a scrollbar), read from that pane. A transcript that cannot be read, or reads
    /// wider than its pane, adds nothing.
    public static func paneWidth(column: Double, pane: CGRect, transcript: CGRect?) -> Double {
        guard let t = transcript, t.width > 0 else { return column }
        let beside = Double(pane.width - t.width)
        return column + (beside >= 0 && beside <= 200 ? beside : 0)
    }

    /// The widest column read reliably, kept: a reading counts only when it is one of Claude's own columns (its
    /// three transcript widths with their gutters, `known`) or when panes at least `spread` apart in width read the
    /// same column. A reading that follows the pane's width is padding, not the column: on 2026-10-15 a pane of
    /// 742 to 960 pt read as its own width less 128, and taking each latest reading shrank the column 832, 736, 646.
    public struct Memory: Sendable {
        /// Claude's 768, 960 and 1280 pt text measures with their 32 pt gutters.
        public static let known: [Double] = [832, 1024, 1344]
        static let match: Double = 4
        static let spread: Double = 64
        static let kept = 12

        public private(set) var measured: Double?
        private var seen: [(column: Double, pane: Double)] = []

        public init() {}
        public var width: Double { measured ?? SessionFit.fallbackColumn }

        /// One scan's readings, one per pane, with each pane's width.
        public mutating func note(_ readings: [Double?], panes: [Double]) {
            for (r, pane) in zip(readings, panes) {
                guard let r, r.isFinite, pane.isFinite else { continue }
                let known = Self.known.contains { abs($0 - r) <= Self.match }
                let agreed = seen.contains { abs($0.column - r) <= Self.match && abs($0.pane - pane) >= Self.spread }
                if known || agreed { measured = max(measured ?? 0, r) }
                seen.append((r, pane))
                if seen.count > Self.kept { seen.removeFirst(seen.count - Self.kept) }
            }
        }
    }
}
