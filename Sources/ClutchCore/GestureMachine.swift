import CoreGraphics
import Foundation

/// Turns the stream of per-frame hand readings into intents. Pure: time comes only from the
/// observations and from `tick(now:)`, so it replays deterministically.
public final class GestureMachine {
    public var mapping: GestureMapping
    public private(set) var talking = false
    public var talkStyle: TalkStyle = .doubleTap
    /// doubleTap thresholds, in palm lengths with hysteresis: closed below `pinchClosed`, open again above `pinchOpen`.
    /// Measured on the owner's hand (2026-10-14): a pinch closes to 0.03–0.11 palm lengths, often held 1–2 s, and
    /// between quick taps only reopens to 0.12–0.18; a relaxed hand rests around 0.20–0.26. Single-frame spikes
    /// occur inside a held pinch, so both edges need two frames in a row.
    public var pinchClosed = 0.12
    static let reopenAbove = 0.14            // reopened when above this AND `reopenRise` above the closed minimum
    static let reopenRise = 0.06
    static let edgeFrames = 2
    static let tapMin = 0.05
    static let tapMax = 2.0            // longest a pinch may stay closed and still count as a tap
    /// Second pinch must close within this long after the first opened, else the pair resets. Measured 2026-10-14:
    /// Deliberate pairs leave 0.2–1.5 s between release and the next touch; 0.6 s missed most of them.
    static let tapGap = 1.2
    /// Fingertips brush together while a thumbs-up is lowered; a pinch that closes this soon after one is not a tap
    /// (measured 2026-10-14: a lowered thumbs-up read as a double pinch 2.6 s after a send).
    static let quietAfterSendPose = 0.7
    static let toggleCooldown = 0.8
    private var pinchIsClosed = false
    private var pinchClosedAt: TimeInterval?
    private var pinchMin = 1.0
    /// Pinch and drag scrolls: once a held pinch moves this far (frame heights), it is a drag, never a tap.
    public static let dragStart = 0.03
    /// Scroll points per frame height of hand travel, before the system speed factor the coordinator applies.
    public static let dragPointsPerFrameHeight = 5000.0
    /// Pointer-style acceleration: faster hand motion scrolls disproportionately further (gain 1x at rest,
    /// up to 1 + dragAccel x at one frame height per second).
    public static let dragAccel = 3.0
    private var dragging = false
    private var dragOriginY: Double?
    private var dragLastY: Double?
    private var dragLastT: Double?
    private var dragFilter = OneEuroFilter(minCutoff: 1.0, beta: 2, dCutoff: 1)
    private var dragFilterX = OneEuroFilter(minCutoff: 1.0, beta: 2, dCutoff: 1)
    private var dragOriginX: Double?
    private var dragLastX: Double?
    public private(set) var isDragging = false
    /// A pinch is closed right now (tap, drag or hold in progress): the coordinator holds focus still meanwhile.
    public var pinchHeld: Bool { pinchIsClosed }
    /// The current pinch already toggled on touch; its release must not start a new pair.
    private var pinchToggled = false
    private var edgeCount = 0
    /// The current pinch closed during a quiet period: it may still drag, but never counts as a tap.
    private var pinchSuspect = false
    private var lastSendPoseT: TimeInterval = -.infinity
    private var lastTapEnd: TimeInterval?
    private var lastToggleAt: TimeInterval = -.infinity
    /// gatherBloom: after a start, the hand must first leave the talk pose (or the frame) before a stop counts.
    private var stopArmed = false
    /// gatherBloom: when the talk pose was last held long enough to begin a stop; an open hand soon after stops.
    private var gatheredForStopAt: TimeInterval?
    static let bloomWindow = 1.5

    // Timing rules (seconds).
    static let talkHold = 0.3
    static let talkArmWindow = 1.5
    static let releaseHold = 0.4
    static let handLostHold = 0.6
    static let staleHold = 1.0
    /// Holding the send pose this long sends: the hold itself is the confirmation (settable).
    public var sendHold = 1.5
    /// Going straight from the talk pose to the send pose stops dictation and sends. Held a little longer than
    /// a plain send, and still shorter than `releaseHold`, so it is read before the hold counts as released.
    static let stopAndSendHold = 0.35
    static let sendAfterTalkEnd = 0.5
    static let cancelHold = 0.3
    static let scrollHold = 0.25

    // Scroll: while a pointing pose is held, each frame scrolls speed * frame time. The speed ramps from
    // `scrollMinSpeed` to `scrollMaxSpeed` points per second over `scrollRamp` seconds of scrolling.
    static let scrollMinSpeed = 300.0
    static let scrollMaxSpeed = 1200.0
    static let scrollRamp = 1.5
    static let scrollMaxGap = 0.2

    /// A continuous stretch of one pose. `startedWhileTalking` taints it for send/cancel so the pose
    /// that ends a dictation hold can never also trigger an action.
    private struct Run {
        var pose: Pose
        var start: TimeInterval
        var startedWhileTalking: Bool
        var armed: Bool
        var fired = false
        var stoppedForSend = false     // this send pose already ended a dictation; it may still send
        var lastT: TimeInterval
    }

    private var run: Run?
    private var lastOtherPresentT: TimeInterval?     // last present frame whose pose was not the talk pose
    private var releaseStart: TimeInterval?
    private var absentStart: TimeInterval?
    private var lastPushT: TimeInterval?
    private var lastTalkEndT: TimeInterval?

    public init(mapping: GestureMapping = .init()) { self.mapping = mapping }

    /// The pose currently held and how far its hold has progressed toward acting, for on-screen feedback.
    public var progress: GestureProgress? {
        if talkStyle == .doubleTap {
            if awaitingSecondTap { return GestureProgress(pose: .gather, action: talking ? .stop : .talk, progress: 0.5, willAct: true, active: false) }
            if talking, run?.pose != mapping.send { return GestureProgress(pose: .gather, action: .talk, progress: 1, willAct: true, active: true) }
        }
        guard let r = run else { return nil }
        let held = r.lastT - r.start
        func make(_ action: GestureAction, _ need: Double, _ can: Bool) -> GestureProgress {
            GestureProgress(pose: r.pose, action: action, progress: min(max(held / need, 0), 1), willAct: can, active: false)
        }
        if talkStyle == .gatherBloom, talking {
            if r.pose == mapping.talk && stopArmed { return make(.stop, Self.talkHold, true) }
            if r.pose == mapping.cancel, gatheredForStopAt != nil { return GestureProgress(pose: r.pose, action: .stop, progress: 1, willAct: true, active: true) }
        }
        if r.pose == mapping.talk && talkStyle != .doubleTap {
            if talking { return GestureProgress(pose: r.pose, action: .talk, progress: 1, willAct: true, active: true) }
            return make(.talk, Self.talkHold, r.armed)
        }
        if talking { return nil }
        if r.pose == mapping.send { return make(.send, sendHold, (!r.startedWhileTalking || r.stoppedForSend) && !r.fired) }
        // An open hand is just a resting hand: nothing to show (cancel has nothing to cancel since send became a hold).
        if r.pose == mapping.cancel { return nil }
        if let direction = scrollDirection(r.pose) {
            let p = make(direction < 0 ? .scrollUp : .scrollDown, Self.scrollHold, !r.startedWhileTalking)
            return GestureProgress(pose: p.pose, action: p.action, progress: p.progress, willAct: p.willAct, active: p.willAct && p.progress >= 1)
        }
        return nil
    }

    public func reset() {
        talking = false
        pinchIsClosed = false; pinchClosedAt = nil; lastTapEnd = nil
        pinchToggled = false; dragging = false; isDragging = false; edgeCount = 0
        pinchSuspect = false; lastSendPoseT = -.infinity
        lastToggleAt = -.infinity
        stopArmed = false
        gatheredForStopAt = nil
        run = nil
        lastOtherPresentT = nil
        releaseStart = nil
        absentStart = nil
        lastPushT = nil
        lastTalkEndT = nil
    }

    /// The coordinator refused or failed to start the dictation this machine just announced: forget it
    /// without emitting an end, so the next double tap starts again instead of being read as a stop.
    public func abortTalk() {
        talking = false
        lastTapEnd = nil
        lastToggleAt = -.infinity
        stopArmed = false
        gatheredForStopAt = nil
        releaseStart = nil
    }

    public func push(_ observation: HandObservation) -> [GestureIntent] {
        // A non-finite reading is a missing reading: it must not reach the filters or the pinch hysteresis.
        var h = observation
        if let d = h.pinch, !d.isFinite { h.pinch = nil }
        if let c = h.palmCenter, !(c.x.isFinite && c.y.isFinite) { h.palmCenter = nil }
        guard h.t.isFinite else { return [] }
        lastPushT = h.t
        var intents: [GestureIntent] = []
        if h.present, let send = mapping.send, h.pose == send { lastSendPoseT = h.t }
        if talkStyle == .doubleTap {
            if let end = lastTapEnd, h.t - end > Self.tapGap, !pinchIsClosed { lastTapEnd = nil }   // first tap expired
            trackTaps(h, into: &intents)
        }

        guard h.present else {
            run = nil
            releaseStart = nil
            absentStart = absentStart ?? h.t
            if talking, talkStyle != .hold {
                if let since = absentStart, h.t - since >= 0.3 { stopArmed = true }
            } else if talking, let since = absentStart, h.t - since >= Self.handLostHold {
                endTalk(.handLost, at: h.t, into: &intents)
            }
            return intents
        }
        absentStart = nil

        let pose = h.pose
        if pose != mapping.talk { lastOtherPresentT = h.t }

        guard let pose else {
            run = nil
            if talkStyle == .gatherBloom { if talking { stopArmed = true } } else if talkStyle == .hold { trackRelease(isTalkPose: false, at: h.t, into: &intents) }
            return intents
        }

        if run?.pose != pose {
            let armed = pose == mapping.talk && (lastOtherPresentT.map { h.t - $0 <= Self.talkArmWindow } ?? false)
            run = Run(pose: pose, start: h.t, startedWhileTalking: talking, armed: armed, lastT: h.t)
        }
        if talkStyle == .hold { trackRelease(isTalkPose: pose == mapping.talk, at: h.t, into: &intents) }
        guard var r = run else { return intents }
        let held = h.t - r.start

        if talkStyle == .gatherBloom, talking, pose != mapping.send {
            if pose == mapping.talk {
                if stopArmed, held >= Self.talkHold { gatheredForStopAt = h.t }
            } else {
                stopArmed = true
                if pose == mapping.cancel, let g = gatheredForStopAt, h.t - g <= Self.bloomWindow {
                    endTalk(.released, at: h.t, into: &intents)
                    r.fired = true            // this open hand is the bloom; it must not also cancel anything
                }
            }
            r.lastT = h.t
            run = r
            return intents
        }

        if pose == mapping.talk && talkStyle != .doubleTap {
            if !talking, r.armed, held >= Self.talkHold {
                talking = true
                stopArmed = false
                gatheredForStopAt = nil
                releaseStart = nil
                intents.append(.talkBegan)
            }
        } else if talking, pose == mapping.send, !r.stoppedForSend, held >= Self.stopAndSendHold {
            // Straight from the talk pose to the send pose: stop dictating now; keep holding to send.
            r.stoppedForSend = true
            endTalk(.released, at: h.t, into: &intents)
        } else if !talking {
            if pose == mapping.send, !r.startedWhileTalking || r.stoppedForSend, !r.fired, held >= sendHold,
               r.stoppedForSend || (lastTalkEndT.map({ h.t - $0 >= Self.sendAfterTalkEnd }) ?? true) {
                r.fired = true
                intents.append(.sendRequested)
            } else if pose == mapping.cancel, !r.startedWhileTalking, !r.fired, held >= Self.cancelHold {
                r.fired = true
                intents.append(.cancelRequested)
            } else if let direction = scrollDirection(pose), !r.startedWhileTalking, held >= Self.scrollHold {
                let dt = h.t - r.lastT
                if dt > 0, dt <= Self.scrollMaxGap {
                    let ramp = min((held - Self.scrollHold) / Self.scrollRamp, 1)
                    let speed = Self.scrollMinSpeed + (Self.scrollMaxSpeed - Self.scrollMinSpeed) * ramp
                    intents.append(.scroll(dy: direction * speed * dt))
                }
            }
        }
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

    /// Two quick thumb-to-index taps toggle dictation. Taps are read from the pinch distance alone, so any hand
    /// shape works; a pinch held longer than `tapMax` (holding something) never counts.
    private func trackTaps(_ h: HandObservation, into intents: inout [GestureIntent]) {
        guard h.present, let d = h.pinch else {
            if dragging { intents.append(.dragScrollEnded) }
            pinchIsClosed = false; pinchClosedAt = nil; edgeCount = 0
            dragging = false; isDragging = false
            return
        }
        if !pinchIsClosed {
            edgeCount = d < pinchClosed ? edgeCount + 1 : 0
            guard edgeCount >= Self.edgeFrames else { return }
            pinchIsClosed = true; edgeCount = 0
            pinchClosedAt = h.t; pinchMin = d
            pinchToggled = false
            dragging = false; isDragging = false
            dragFilter.reset(); dragFilterX.reset()
            dragOriginY = h.palmCenter.map { dragFilter.filter(Double($0.y), at: h.t) }
            dragOriginX = h.palmCenter.map { dragFilterX.filter(Double($0.x), at: h.t) }
            dragLastY = dragOriginY; dragLastX = dragOriginX
            if let end = lastTapEnd, h.t - end > Self.tapGap { lastTapEnd = nil }
            pinchSuspect = h.t - lastSendPoseT < Self.quietAfterSendPose
            if pinchSuspect { lastTapEnd = nil }
            // The second pinch acts the moment it touches; holding it afterwards changes nothing.
            if lastTapEnd != nil, h.t - lastToggleAt >= Self.toggleCooldown {
                lastTapEnd = nil
                lastToggleAt = h.t
                pinchToggled = true
                if talking { endTalk(.released, at: h.t, into: &intents) } else { talking = true; intents.append(.talkBegan) }
            }
        } else {
            // Pinch and drag: a held pinch that moves vertically scrolls, with the hand position smoothed.
            // Release first: fingers that have parted while dragging end the drag before any movement counts.
            if dragging, d > max(pinchClosed, min(pinchMin, d) + Self.reopenRise * 0.6) {
                pinchIsClosed = false; edgeCount = 0; pinchClosedAt = nil
                dragging = false; isDragging = false; lastTapEnd = nil
                intents.append(.dragScrollEnded)
                return
            }
            // Hands move in arcs: the scroll follows the distance the pinch travels, signed by its vertical direction.
            if !pinchToggled, let p = h.palmCenter, let originY = dragOriginY, let originX = dragOriginX {
                let y = dragFilter.filter(Double(p.y), at: h.t)
                let x = dragFilterX.filter(Double(p.x), at: h.t)
                if !dragging, hypot(x - originX, y - originY) >= Self.dragStart { dragging = true; isDragging = true; lastTapEnd = nil }
                if dragging, let ly = dragLastY, let lx = dragLastX, let lt = dragLastT, h.t > lt {
                    let dy = y - ly, dx = (x - lx) * (640.0 / 480.0)   // frame is 4:3: put both axes in frame-height units
                    // Like dragging the page: each frame scrolls by the signed vertical move, so going up and then
                    // back down past the start scrolls back past where it began. When the move is mainly vertical
                    // the sideways part of an arc counts too (the full step length, signed by up or down); when it
                    // is mainly sideways only its small vertical part counts, so sideways jitter cannot drive it.
                    let step = abs(dy) >= 0.5 * abs(dx) ? (dy >= 0 ? 1.0 : -1.0) * hypot(dx, dy) : dy
                    if step != 0 {
                        let speed = abs(step) / (h.t - lt)                  // frame heights per second
                        let gain = 1 + Self.dragAccel * min(speed, 1)
                        intents.append(.dragScroll(handDy: step * Self.dragPointsPerFrameHeight * gain))
                    }
                }
                dragLastT = h.t
                dragLastY = y; dragLastX = x
            }
            pinchMin = min(pinchMin, d)
            // While dragging, opening the fingers even a little ends the drag at once (one frame, a lower bar),
            // so the page never follows a hand that has let go.
            let opened = dragging ? d > max(pinchClosed, pinchMin + Self.reopenRise * 0.6) : d > max(Self.reopenAbove, pinchMin + Self.reopenRise)
            edgeCount = opened ? edgeCount + 1 : 0
            if dragging, opened { edgeCount = Self.edgeFrames }
            if let start = pinchClosedAt, h.t - start > Self.tapMax { lastTapEnd = nil }   // held: not a tap
            guard edgeCount >= Self.edgeFrames else { return }
            pinchIsClosed = false; edgeCount = 0
            guard let start = pinchClosedAt else { return }
            pinchClosedAt = nil
            let closedFor = h.t - start
            if pinchToggled { pinchToggled = false; lastTapEnd = nil; return }
            if dragging { dragging = false; isDragging = false; lastTapEnd = nil; intents.append(.dragScrollEnded); return }
            guard closedFor >= Self.tapMin, closedFor <= Self.tapMax, !pinchSuspect else { lastTapEnd = nil; return }
            lastTapEnd = h.t
        }
    }

    /// One line of machine state for the per-frame trace.
    public var traceState: String {
        "talk=\(talking ? 1 : 0) closed=\(pinchIsClosed ? 1 : 0) await=\(awaitingSecondTap ? 1 : 0) drag=\(dragging ? 1 : 0) suspect=\(pinchSuspect ? 1 : 0)"
    }

    /// Feedback for the bubble: after one tap, the second tap is awaited.
    public var awaitingSecondTap: Bool {
        guard talkStyle == .doubleTap, let end = lastTapEnd, let now = lastPushT else { return false }
        return now - end <= Self.tapGap
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

    /// -1 for the scroll-up pose, +1 for scroll-down, nil for any other pose.
    private func scrollDirection(_ pose: Pose) -> Double? {
        if pose == mapping.scrollUp { return -1 }
        if pose == mapping.scrollDown { return 1 }
        return nil
    }
}
