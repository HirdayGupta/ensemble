import AppKit
import EnsembleCore

@MainActor
protocol AppCoordinating: AnyObject {
    func start()
    func stop(disarm: Bool)
    func calibrate()
    /// Called once as the app quits; must finish within about two seconds and leave nothing recording.
    func shutdown()
    var cameraNames: [String] { get }
}

/// The integrator replaces the body of this factory (in another file) with the real coordinator.
@MainActor
func makeCoordinator(state: AppState, settings: SettingsStore, overlay: OverlayController) -> AppCoordinating {
    ProcessInfo.processInfo.arguments.contains("--stub")
        ? StubCoordinator(state: state, settings: settings, overlay: overlay)
        : Coordinator(state: state, settings: settings, overlay: overlay)
}

/// Animates fake states so the UI can be exercised without a camera.
@MainActor
final class StubCoordinator: AppCoordinating {
    private let state: AppState
    private let settings: SettingsStore
    private let overlay: OverlayController
    private var timer: Timer?
    private var started = Date()
    private let cycle = 12.0

    let cameraNames = ["FaceTime HD Camera (stub)", "Studio Display Camera (stub)"]

    init(state: AppState, settings: SettingsStore, overlay: OverlayController) {
        self.state = state
        self.settings = settings
        self.overlay = overlay
    }

    func start() {
        state.cameraNames = cameraNames
        state.cameraName = settings.cameraName ?? cameraNames[0]
        started = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop(disarm: Bool) {
        timer?.invalidate()
        timer = nil
        state.status = .off
        push(target: nil, nose: nil, listening: false)
    }

    func shutdown() { stop(disarm: false) }


    func calibrate() {
        guard !state.calibrating else { return }
        state.calibrating = true
        var tick = 0.0
        CalibrationController.shared.run(headSource: {
            tick += 1
            return HeadObservation(t: tick, yaw: 0, pitch: 0, faceCount: 1)
        }, completion: { [weak self] results in
            guard let self else { return }
            self.state.calibrating = false
            guard !results.isEmpty, let data = try? JSONEncoder().encode(results.flatMap(\.samples)) else { return }
            self.settings.calibration = data
            self.settings.calibratedAt = Date()
        })
    }

    private func tick() {
        guard settings.enabled else {
            if state.status != .off { stop(disarm: false) }
            return
        }
        let t = Date().timeIntervalSince(started)
        let phase = t.truncatingRemainder(dividingBy: cycle)
        let screen = ScreenGeometry.topLeftFrame(of: NSScreen.main ?? NSScreen.screens[0])

        let pane = CGRect(x: screen.minX + screen.width * 0.08, y: screen.minY + screen.height * 0.16,
                          width: screen.width * 0.42, height: screen.height * 0.66)
        let nose = CGPoint(x: pane.midX + sin(t * 0.9) * pane.width * 0.3, y: pane.midY + sin(t * 1.3) * pane.height * 0.3)

        let listening = (3..<7).contains(phase)
        if phase >= 10 { state.lastRefusal = "Not sending: the session is in a mode that asks before acting." }
        if phase < 1 { state.lastRefusal = nil }

        state.status = listening ? .listening : .watching
        state.listening = listening
        state.targetFrame = pane
        state.nosePoint = nose
        state.fps = 30
        push(target: pane, nose: nose, listening: listening)
    }

    private func push(target: CGRect?, nose: CGPoint?, listening: Bool) {
        overlay.update(target: target, nose: nose, listening: listening,
                       showNoseDot: settings.showNoseDot, showHighlight: settings.showHighlight)
    }
}
