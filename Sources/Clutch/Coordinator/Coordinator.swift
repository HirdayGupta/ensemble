import AppKit
import Combine
import ClutchCore

/// Wires the camera engine, the gesture rules, the nose pointer and the Claude bridge together,
/// and owns every guard that decides whether a gesture is allowed to act.
@MainActor
final class Coordinator: AppCoordinating {
    private let state: AppState
    private let settings: SettingsStore
    private let overlay: OverlayController
    private let engine = VisionEngine()
    private let bridge = ClaudeBridge()
    private lazy var safety = DictationSafety(bridge: bridge)
    private let pointer = NosePointer()
    private let gestures = GestureMachine()
    private let cover = CoverDetector()

    private var latestHead: HeadObservation?
    private var faceCount = 0
    private var sessions: [ClaudeSession] = []
    private var target: ClaudeSession?
    private var listeningSession: ClaudeSession?
    private var lastSpoken: (session: ClaudeSession, stoppedAt: Date)?
    private var pendingSend: (session: ClaudeSession, started: Date, text: String)?
    private var scrollSession: (session: ClaudeSession, lastAt: Date)?
    private var busy = false                 // a start/stop/send is in flight
    private var tickTimer: Timer?
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var running = false

    /// Gestures are refused within this long after the keyboard, mouse or trackpad was used.
    private let inputQuiet = 1.5
    /// A thumbs-up sends only this soon after dictation stopped.
    private let sendWindow = 30.0
    /// Wait this long after the hand opens before stopping, so the last word is caught.
    private let stopTail = 0.4

    var cameraNames: [String] { VisionEngine.cameraNames() }

    init(state: AppState, settings: SettingsStore, overlay: OverlayController) {
        self.state = state
        self.settings = settings
        self.overlay = overlay
        if let data = settings.calibration { pointer.calibration = data }
        gestures.mapping = settings.mapping

        settings.$mapping.dropFirst().sink { [weak self] m in self?.gestures.mapping = m; self?.gestures.reset() }.store(in: &cancellables)
        settings.$enabled.dropFirst().removeDuplicates().sink { [weak self] on in
            guard let self else { return }
            on ? self.start() : self.stop()
        }.store(in: &cancellables)
        settings.$cameraName.dropFirst().removeDuplicates().sink { [weak self] _ in
            guard let self, self.running else { return }
            self.stop(); self.start()
        }.store(in: &cancellables)

        engine.onHand = { [weak self] in self?.handle(hand: $0) }
        engine.onHead = { [weak self] in self?.handle(head: $0) }
        engine.onLight = { [weak self] in self?.handle(light: $0) }
        engine.onStatus = { [weak self] in self?.handle(status: $0) }
        safety.onAlarm = { [weak self] msg in
            self?.refuse("Alarm: \(msg)")
            Notifier.shared.notify(title: "Claude's microphone may still be on", body: msg)
        }
        safety.onMuted = { [weak self] muted in self?.state.muted = muted }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
    }

    // MARK: - AppCoordinating

    func start() {
        ClutchLog.write("start (enabled=\(settings.enabled), camera=\(settings.cameraName ?? "automatic"), calibrated=\(pointer.isCalibrated))")
        state.cameraNames = cameraNames
        sweep()
        guard settings.enabled else { state.status = .off; return }
        running = true
        engine.start(cameraName: settings.cameraName)
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSessions() }
        }
        refreshSessions()
        updateStatus()
    }

    func stop() {
        ClutchLog.write("stop")
        running = false
        tickTimer?.invalidate(); tickTimer = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        if listeningSession != nil { endTalk(reason: "turned off") }
        engine.stop()
        gestures.reset()
        pendingSend = nil
        target = nil
        state.status = .off
        pushOverlay()
    }

    func calibrate() {
        ClutchLog.write("calibrate requested (engine running=\(engine.isRunning))")
        guard engine.isRunning else { refuse("Turn Clutch on before calibrating"); return }
        state.calibrating = true
        CalibrationController.shared.run(headSource: { [weak self] in self?.latestHead }) { [weak self] samples in
            guard let self else { return }
            self.state.calibrating = false
            ClutchLog.write("calibration samples: \(samples.count)")
            guard !samples.isEmpty else { return }
            if self.pointer.fit(samples), let data = self.pointer.calibration {
                self.settings.calibration = data
                self.settings.calibratedAt = Date()
                self.pointer.resetFilter()
            } else {
                self.refuse("Calibration did not fit; try again sitting where you normally work")
            }
            self.updateStatus()
        }
    }

    func clearAndDisarm() {
        safety.clearAndDisarm()
        pendingSend = nil
        listeningSession = nil
        state.listening = false
        settings.enabled = false
    }

    // MARK: - Inputs

    private func handle(head: HeadObservation) {
        latestHead = head
        faceCount = head.faceCount
        guard !state.calibrating else { return }
        if head.faceCount == 1, pointer.isCalibrated, let p = pointer.point(for: head) {
            state.nosePoint = p
            target = sessions.first { $0.frame.contains(p) }
        } else {
            state.nosePoint = nil
            target = nil
        }
        state.targetFrame = target?.frame
        pushOverlay()
    }

    private func handle(hand: HandObservation) {
        if listeningSession != nil, hand.present, hand.pose == settings.mapping.talk { safety.heartbeat() }
        guard !state.calibrating else { return }
        for intent in gestures.push(hand) { apply(intent) }
    }

    private func handle(light: FrameLight) {
        guard let covered = cover.push(light) else { return }
        if covered {
            if listeningSession != nil { endTalk(reason: "camera covered") }
            pendingSend = nil
            gestures.reset()
            Notifier.shared.notify(title: "Camera covered", body: "Gestures are off until the camera is uncovered.")
        }
        updateStatus()
    }

    private func handle(status: EngineStatus) {
        if case .running = status {} else { ClutchLog.write("engine: \(status)") }
        switch status {
        case .running(let fps, let camera):
            state.fps = fps
            state.cameraName = camera
        case .permissionDenied:
            state.status = .needsPermission("Camera")
        case .noCamera:
            state.status = .error("No camera found")
        case .error(let msg), .faceTrackerFailed(let msg):
            state.status = .error(msg)
        default:
            break
        }
        updateStatus()
    }

    private func tick() {
        for intent in gestures.tick(now: CACurrentMediaTime()) { apply(intent) }
        if let send = pendingSend { advanceCountdown(send) }
        if let s = scrollSession, Date().timeIntervalSince(s.lastAt) > 0.6 { scrollSession = nil }
    }

    private func refreshSessions() {
        guard bridge.claudeIsRunning() else {
            sessions = []; target = nil; updateStatus(); return
        }
        Task { @MainActor in
            self.sessions = await self.bridge.refreshSessions()
            self.updateStatus()
        }
    }

    // MARK: - Intents and guards

    private func apply(_ intent: GestureIntent) {
        if case .scroll = intent {} else { ClutchLog.write("gesture: \(intent)") }
        switch intent {
        case .talkBegan: beginTalk()
        case .talkEnded(let reason): if listeningSession != nil { endTalk(reason: reason.rawValue) }
        case .sendRequested: requestSend()
        case .cancelRequested: if pendingSend != nil { pendingSend = nil; state.countdown = nil; Notifier.shared.playCue(.refused); pushOverlay() }
        case .scroll(let dy): scroll(dy)
        }
    }

    /// Shared guards for every gesture that acts on Claude. Returns a refusal reason, or nil when allowed.
    private func commonRefusal() -> String? {
        if !settings.enabled { return "Clutch is off" }
        if cover.covered { return "Camera is covered" }
        if faceCount != 1 { return faceCount == 0 ? "No face in view" : "More than one face in view" }
        if ClaudeBridge.secondsSinceUserInput() < inputQuiet { return "Keyboard or mouse was just used" }
        return nil
    }

    private func beginTalk() {
        guard listeningSession == nil, !busy else { return }
        if let why = commonRefusal() { refuse(why); return }
        guard pointer.isCalibrated else { refuse("Calibrate first"); return }
        guard let session = target else { refuse("Your nose is not on a Claude session"); return }
        if let other = bridge.otherProcessCapturingInput() { refuse("\(other) is using a microphone"); return }
        pendingSend = nil; state.countdown = nil
        guard safety.episodeStarting(session: session) else { refuse("Could not write the safety record; not starting"); return }
        busy = true
        listeningSession = session
        state.listening = true
        pushOverlay()
        Task { @MainActor in
            let result = await self.bridge.startDictation(session)
            self.busy = false
            switch result {
            case .done:
                ClutchLog.write("dictation started")
                self.safety.episodeConfirmed()
                Notifier.shared.playCue(.listenStart)
            case .refused(let why), .unknown(let why):
                self.listeningSession = nil
                self.state.listening = false
                self.safety.episodeEnded()
                self.refuse("Could not start dictation: \(why)")
            }
            // The hand may already have opened while the press was in flight.
            if !self.gestures.talking, self.listeningSession != nil { self.endTalk(reason: "released") }
            self.pushOverlay()
        }
    }

    private func endTalk(reason: String) {
        guard let session = listeningSession, !busy else { return }
        busy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(self.stopTail * 1e9))
            let result = await self.bridge.stopDictation(session)
            self.busy = false
            self.listeningSession = nil
            self.state.listening = false
            self.safety.episodeEnded()
            switch result {
            case .done:
                ClutchLog.write("dictation stopped")
                self.lastSpoken = (session, Date())
                Notifier.shared.playCue(.listenEnd)
            case .refused(let why), .unknown(let why):
                self.refuse("Stop not confirmed (\(why)); the safety check keeps watching")
            }
            self.pushOverlay()
        }
    }

    private func requestSend() {
        guard settings.mapping.send != nil, pendingSend == nil, listeningSession == nil, !busy else { return }
        if let why = commonRefusal() { refuse(why); return }
        guard let spoken = lastSpoken, Date().timeIntervalSince(spoken.stoppedAt) <= sendWindow else {
            refuse("Nothing dictated in the last \(Int(sendWindow)) seconds"); return
        }
        guard let session = target, session.id == spoken.session.id else { refuse("Look at the session you dictated into"); return }
        if ClaudeBridge.secondsSinceUserInput() < Date().timeIntervalSince(spoken.stoppedAt) { refuse("Keyboard or mouse used since dictation"); return }
        if let other = bridge.otherProcessCapturingInput() { refuse("\(other) is using a microphone"); return }
        Task { @MainActor in
            guard let text = await self.bridge.draftText(session), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.refuse("The draft is empty"); return
            }
            self.pendingSend = (session, Date(), text)
            Notifier.shared.playCue(.listenStart)
        }
    }

    private func advanceCountdown(_ send: (session: ClaudeSession, started: Date, text: String)) {
        let words = Double(send.text.split(separator: " ").count)
        let duration = settings.sendCountdownSeconds + words * 0.03
        let elapsed = Date().timeIntervalSince(send.started)
        // Cancel on any keyboard or mouse use, or when the nose leaves the session.
        if ClaudeBridge.secondsSinceUserInput() < elapsed || target?.id != send.session.id || cover.covered {
            pendingSend = nil; state.countdown = nil; pushOverlay(); Notifier.shared.playCue(.refused); return
        }
        if elapsed < duration {
            state.countdown = Countdown(progress: elapsed / duration, text: send.text, sessionFrame: send.session.frame)
            pushOverlay()
            return
        }
        pendingSend = nil
        state.countdown = nil
        pushOverlay()
        busy = true
        Task { @MainActor in
            let result = await self.bridge.sendDraft(send.session)
            self.busy = false
            switch result {
            case .done: self.lastSpoken = nil; Notifier.shared.playCue(.send)
            case .refused(let why), .unknown(let why): self.refuse("Not sent: \(why)")
            }
        }
    }

    private func scroll(_ dy: Double) {
        guard listeningSession == nil, pendingSend == nil, commonRefusal() == nil else { return }
        let session: ClaudeSession
        if let s = scrollSession { session = s.session } else if let t = target { session = t } else { return }
        scrollSession = (session, Date())
        bridge.scroll(session, dy: dy)
    }

    // MARK: - Output

    private func sweep() {
        Task { await self.safety.launchSweep() }
    }

    private func refuse(_ why: String) {
        state.lastRefusal = why
        ClutchLog.write("refused: \(why)")
    }

    private func updateStatus() {
        if !settings.enabled || !running { state.status = .off; return }
        if case .needsPermission = state.status { return }
        if case .error = state.status, !engine.isRunning { return }
        if cover.covered { state.status = .cameraCovered; return }
        if !pointer.isCalibrated { state.status = .needsCalibration; return }
        if !bridge.claudeIsRunning() { state.status = .claudeNotRunning; return }
        state.status = state.listening ? .listening : .watching
    }

    private func pushOverlay() {
        overlay.update(target: target?.frame, nose: state.nosePoint, listening: state.listening,
                       countdown: state.countdown, showNoseDot: settings.showNoseDot, showHighlight: settings.showHighlight)
        updateStatus()
    }
}
