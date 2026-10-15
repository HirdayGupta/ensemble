import Foundation

/// The peace sign and the scissors, read from the two-fingers pose and how far apart its fingertips are.
///
/// Peace: index and middle out and apart. Held `maximizeHold` it asks to maximize the session under the nose.
/// Scissors: the same two fingers closing together within `scissorsWindow` of opening. The two windows are the
/// same length, so one raised peace sign is exactly one of them: closed in time it is a scissors, held on it is
/// a maximize, and a peace that already maximized never also counts as a scissors when it closes.
///
/// Spread is the index-to-middle fingertip distance in palm lengths (wrist to middle knuckle). Measured on the recorded
/// two-fingers hold (fingers side by side, 179 frames): 0.22-0.30 for the middle 80 percent, at most 0.31, the fingers
/// about 9 degrees apart. Opening them into a V adds roughly two finger lengths times the sine of half the extra angle,
/// so 0.36 is reached about 14 degrees apart and a usual V (25 to 40 degrees) reads 0.5-0.75. An open threshold at
/// 0.30 maximized twice on that side-by-side hold; 0.42 (the first, unmeasured value) needed a wide V.
/// Closing (the scissors) counts relative to how wide this V opened: the spread falls to half its open peak, or to
/// `closedSpread`, the median of fingers held side by side, whichever is higher, so a narrow V that closes to side
/// by side counts as surely as a wide one. Between open and closed the last state holds, and every edge needs
/// `edgeFrames` frames in a row, as the pinch does.
public struct WidthGestures {
    public static let openSpread = 0.36
    public static let closedSpread = 0.28
    /// Closed once the spread has fallen to this fraction of the V's open peak.
    public static let closeRatio = 0.5
    static let edgeFrames = 2
    public static let maximizeHold = 0.6
    public static let scissorsWindow = 0.6
    /// A frame or two of another pose (a blur, a misread finger) does not end the gesture; longer does.
    static let maxGap = 0.2
    /// After acting, the next gesture waits this long, so a hand settling back is never read as a second one.
    static let cooldown = 1.0

    private var openCount = 0
    private var firstOpenT: TimeInterval?
    private var openSince: TimeInterval?
    /// The widest the V has held for `edgeFrames` frames in a row, so one misread frame never raises it.
    private var peak = 0.0
    private var lastSpread = 0.0
    private var closedCount = 0
    private var fired = false
    private var lastSeen: TimeInterval?
    private var lastActAt: TimeInterval = -.infinity
    /// Set while gestures may not act (dictating, turned off): a two-fingers pose already up then has to drop first.
    private var needsRelease = false

    public init() {}

    /// A peace sign is open right now (counting toward a maximize or waiting for a scissors close).
    public var peaceOpen: Bool { openSince != nil }

    public mutating func reset() {
        endRun()
        lastActAt = -.infinity
        needsRelease = false
    }

    /// `maximize` and `evenOut` say which of the two are on; `allowed` is false while nothing may act (dictating).
    public mutating func push(t: TimeInterval, pose: Pose?, spread: Double?, maximize: Bool, evenOut: Bool,
                              allowed: Bool) -> GestureIntent? {
        guard allowed, maximize || evenOut else {
            if pose == .twoFingers { needsRelease = true }
            endRun()
            return nil
        }
        guard pose == .twoFingers, let spread, spread.isFinite else {
            needsRelease = false
            if let last = lastSeen, t - last > Self.maxGap { endRun() }
            return nil
        }
        guard !needsRelease else { return nil }
        if let last = lastSeen, t - last > Self.maxGap { endRun() }
        lastSeen = t
        guard t - lastActAt >= Self.cooldown else { return nil }

        defer { lastSpread = spread }
        guard let since = openSince else {
            if spread >= Self.openSpread {
                if openCount == 0 { firstOpenT = t }
                openCount += 1
                if openCount >= Self.edgeFrames {
                    openSince = firstOpenT
                    peak = min(spread, lastSpread)
                }
            } else {
                openCount = 0
                firstOpenT = nil
            }
            return nil
        }
        peak = max(peak, min(spread, lastSpread))
        closedCount = spread <= max(Self.closedSpread, peak * Self.closeRatio) ? closedCount + 1 : 0
        if closedCount >= Self.edgeFrames {
            let inTime = !fired && t - since <= Self.scissorsWindow
            endRun()
            guard inTime, evenOut else { return nil }
            lastActAt = t
            return .evenOutSessions
        }
        if !fired, closedCount == 0, t - since >= Self.maximizeHold {
            fired = true
            guard maximize else { return nil }
            lastActAt = t
            return .maximizeSession
        }
        return nil
    }

    private mutating func endRun() {
        openCount = 0
        firstOpenT = nil
        openSince = nil
        peak = 0
        lastSpread = 0
        closedCount = 0
        fired = false
        lastSeen = nil
    }
}
