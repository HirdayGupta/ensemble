import EnsembleCore

/// Implemented by the tour while its gesture-practice step is open. The coordinator routes real gesture
/// intents here instead of acting on Claude: nothing is pressed, dictated or sent.
@MainActor
protocol TourPracticeSink: AnyObject {
    func tourPractice(intent: GestureIntent)
    /// Every hand reading, with its joint coordinates, for the skeleton inset. Points only; no image reaches the tour.
    func tourPractice(hand: HandObservation)
}
