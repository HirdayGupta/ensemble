import Foundation

/// The peace sign and the scissors, read from the two-fingers pose and how far apart its fingertips are.
///
/// Peace: index and middle out and apart. Held `maximizeHold` it asks to maximize the session under the nose.
/// Scissors: the same two fingers closing together within `scissorsWindow` of opening. The two windows are the
/// same length, so one raised peace sign is exactly one of them: closed in time it is a scissors, held on it is
/// a maximize, and a peace that already maximized never also counts as a scissors when it closes.
///
/// Spread is the index-to-middle fingertip distance in palm lengths (wrist to middle knuckle). Fingers held
/// side by side read 0.02-0.31 in the recorded fixtures (the two-fingers hold and desk life), so a peace needs
/// `openSpread`, well above that, and a scissors needs the fingers back under `closedSpread`. Between the two
/// the last state holds (hysteresis), and every edge needs `edgeFrames` frames in a row, as the pinch does.
public struct WidthGestures {
    public static let openSpread = 0.42
    public static let closedSpread = 0.24
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

        guard let since = openSince else {
            if spread >= Self.openSpread {
                if openCount == 0 { firstOpenT = t }
                openCount += 1
                if openCount >= Self.edgeFrames { openSince = firstOpenT }
            } else {
                openCount = 0
                firstOpenT = nil
            }
            return nil
        }
        closedCount = spread <= Self.closedSpread ? closedCount + 1 : 0
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
        closedCount = 0
        fired = false
        lastSeen = nil
    }
}
