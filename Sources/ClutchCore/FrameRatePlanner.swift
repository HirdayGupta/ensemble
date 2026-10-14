import Foundation

/// Decides, for each camera frame, which analyses run. Full rate only where a gesture or a safety check needs it:
/// hand pose every frame while a hand is in view (and for `handHold` s after), otherwise a slow probe; the face
/// tracker at `faceInterval`; and both near zero once no face has been seen for `idleAfter` s. `forceFull` (dictating,
/// a send pending, calibrating, a gesture held) keeps the hand at every frame and cancels the idle slowdown.
/// Not thread-safe; one queue owns it.
public struct FrameRatePlanner {
    public struct Plan: Equatable, Sendable {
        public var runHand: Bool
        public var runFace: Bool
        public var runLight: Bool
    }

    public var handProbeInterval: TimeInterval = 0.125
    public var handHold: TimeInterval = 1.0
    public var faceInterval: TimeInterval = 1.0 / 15.0
    public var idleAfter: TimeInterval = 3.0
    public var idleInterval: TimeInterval = 0.5
    public var lightInterval: TimeInterval = 0.1
    /// A frame may run this much early, so a 15 Hz target on a 30 fps camera lands on every second frame.
    public var slack: TimeInterval = 0.012

    private var startedAt: TimeInterval?
    private var lastHandRun = -TimeInterval.infinity
    private var lastFaceRun = -TimeInterval.infinity
    private var lastLightRun = -TimeInterval.infinity
    private var handPresent = false
    private var lastHandSeen = -TimeInterval.infinity

    public init() {}

    public mutating func plan(now: TimeInterval, forceFull: Bool, lastFaceSeenAt: TimeInterval?) -> Plan {
        if startedAt == nil { startedAt = now }
        let faceReference = max(lastFaceSeenAt ?? -.infinity, startedAt ?? now)
        let idle = !forceFull && now - faceReference > idleAfter

        var runHand = false
        if !idle, forceFull || handPresent || now - lastHandSeen < handHold {
            runHand = true
        } else {
            runHand = now - lastHandRun >= (idle ? idleInterval : handProbeInterval) - slack
        }
        let faceEvery = idle ? idleInterval : faceInterval
        let runFace = now - lastFaceRun >= faceEvery - slack
        let runLight = now - lastLightRun >= lightInterval - slack

        if runHand { lastHandRun = now }
        if runFace { lastFaceRun = now }
        if runLight { lastLightRun = now }
        return Plan(runHand: runHand, runFace: runFace, runLight: runLight)
    }

    /// The result of a hand analysis the plan asked for.
    public mutating func noteHand(present: Bool, at t: TimeInterval) {
        handPresent = present
        if present { lastHandSeen = t }
    }
}
