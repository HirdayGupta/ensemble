import Foundation

public enum HandClassifierAdapter {
    /// Maps one Sleight hand reading to a `HandObservation`. Swipes are not used by Clutch.
    public static func observation(from hand: Hand?, at t: TimeInterval, classifier: GestureClassifier) -> HandObservation {
        guard let hand else { return HandObservation(t: t, present: false, pose: nil, palmCenter: nil) }
        return HandObservation(t: t, present: true, pose: pose(for: classifier.classify(hand)), palmCenter: hand.palmCenter)
    }

    static func pose(for gesture: Gesture?) -> Pose? {
        switch gesture {
        case .openPalm: return .openPalm
        case .fist: return .fist
        case .twoFingers: return .twoFingers
        case .thumbsUp: return .thumbsUp
        case .pointUp: return .pointUp
        case .pointDown: return .pointDown
        case .swipeLeft, .swipeRight, .none: return nil
        }
    }
}
