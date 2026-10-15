import AppKit
import EnsembleCore

/// What every controller shares: the services, the facts more than one of them reads, and the guards that
/// decide whether a gesture may act on Claude.
@MainActor
final class CoordinatorContext {
    /// Gestures are refused within this long after the keyboard, mouse or trackpad was used.
    static let inputQuiet = 1.5

    let state: AppState
    let settings: SettingsStore
    let overlay: OverlayController
    let bridge = ClaudeBridge()
    let gestures = GestureMachine()
    let cover = CoverDetector()
    let pointer = NosePointer()

    var latestHead: HeadObservation?
    var sessions: [ClaudeSession] = []
    /// The session being dictated into, from the press until the stop is confirmed.
    var listening: ClaudeSession?
    /// A start, stop or send is in flight.
    var busy = false
    /// The last time exactly one face was seen.
    var lastOneFaceT: TimeInterval = -.infinity
    var gestureShowing = false
    /// A headphone press acted until this time, so refusals it causes are shown on the island and labelled.
    var headphoneUntil: TimeInterval = -.infinity
    var headphoneActive: Bool { CACurrentMediaTime() < headphoneUntil }
    /// Redraws the overlay from the current facts.
    var changed: () -> Void = {}

    private var calibratedCache: (value: Bool, at: TimeInterval)?

    init(state: AppState, settings: SettingsStore, overlay: OverlayController) {
        self.state = state
        self.settings = settings
        self.overlay = overlay
    }

    /// The calibration is usable only on the screen arrangement it was made on.
    var calibratedHere: Bool {
        guard pointer.isCalibrated else { return false }
        // Read on every camera frame; the screen arrangement only changes in screensChanged, so cache briefly.
        let now = CACurrentMediaTime()
        if let c = calibratedCache, now - c.at < 1 { return c.value }
        let value = settings.calibrationDisplays == ScreenFacts.displayFingerprint()
        calibratedCache = (value, now)
        return value
    }

    func invalidateCalibrationCache() { calibratedCache = nil }

    /// Shared guards for every gesture that acts on Claude. Returns a refusal reason, or nil when allowed.
    func commonRefusal() -> String? {
        if !settings.enabled { return "Ensemble is off" }
        if cover.covered { return "Camera is covered" }
        if ScreenFacts.sessionAway() { return "The screen is locked" }
        // The hand often covers the face as it rises: one face within the last 1.5 s counts. Two faces block only
        // when they persist: a stray two-face reading is a false alarm.
        let now = CACurrentMediaTime()
        if now - lastOneFaceT > 1.5 { return "No face in view" }
        if ClaudeBridge.secondsSinceTypingOrClick() < Self.inputQuiet { return "You just typed or clicked" }
        return nil
    }

    func refuse(_ why: String, title: String? = nil) {
        state.lastRefusal = why
        if gestureShowing || headphoneActive || why.hasPrefix("Send") || why.hasPrefix("Not sent") {
            let sendRelated = why.hasPrefix("Send") || why.hasPrefix("Not sent")
            let body = why.hasPrefix("Not sent: ") ? String(why.dropFirst("Not sent: ".count)) : why
            if headphoneActive, !sendRelated {
                // Labelled as the headphone press, with the usual title folded into the line.
                let line = (title.map { $0 + ": " } ?? "") + body
                overlay.showBanner(title: "Headphone press", body: line.prefix(1).uppercased() + line.dropFirst(), style: .refused, seconds: 2.5)
            } else {
                overlay.showBanner(title: title ?? (sendRelated ? "Not sent" : "Nothing done"), body: body.prefix(1).uppercased() + body.dropFirst(), style: .refused, seconds: 2.5)
            }
        }
        EnsembleLog.write("refused: \(why)")
    }

    /// The session's name as Claude shows it now, for the island.
    func name(of session: ClaudeSession) -> String {
        (sessions.first { $0.id == session.id }?.title ?? session.title) ?? "this session"
    }
}
