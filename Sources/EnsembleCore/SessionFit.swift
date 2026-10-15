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
    /// the others and none of them below `minimum`. When the others cannot give it all, the pane gets what they can.
    /// nil when the pane is already within `PaneWidths.tolerance` of `width`, or the others have nothing to give.
    public static func widths(current: [Double], focus k: Int, width: Double,
                              minimum: Double = PaneWidths.narrowWidth) -> [Double]? {
        guard current.count >= 2, current.indices.contains(k), width.isFinite, current.allSatisfy(\.isFinite) else { return nil }
        let need = width - current[k]
        guard need > PaneWidths.tolerance else { return nil }
        var room = current.map { max(0, $0 - minimum) }
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

    /// The column measured last, while Claude keeps it; a later reading replaces it, so a changed transcript width
    /// setting is picked up the next time a wide pane is on screen.
    public struct Memory: Sendable {
        public private(set) var measured: Double?
        public init() {}
        public var width: Double { measured ?? SessionFit.fallbackColumn }
        /// Takes the widest of this scan's readings, one per pane, when any pane showed the column.
        public mutating func note(_ readings: [Double?]) {
            if let w = readings.compactMap({ $0 }).max() { measured = w }
        }
    }
}
