import Foundation

/// The media remote commands Ensemble listens for. Everything else macOS can send is not registered.
public enum HeadphoneCommand: Sendable {
    case togglePlayPause, play, pause, nextTrack
}

/// What a stem press means. AirPods send a single press as play/pause and a double press as next track.
public enum HeadphoneAction: Equatable, Sendable {
    case press          // start or stop dictation in the session the user is looking at
    case doublePress    // send the dictated draft, under the same narrow rules as the thumbs-up
}

/// The facts that decide whether Ensemble should be the app macOS treats as Now Playing.
public struct HeadphoneConditions: Equatable, Sendable {
    public var settingOn: Bool
    public var outputIsBluetooth: Bool
    public var claudeRunning: Bool
    /// Some other app is sending audio out. Ensemble plays nothing itself, so its own output never counts.
    public var otherAudioPlaying: Bool
    public init(settingOn: Bool, outputIsBluetooth: Bool, claudeRunning: Bool, otherAudioPlaying: Bool) {
        self.settingOn = settingOn; self.outputIsBluetooth = outputIsBluetooth
        self.claudeRunning = claudeRunning; self.otherAudioPlaying = otherAudioPlaying
    }

    /// All four must hold. Music playing always wins: presses then belong to the music.
    public var allowsClaim: Bool { settingOn && outputIsBluetooth && claudeRunning && !otherAudioPlaying }
}

/// Decides when to hold and when to let go of Now Playing. Letting go is immediate, so Ensemble never stands
/// between a press and music that just started; claiming waits for a few quiet polls in a row, so a short
/// system sound does not make the claim flap.
public struct HeadphoneClaimGate: Sendable {
    public static let quietPollsBeforeClaim = 2
    public private(set) var held = false
    private var quietPolls = 0
    public init() {}

    /// Feed one poll; returns whether Now Playing should be held now.
    public mutating func update(_ c: HeadphoneConditions) -> Bool {
        guard c.allowsClaim else { held = false; quietPolls = 0; return false }
        quietPolls += 1
        if quietPolls >= Self.quietPollsBeforeClaim { held = true }
        return held
    }
}

/// Turns raw commands into actions, and drops the ones that were not a person pressing the stem.
public struct HeadphoneInputFilter: Sendable {
    /// A command this soon after Ensemble sent a play/pause key itself (the audio pause while dictating) is our
    /// own key coming back through Now Playing, never a user press.
    public static let selfKeyWindow: TimeInterval = 1.5
    /// macOS sends the Now Playing app a pause or play when any microphone capture starts or stops (measured: a
    /// "pause" 0.3 to 1.3 s after every Claude dictation start or stop, 42 times in one log). That is the system
    /// talking, not the stem, and acting on it stopped dictations the moment they began or started new ones.
    public static let micChangeWindow: TimeInterval = 3.0
    /// Some devices report one press as both play and toggle; the same action twice this fast is one press.
    public static let duplicateGap: TimeInterval = 0.25
    private var last: (action: HeadphoneAction, at: TimeInterval)?
    public init() {}

    public static func action(for command: HeadphoneCommand) -> HeadphoneAction {
        switch command {
        case .togglePlayPause, .play, .pause: return .press
        case .nextTrack: return .doublePress
        }
    }

    /// `lastSyntheticKeyAt` is when Ensemble last posted a play/pause key (-infinity if never), on the same clock as `now`.
    /// `lastMicChangeAt` is when a microphone capture last started or stopped, by Ensemble or by Claude itself.
    public mutating func accept(_ command: HeadphoneCommand, at now: TimeInterval, lastSyntheticKeyAt: TimeInterval,
                                lastMicChangeAt: TimeInterval = -.infinity) -> HeadphoneAction? {
        guard now.isFinite else { return nil }
        if now - lastSyntheticKeyAt < Self.selfKeyWindow { return nil }
        if command != .nextTrack, now - lastMicChangeAt < Self.micChangeWindow { return nil }
        let action = Self.action(for: command)
        if let l = last, l.action == action, now - l.at < Self.duplicateGap { return nil }
        last = (action, now)
        return action
    }
}
