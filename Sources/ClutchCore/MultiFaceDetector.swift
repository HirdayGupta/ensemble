import Foundation

/// Decides whether a second person is really in view. A single two-face reading is usually a false alarm
/// (one in 150 readings in a typical session), so it counts only once at least `minReadings` readings with
/// two or more faces fall within the last `window` seconds.
public struct MultiFaceDetector: Sendable {
    public static let window: TimeInterval = 1.0
    public static let minReadings = 5

    private var times: [TimeInterval] = []

    public init() {}

    public mutating func record(faceCount: Int, at t: TimeInterval) {
        if faceCount > 1 { times.append(t) }
        times.removeAll { t - $0 > Self.window }
    }

    public func isActive(now: TimeInterval) -> Bool {
        times.reduce(0) { now - $1 <= Self.window ? $0 + 1 : $0 } >= Self.minReadings
    }
}
