import Foundation
import Vision

enum Gesture: String, CaseIterable {
    case openPalm, fist, twoFingers, thumbsUp
    case swipeLeft, swipeRight   // dynamic, produced by SwipeDetector

    var isSwipe: Bool { self == .swipeLeft || self == .swipeRight }
}

/// Everything the classifier derived from one hand, for the debug view.
struct HandFeatures {
    var index, middle, ring, little: Bool
    var curled: Int              // fingers folded back past their PIP (see `GestureClassifier.curlRatio`)
    var tipReach: CGFloat        // farthest fingertip from the wrist, in palm lengths
    var thumbStraight, thumbClear, thumbUp: Bool
    var extent: CGFloat          // landmark bounding-box diagonal, fraction of frame
    var palm: CGFloat            // wrist → middle MCP, fraction of frame; the unit every finger test is normalized by
    var span: CGFloat            // knuckle width (index MCP → little MCP) in palm lengths; see `maxPalmSpan`
    var upright: CGFloat         // middle knuckle above the wrist, in palm lengths; see `minUpright`
    var tooSmall: Bool           // pose rejected because the hand is too far away
    var angled: Bool             // pose rejected because the palm does not face the camera or points down
    var thumb: Bool { thumbStraight && thumbClear }
    var extendedCount: Int { [index, middle, ring, little].filter { $0 }.count }
    /// Enough fingers extended to count as an open hand; swipes only track open hands.
    var isOpen: Bool { extendedCount >= 3 }
    var gesture: Gesture?
}

/// Rule-based static pose classifier on Vision hand landmarks.
/// All distances are normalized by hand size (wrist → middle MCP) for scale invariance.
struct GestureClassifier {
    /// Open-finger poses (open palm, two fingers) need at least this hand extent. Deliberate open
    /// palms measure 0.33 at arm's length and 0.21 one step back; the floor only rejects hands
    /// farther than that. Distance no longer separates gestures from desk hands (an open hand
    /// held up while talking reaches 0.29), `maxPalmSpan` does.
    var minOpenExtent: CGFloat = 0.19
    /// Closed poses (fist, thumbs up) need this much. A fist is compact, about 0.6 of an open
    /// palm's extent at the same distance: 0.19 at arm's length, 0.12 one step back.
    var minClosedExtent: CGFloat = 0.11

    /// Knuckle width over palm length, at most, for open palm, fist and two fingers. A palm facing
    /// the camera keeps its full wrist-to-knuckle length and measures 0.37–0.58 in every fixture at
    /// both distances. A hand on the desk or gesturing while talking is seen at an angle, its palm
    /// length foreshortens and the ratio grows: 0.64–0.72 for the open hand that fired at extent
    /// 0.22, 0.6–1.9 for idle hands generally. Every size-normalized finger test above also
    /// assumes an unforeshortened palm, so this is the precondition for trusting them. Thumbs up is
    /// exempt: the hand is edge-on by nature (1.3–1.7).
    static let maxPalmSpan: CGFloat = 0.6

    /// A finger is extended when its tip reaches past 1.15× its PIP distance from the wrist, and
    /// curled when it folds back inside 0.85×. In between is a relaxed finger: a hand on a mouse or
    /// keyboard is all relaxed fingers (idle fixture: ratios 0.84–1.15) and used to read as a fist,
    /// while every deliberate fist, thumbs up and two-fingers frame folds its closed fingers to
    /// 0.41–0.84. Closed poses therefore require curled fingers, not merely non-extended ones.
    static let extendRatio: CGFloat = 1.15
    static let curlRatio: CGFloat = 0.85

    /// A fist also keeps every fingertip inside the palm: within this many palm lengths of the
    /// wrist (fixture fists 0.61–0.77 at both distances). Fingers hanging over a mouse or keyboard
    /// curl past their PIP too, but from beyond the knuckles (0.99–1.28), and a relaxed closed hand
    /// resting on the desk sits between (dogfood fixtures: 0.81–0.90 for their whole hold). Thumbs
    /// up is exempt: the hand is turned edge-on, so its folded fingers project past the knuckles
    /// (1.05–1.43).
    static let fistTipReach: CGFloat = 0.8

    /// An open palm's fingertips reach at most this many palm lengths from the wrist: a finger is
    /// about one palm long, so a camera-facing open hand measures 1.8–2.0 (fixtures at both
    /// distances: median 1.85–2.03, p95 ≤ 2.08). A hand pitched about its knuckle axis (resting on
    /// the desk, seen from above) foreshortens the palm but not the fingers and reads 2.1–3.0; the
    /// span gate cannot see pitch, only yaw. Dogfood open-palm misfires: median 2.18–2.92.
    static let maxOpenTipReach: CGFloat = 2.1

    /// The middle knuckle must sit this many palm lengths above the wrist: a gesture made toward
    /// the camera is upright. Every fixture pose measures ≥ 0.97, thumbs up (edge-on) ≥ 0.46. The
    /// right hand resting at the frame edge points its fingers down (dogfood: -0.5 to -1.0) and
    /// a fifth of the idle fixture's hands do too.
    static let minUpright: CGFloat = 0.3

    func classify(_ hand: Hand) -> Gesture? { features(hand)?.gesture }

    func features(_ hand: Hand) -> HandFeatures? {
        guard let wrist = hand[.wrist], let midMCP = hand[.middleMCP] else { return nil }
        let size = dist(wrist, midMCP)
        guard size > 0.01 else { return nil }

        // Tip distance from the wrist relative to the PIP's: >1.15 extended, <0.85 curled.
        func reach(tip: Joint, pip: Joint) -> CGFloat? {
            guard let t = hand[tip], let p = hand[pip] else { return nil }
            let d = dist(p, wrist)
            return d > 0 ? dist(t, wrist) / d : nil
        }
        guard let index = reach(tip: .indexTip, pip: .indexPIP),
              let middle = reach(tip: .middleTip, pip: .middlePIP),
              let ring = reach(tip: .ringTip, pip: .ringPIP),
              let little = reach(tip: .littleTip, pip: .littlePIP),
              let thumbTip = hand[.thumbTip], let thumbIP = hand[.thumbIP],
              let indexMCP = hand[.indexMCP], let littleMCP = hand[.littleMCP]
        else { return nil }
        let reaches = [index, middle, ring, little]
        let ext = reaches.map { $0 > Self.extendRatio }
        let curl = reaches.map { $0 < Self.curlRatio }
        let tipReach = [Joint.indexTip, .middleTip, .ringTip, .littleTip]
            .compactMap { hand[$0] }.map { dist($0, wrist) / size }.max() ?? 0

        // Thumb: extended when straight and clear of the index knuckle (a tucked thumb sits on it).
        let thumbStraight = dist(thumbTip, wrist) > dist(thumbIP, wrist) * 1.1
        let thumbClear = dist(thumbTip, indexMCP) / size > 0.6
        var f = HandFeatures(index: ext[0], middle: ext[1], ring: ext[2], little: ext[3],
                             curled: curl.filter { $0 }.count, tipReach: tipReach,
                             thumbStraight: thumbStraight, thumbClear: thumbClear,
                             thumbUp: thumbTip.y > indexMCP.y + 0.3 * size,
                             extent: hand.extent, palm: size, span: dist(indexMCP, littleMCP) / size,
                             upright: (midMCP.y - wrist.y) / size, tooSmall: false, angled: false)
        let n = f.extendedCount
        // Open palm ignores the thumb: a relaxed palm keeps it alongside the index (measured
        // 0.26–0.47 hand-widths from the index MCP, same range as a fist), so it carries no signal.
        if n == 4 && tipReach <= Self.maxOpenTipReach { f.gesture = .openPalm }
        else if f.curled == 4 && !f.thumb && tipReach < Self.fistTipReach { f.gesture = .fist }
        else if ext[0] && ext[1] && curl[2] && curl[3] { f.gesture = .twoFingers }
        else if f.curled == 4 && f.thumb && f.thumbUp { f.gesture = .thumbsUp }

        if let g = f.gesture {
            let floor = (g == .openPalm || g == .twoFingers) ? minOpenExtent : minClosedExtent
            if f.extent < floor { f.tooSmall = true; f.gesture = nil }
            else if (g != .thumbsUp && f.span > Self.maxPalmSpan) || f.upright < Self.minUpright { f.angled = true; f.gesture = nil }
        }
        return f
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// Emits a gesture only after it has been seen for `holdFrames` consecutive frames.
struct GestureStabilizer {
    let holdFrames: Int
    private(set) var candidate: Gesture?
    private(set) var count = 0
    private(set) var current: Gesture?

    init(holdFrames: Int = 6) { self.holdFrames = holdFrames }

    /// Treat `g` as already fired: it will not fire again until the pose changes away from it.
    mutating func prime(_ g: Gesture?) {
        candidate = g; current = g; count = holdFrames
    }

    /// Returns the newly stabilized gesture on the frame it becomes stable, else nil.
    mutating func push(_ g: Gesture?) -> Gesture? {
        if g == candidate { count += 1 } else { candidate = g; count = 1 }
        if count >= holdFrames && candidate != current {
            current = candidate
            return current
        }
        return nil
    }
}
