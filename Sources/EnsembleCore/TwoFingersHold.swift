import Foundation

/// One log line per two-fingers hold, so a peace sign that does nothing can be measured from the plain log without
/// turning on the trace: how long the hand held the shape, how far apart the fingers were, how often the classifier
/// actually read it as two fingers (and what refused it otherwise), and whether a peace or scissors fired.
///
/// A hold is a stretch of frames with the two-fingers shape (`HandObservation.twoUp`), or read as two fingers, with
/// gaps of at most `maxGap`. Only holds of at least `minHold` are reported. Numbers only, never images.
public struct TwoFingersHold {
    public static let minHold = 0.3
    static let maxGap = 0.2

    private var start: TimeInterval?
    private var last: TimeInterval = 0
    private var spreads: [Double] = []
    private var frames = 0
    private var read = 0
    private var tooFar = 0
    private var angled = 0
    private var heldOff = 0
    private var peace = false
    private var scissors = false

    public init() {}

    public mutating func reset() { self = TwoFingersHold() }

    /// Feed every hand frame. `allowed` is whether the width gestures could act on this frame; `fired` is what they
    /// asked for on it. Returns the summary line when a reportable hold has just ended.
    public mutating func push(_ h: HandObservation, allowed: Bool, fired: GestureIntent?) -> String? {
        let shaped = h.present && (h.twoUp || h.pose == .twoFingers)
        var line: String?
        if start != nil, h.t - last > Self.maxGap {
            line = summary()
            self = TwoFingersHold()
        }
        guard start != nil || shaped else { return line }
        if fired == .maximizeSession { peace = true }
        if fired == .evenOutSessions { scissors = true }
        guard shaped else { return line }
        if start == nil { start = h.t }
        last = h.t
        frames += 1
        if let s = h.fingerSpread, s.isFinite { spreads.append(s) }
        if h.pose == .twoFingers { read += 1 } else if h.gate == .tooFar { tooFar += 1 } else if h.gate == .angled { angled += 1 }
        if !allowed { heldOff += 1 }
        return line
    }

    private func summary() -> String? {
        guard let start, last - start >= Self.minHold, frames > 0 else { return nil }
        let sorted = spreads.sorted()
        let spread = sorted.isEmpty ? "none"
            : String(format: "%.2f/%.2f/%.2f", sorted[0], sorted[sorted.count / 2], sorted[sorted.count - 1])
        func pct(_ n: Int) -> Int { Int((Double(n) * 100 / Double(frames)).rounded()) }
        return String(format: "two fingers held %.1f s, ", last - start)
            + "spread min/median/max \(spread), read as two fingers \(pct(read))%, too far \(pct(tooFar))%, "
            + "angled \(pct(angled))%, held off \(pct(heldOff))%, peace fired \(peace ? "yes" : "no"), "
            + "scissors fired \(scissors ? "yes" : "no")"
    }
}
