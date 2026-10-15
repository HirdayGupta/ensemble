import Foundation

/// Turns real gesture intents, routed here instead of to Claude while the tour's practice step is open, into
/// "this tab is done" signals. Dictate needs a full start-then-stop pair, so a `talkBegan` alone does not
/// finish it; a `talkEnded` with no matching `talkBegan` (left over from a previous tab) does not either.
public final class TourPracticeDetector {
    private var sawTalkBegan = false

    public init() {}

    /// Called when the practiced tab changes, so an intent left over from the previous tab cannot complete the next one.
    public func reset() {
        sawTalkBegan = false
    }

    public func observe(_ intent: GestureIntent) -> TourGestureTab? {
        switch intent {
        case .talkBegan:
            sawTalkBegan = true
            return nil
        case .talkEnded:
            defer { sawTalkBegan = false }
            return sawTalkBegan ? .dictate : nil
        case .sendRequested:
            return .send
        case .dragScroll:
            return .scroll
        case .cancelRequested, .scroll, .dragScrollEnded:
            return nil
        }
    }
}

/// Marks the Look tab done once the head has turned away from forward and come back, from head yaw readings
/// alone (a camera's own small jitter around centre never finishes it, and the sign of yaw carries no fixed
/// meaning, so only its magnitude is used).
public final class TourLookDetector {
    /// Beyond this many radians counts as "turned away".
    public static let awayThreshold = 0.22
    /// Back within this many radians counts as "facing forward again".
    public static let homeThreshold = 0.08

    private var turnedAway = false
    public private(set) var done = false

    public init() {}

    public func reset() {
        turnedAway = false
        done = false
    }

    /// Returns true the moment this reading completes the gesture (once, not on every later reading).
    @discardableResult
    public func observe(yaw: Double) -> Bool {
        guard !done else { return false }
        let a = abs(yaw)
        if !turnedAway, a >= Self.awayThreshold {
            turnedAway = true
        } else if turnedAway, a <= Self.homeThreshold {
            done = true
            return true
        }
        return false
    }
}
