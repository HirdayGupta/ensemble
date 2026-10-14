import Foundation

/// The motion math behind pinch-and-drag scrolling. Hand movement becomes distance to deliver; an exponential
/// glide delivers a fixed share of it each 1/60 s frame (ironing out hand-tracking jitter), and a fast release
/// throws the page with momentum, like a trackpad flick. Pure: the caller supplies time and input state.
public struct ScrollGlide {
    public static let frameRate = 60.0
    static let ease = 0.2                  // share of the remaining distance delivered per frame
    static let upStrokeGain = 1.6          // upward pinch strokes are naturally shorter than downward ones
    static let flickThreshold = 2500.0     // points per second at release to start momentum
    static let maxFlick = 15000.0
    static let friction = 0.955            // momentum kept per frame
    static let coastFloor = 60.0           // momentum below this points per second is dropped
    static let flickWindow = 0.12          // seconds of recent output that give the release velocity

    private var pending = 0.0
    private var remaining = 0.0
    private var recent: [(t: TimeInterval, dy: Double)] = []
    /// Momentum after a fast release, in points per second. A slow release stops dead.
    public private(set) var inertia = 0.0

    public init() {}

    /// Hand travel in points, upward strokes weighted up.
    public static func shaped(handDy: Double) -> Double { handDy > 0 ? handDy * upStrokeGain : handDy }

    public mutating func add(_ dy: Double, at t: TimeInterval) {
        pending += dy
        recent.append((t, dy))
    }

    /// A new drag catches a coasting page.
    public mutating func catchPage() { inertia = 0 }

    /// Moves the distance gathered since the last call into the glide. True when there was some.
    public mutating func flush() -> Bool {
        guard pending != 0 else { return false }
        remaining += pending
        pending = 0
        return true
    }

    /// The pinch is gone: forgets the undelivered distance and returns the momentum when the last
    /// `flickWindow` seconds of output were fast enough (and the page can coast), else nil.
    public mutating func release(at now: TimeInterval, canCoast: Bool) -> Double? {
        recent.removeAll { now - $0.t > Self.flickWindow }
        let v = recent.reduce(0) { $0 + $1.dy } / Self.flickWindow
        recent.removeAll()
        pending = 0; remaining = 0
        if abs(v) >= Self.flickThreshold, canCoast {
            inertia = max(-Self.maxFlick, min(Self.maxFlick, v))
            return inertia
        }
        inertia = 0
        return nil
    }

    /// One frame: the distance to deliver now, or nil when nothing is left (the loop should stop). Momentum is
    /// stopped by a held pinch, by hands on the keyboard, mouse or trackpad, or when it dies out.
    public mutating func nextStep(pinchHeld: Bool, secondsSinceInput: @autoclosure () -> TimeInterval, hasTarget: Bool) -> Double? {
        if inertia != 0 {
            if pinchHeld || secondsSinceInput() < 0.2 || abs(inertia) < Self.coastFloor { inertia = 0 }
            else { remaining += inertia / Self.frameRate; inertia *= Self.friction }
        }
        guard abs(remaining) >= 0.5 || inertia != 0, hasTarget else {
            remaining = 0
            return nil
        }
        return remaining * Self.ease
    }

    /// Whole pixels only; the fraction stays in the glide so nothing is lost.
    public mutating func take(_ step: Double) -> Double {
        let px = step.rounded() != 0 ? step.rounded() : (step > 0 ? 1 : -1)
        remaining -= px
        return px
    }

    public mutating func reset() {
        pending = 0; remaining = 0; inertia = 0
        recent.removeAll()
    }
}
