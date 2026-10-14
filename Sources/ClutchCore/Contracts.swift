import CoreGraphics
import Foundation

// Shared types between the vision engine, the Claude bridge, the UI shell and the coordinator.
// Coordinates: every screen-space rect/point here is GLOBAL, TOP-LEFT origin (the Accessibility API's space),
// y grows downward. Convert to AppKit (bottom-left) only when drawing windows.

/// A static hand pose, per frame. Produced by the Sleight classifier (Vendor/Sleight).
public enum Pose: String, Codable, CaseIterable, Sendable {
    case fist, openPalm, thumbsUp, twoFingers
}

/// One camera frame's hand reading. `present == false` means no hand was found.
public struct HandObservation: Sendable {
    public var t: TimeInterval            // seconds, monotonic (CACurrentMediaTime)
    public var present: Bool
    public var pose: Pose?                // nil = a hand that is not one of the four poses (or gated out)
    public var palmCenter: CGPoint?       // normalized image coords, origin bottom-left, 0...1
    public init(t: TimeInterval, present: Bool, pose: Pose?, palmCenter: CGPoint?) {
        self.t = t; self.present = present; self.pose = pose; self.palmCenter = palmCenter
    }
}

/// One camera frame's head reading from MediaPipe. Angles in radians; sign conventions don't matter
/// because the pointer calibration fits them.
public struct HeadObservation: Sendable {
    public var t: TimeInterval
    public var yaw: Double
    public var pitch: Double
    public var faceCount: Int
    public init(t: TimeInterval, yaw: Double, pitch: Double, faceCount: Int) {
        self.t = t; self.yaw = yaw; self.pitch = pitch; self.faceCount = faceCount
    }
}

/// Brightness statistics of one frame, for the covered-camera check.
public struct FrameLight: Sendable {
    public var t: TimeInterval
    public var meanLuma: Double           // 0...1
    public var lumaStdDev: Double         // 0...1
    public init(t: TimeInterval, meanLuma: Double, lumaStdDev: Double) { self.t = t; self.meanLuma = meanLuma; self.lumaStdDev = lumaStdDev }
}

/// Which pose does what. User-configurable.
public struct GestureMapping: Codable, Equatable, Sendable {
    public var talk: Pose = .fist           // hold to dictate
    public var send: Pose? = .thumbsUp      // nil = sending by gesture is off
    public var scroll: Pose? = .twoFingers  // nil = scrolling by gesture is off
    public var cancel: Pose = .openPalm     // cancels a pending send
    public init() {}
}

/// What the gesture state machine asks for. The coordinator applies the safety guards before acting.
public enum GestureIntent: Equatable, Sendable {
    case talkBegan
    case talkEnded(TalkEndReason)
    case sendRequested
    case cancelRequested
    case scroll(dy: Double)                 // positive = scroll down the transcript
}

public enum TalkEndReason: String, Sendable { case released, handLost, stale }

/// A Claude Code session pane visible on screen.
public struct ClaudeSession: Equatable, Sendable {
    public var id: String                   // opaque, stable while the pane exists
    public var frame: CGRect                // global, top-left origin
    public var windowNumber: Int
    public init(id: String, frame: CGRect, windowNumber: Int) { self.id = id; self.frame = frame; self.windowNumber = windowNumber }
}

/// One calibration reading: where the user was asked to point their nose (global, top-left) and the
/// head angles averaged while they did.
public struct CalibrationSample: Codable, Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double
    public var target: CGPoint
    public init(yaw: Double, pitch: Double, target: CGPoint) { self.yaw = yaw; self.pitch = pitch; self.target = target }
}

/// The result of asking Claude to do something.
public enum BridgeResult: Equatable, Sendable {
    case done
    case refused(String)    // a guard said no; nothing was pressed
    case unknown(String)    // pressed, but the outcome could not be confirmed
}
