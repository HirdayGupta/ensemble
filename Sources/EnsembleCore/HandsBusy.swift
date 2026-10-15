import CoreGraphics
import Foundation

/// When to step back: while your hands are on the keyboard, mouse or trackpad, Ensemble moves no focus, moves no
/// highlight and acts on no gesture, so working by hand never meets a surprise. Fed once per tick with when each
/// kind of hardware input last happened, on the same clock as `now`.
public struct HandsBusy: Equatable {
    public static let defaultQuiet = 2.0
    public static let quietRange: ClosedRange<Double> = 1...5
    /// A pointer that drifts less than this from where it rested is a nudged desk, not use.
    public static let moveThreshold: CGFloat = 4
    /// A key read within this of a key Ensemble consumed or posted itself is that key.
    public static let ownKeyWindow = 0.25
    /// Ensemble's own scroll moves the pointer and puts it back; movement this close to one is not counted.
    public static let ownPointerWindow = 0.15

    /// Seconds with no input before Ensemble acts again.
    public var quiet: Double
    public private(set) var lastInputAt: TimeInterval = -.infinity
    private var anchor: CGPoint?
    private var lastMoveSeen: TimeInterval = -.infinity

    public init(quiet: Double = HandsBusy.defaultQuiet) { self.quiet = quiet }

    /// One reading. `keyAt`, `clickAt`, `scrollAt` and `moveAt` are when that hardware input last happened;
    /// `ownKeyAt` when Ensemble last consumed (a Return it held back) or posted a key; `ownPointerAt` when it last
    /// moved the pointer for its own scroll. Returns whether Ensemble is paused.
    @discardableResult
    public mutating func update(now: TimeInterval, keyAt: TimeInterval, clickAt: TimeInterval, scrollAt: TimeInterval,
                                moveAt: TimeInterval, pointer: CGPoint, ownKeyAt: TimeInterval = -.infinity,
                                ownPointerAt: TimeInterval = -.infinity) -> Bool {
        if abs(keyAt - ownKeyAt) > Self.ownKeyWindow { note(keyAt) }
        note(clickAt)
        note(scrollAt)
        let movedSinceLast = moveAt > lastMoveSeen
        lastMoveSeen = max(lastMoveSeen, moveAt)
        let ownMove = now - ownPointerAt < Self.ownPointerWindow
        if let a = anchor, movedSinceLast, !ownMove {
            // Slow, steady movement adds up from where the pointer last rested, so it still counts.
            if hypot(pointer.x - a.x, pointer.y - a.y) > Self.moveThreshold {
                note(moveAt)
                anchor = pointer
            }
        } else {
            anchor = pointer
        }
        return isPaused(at: now)
    }

    public func isPaused(at now: TimeInterval) -> Bool { now - lastInputAt < quiet }

    private mutating func note(_ t: TimeInterval) {
        if t.isFinite, t > lastInputAt { lastInputAt = t }
    }
}
