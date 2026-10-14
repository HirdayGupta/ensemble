import CoreGraphics
import Foundation

/// Turns the stream of per-frame hand readings into intents. Pure: time comes only from the
/// observations and from `tick(now:)`, so it replays deterministically.
public final class GestureMachine {
    public var mapping: GestureMapping
    public private(set) var talking = false

    // Timing rules (seconds).
    static let talkHold = 0.3
    static let talkArmWindow = 1.5
    static let releaseHold = 0.4
    static let handLostHold = 0.6
    static let staleHold = 1.0
    static let sendHold = 0.3
    static let sendAfterTalkEnd = 0.5
    static let cancelHold = 0.3
    static let scrollHold = 0.2

    // Scroll: palm speed in frame-heights per second. Above the deadzone the excess is integrated
    // and scaled so a brisk 0.3-frame motion over ~0.5 s scrolls about 600 points.
    static let scrollDeadzone = 0.1
    static let scrollPointsPerFrameHeight = 2400.0
    static let scrollSmoothing = 0.5
    static let scrollMaxGap = 0.2

    /// A continuous stretch of one pose. `startedWhileTalking` taints it for send/cancel so the pose
    /// that ends a dictation hold can never also trigger an action.
    private struct Run {
        var pose: Pose
        var start: TimeInterval
        var startedWhileTalking: Bool
        var armed: Bool
        var fired = false
        var lastPalm: CGPoint?
        var lastT: TimeInterval
        var velocity = 0.0
    }

    private var run: Run?
    private var lastOtherPresentT: TimeInterval?     // last present frame whose pose was not the talk pose
    private var releaseStart: TimeInterval?
    private var absentStart: TimeInterval?
    private var lastPushT: TimeInterval?
    private var lastTalkEndT: TimeInterval?

    public init(mapping: GestureMapping = .init()) { self.mapping = mapping }

    public func reset() {
        talking = false
        run = nil
        lastOtherPresentT = nil
        releaseStart = nil
        absentStart = nil
        lastPushT = nil
        lastTalkEndT = nil
    }

    public func push(_ h: HandObservation) -> [GestureIntent] {
        lastPushT = h.t
        var intents: [GestureIntent] = []

        guard h.present else {
            run = nil
            releaseStart = nil
            absentStart = absentStart ?? h.t
            if talking, let since = absentStart, h.t - since >= Self.handLostHold {
                endTalk(.handLost, at: h.t, into: &intents)
            }
            return intents
        }
        absentStart = nil

        let pose = h.pose
        if pose != mapping.talk { lastOtherPresentT = h.t }

        guard let pose else {
            run = nil
            trackRelease(isTalkPose: false, at: h.t, into: &intents)
            return intents
        }

        if run?.pose != pose {
            let armed = pose == mapping.talk && (lastOtherPresentT.map { h.t - $0 <= Self.talkArmWindow } ?? false)
            run = Run(pose: pose, start: h.t, startedWhileTalking: talking, armed: armed, lastPalm: h.palmCenter, lastT: h.t)
        }
        trackRelease(isTalkPose: pose == mapping.talk, at: h.t, into: &intents)
        guard var r = run else { return intents }
        let held = h.t - r.start

        if pose == mapping.talk {
            if !talking, r.armed, held >= Self.talkHold {
                talking = true
                releaseStart = nil
                intents.append(.talkBegan)
            }
        } else if !talking {
            if pose == mapping.send, !r.startedWhileTalking, !r.fired, held >= Self.sendHold,
               lastTalkEndT.map({ h.t - $0 >= Self.sendAfterTalkEnd }) ?? true {
                r.fired = true
                intents.append(.sendRequested)
            } else if pose == mapping.cancel, !r.startedWhileTalking, !r.fired, held >= Self.cancelHold {
                r.fired = true
                intents.append(.cancelRequested)
            } else if pose == mapping.scroll {
                if let dy = scrollDelta(&r, h: h, held: held) { intents.append(.scroll(dy: dy)) }
            }
        }
        r.lastPalm = h.palmCenter ?? r.lastPalm
        r.lastT = h.t
        run = r
        return intents
    }

    /// Call on a timer. Ends a dictation hold when the camera stopped delivering frames.
    public func tick(now: TimeInterval) -> [GestureIntent] {
        guard talking, let last = lastPushT, now - last >= Self.staleHold else { return [] }
        var intents: [GestureIntent] = []
        endTalk(.stale, at: now, into: &intents)
        return intents
    }

    private func trackRelease(isTalkPose: Bool, at t: TimeInterval, into intents: inout [GestureIntent]) {
        guard talking else { releaseStart = nil; return }
        if isTalkPose { releaseStart = nil; return }
        releaseStart = releaseStart ?? t
        if let since = releaseStart, t - since >= Self.releaseHold {
            endTalk(.released, at: t, into: &intents)
        }
    }

    private func endTalk(_ reason: TalkEndReason, at t: TimeInterval, into intents: inout [GestureIntent]) {
        talking = false
        releaseStart = nil
        absentStart = nil
        lastTalkEndT = t
        // On release the current run stays, still marked as started while talking. After a lost hand
        // or stale camera the next closed hand is a new arrival, not an open-to-fist transition.
        if reason != .released { run = nil; lastOtherPresentT = nil }
        intents.append(.talkEnded(reason))
    }

    private func scrollDelta(_ r: inout Run, h: HandObservation, held: TimeInterval) -> Double? {
        guard let palm = h.palmCenter, let prev = r.lastPalm else { return nil }
        let dt = h.t - r.lastT
        guard dt > 0, dt <= Self.scrollMaxGap else { return nil }
        let instant = Double(palm.y - prev.y) / dt
        r.velocity += Self.scrollSmoothing * (instant - r.velocity)
        guard held >= Self.scrollHold, abs(r.velocity) > Self.scrollDeadzone else { return nil }
        let excess = abs(r.velocity) - Self.scrollDeadzone
        return (r.velocity > 0 ? 1 : -1) * excess * dt * Self.scrollPointsPerFrameHeight
    }
}
