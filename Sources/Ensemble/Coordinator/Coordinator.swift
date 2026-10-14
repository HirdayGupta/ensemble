import AppKit
import Combine
import EnsembleCore

/// Wires the camera engine, the gesture rules, the nose pointer and the Claude bridge together. Each job has
/// its own controller; this routes camera readings and gesture intents to them, runs the 20 Hz tick, and keeps
/// the steps that cut across controllers (interrupting, refreshing the overlay).
@MainActor
final class Coordinator: AppCoordinating {
    private let ctx: CoordinatorContext
    private let engine = VisionEngine()
    private let health: HealthMonitor
    private let focus: FocusController
    private let dot: DotPlacement
    private let scroll: ScrollController
    private let send: SendController
    private let dictation: DictationController
    private var state: AppState { ctx.state }
    private var settings: SettingsStore { ctx.settings }
    private var gestures: GestureMachine { ctx.gestures }

    private var tickTimer: Timer?
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var headStats: (since: TimeInterval, n: Int, faces: [Int]) = (0, 0, [0, 0, 0])
    private var calibrationPending = false
    private var refreshInFlight = false
    private var promptedAccessibility = false
    private var lastAwayCheck: TimeInterval = 0
    private var lastSessionScan: TimeInterval = 0
    private static let staleHeadSeconds = 2.0
    private static let sessionScanFaceWindow = 5.0
    private static let sessionScanIdleInterval = 5.0

    var cameraNames: [String] { VisionEngine.cameraNames() }

    init(state: AppState, settings: SettingsStore, overlay: OverlayController) {
        let ctx = CoordinatorContext(state: state, settings: settings, overlay: overlay)
        self.ctx = ctx
        health = HealthMonitor(ctx: ctx, engine: engine)
        focus = FocusController(ctx: ctx)
        dot = DotPlacement(ctx: ctx)
        scroll = ScrollController(ctx: ctx)
        send = SendController(ctx: ctx)
        dictation = DictationController(ctx: ctx, focus: focus, send: send)
        ctx.changed = { [weak self] in self?.pushOverlay() }
        focus.stopDictation = { [weak self] reason in self?.dictation.end(reason: reason) }
        dictation.interrupt = { [weak self] reason in self?.interrupt(reason) }

        if let data = settings.calibration { ctx.pointer.calibration = data }
        if ctx.pointer.isCalibrated, settings.calibrationDisplays == nil { settings.calibrationDisplays = ScreenFacts.displayFingerprint() }
        gestures.mapping = settings.mapping
        ctx.pointer.setSmoothing(settings.pointerSmoothing)
        gestures.sendHold = settings.sendCountdownSeconds

        settings.$mapping.dropFirst().sink { [weak self] m in self?.gestures.mapping = m; self?.gestures.reset() }.store(in: &cancellables)
        settings.$sendCountdownSeconds.dropFirst().sink { [weak self] v in self?.gestures.sendHold = v }.store(in: &cancellables)
        settings.$pointerSmoothing.dropFirst().sink { [weak self] k in self?.ctx.pointer.setSmoothing(k) }.store(in: &cancellables)
        settings.$enabled.removeDuplicates().dropFirst().sink { [weak self] on in
            guard let self else { return }
            // @Published fires before the stored value changes, so read settings on the next turn of the run loop.
            DispatchQueue.main.async { on ? self.start() : self.stop(disarm: true) }
        }.store(in: &cancellables)
        settings.$cameraName.removeDuplicates().dropFirst().sink { [weak self] _ in
            guard let self, self.health.running else { return }
            DispatchQueue.main.async { self.stop(disarm: false); self.start() }
        }.store(in: &cancellables)

        engine.onHand = { [weak self] in self?.handle(hand: $0) }
        engine.onHead = { [weak self] in self?.handle(head: $0) }
        engine.onLight = { [weak self] in self?.handle(light: $0) }
        engine.onStatus = { [weak self] in self?.health.handle(status: $0) }
        engine.onDiagnostic = { note in EnsembleLog.write("engine: \(note)") }
        SystemEvents.observe(
            interrupt: { [weak self] in self?.interrupt($0) },
            sweep: { [weak self] in self?.dictation.sweep() },
            screensChanged: { [weak self] in self?.screensChanged() })
    }

    // MARK: - AppCoordinating

    func start() {
        EnsembleLog.write("start (enabled=\(settings.enabled), camera=\(settings.cameraName ?? "automatic"), calibrated=\(ctx.pointer.isCalibrated), accessibility=\(AXIsProcessTrusted()), screens=\(ScreenFacts.displayFingerprint()))")
        state.cameraNames = cameraNames
        dictation.sweep()
        MediaDucker.recoverAfterCrash()
        guard settings.enabled else { state.status = .off; return }
        if !Permissions.accessibilityTrusted {
            EnsembleLog.write("accessibility permission missing (if Ensemble is already listed in Settings, remove it and add it again)")
            if !promptedAccessibility {
                promptedAccessibility = true
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
        }
        health.begin()
        ctx.latestHead = nil
        engine.start(cameraName: settings.cameraName)
        tickTimer?.invalidate()
        tickTimer = commonModeTimer(1.0 / 20.0) { [weak self] in self?.tick() }
        refreshTimer?.invalidate()
        refreshTimer = commonModeTimer(1.0) { [weak self] in self?.refreshSessions() }
        refreshSessions()
        health.update()
    }

    /// Common run-loop mode keeps the timers firing while a slider is dragged or a menu is open.
    private func commonModeTimer(_ interval: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { fire() } }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// `disarm`: the owner switched Ensemble off. Any Claude dictation still recording is stopped and confirmed off,
    /// and the safety record and microphone mute are cleared, the same as the old "Clear and disarm" button did.
    func stop(disarm: Bool) {
        EnsembleLog.write("stop")
        health.running = false
        ctx.latestHead = nil
        tickTimer?.invalidate(); tickTimer = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        if disarm { dictation.clearAndDisarm() } else if ctx.listening != nil { dictation.end(reason: "turned off") }
        engine.stop()
        gestures.reset()
        scroll.cancel()
        focus.clearDeferred(); send.afterStop = false; send.forget()
        focus.forgetTarget()
        state.status = .off
        pushOverlay()
    }

    /// Quit path: blocks (at most about two seconds) until Claude's microphone is confirmed off and our mute is undone.
    func shutdown() {
        EnsembleLog.write("shutdown")
        health.running = false
        tickTimer?.invalidate(); tickTimer = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        ctx.bridge.beginShutdown()
        engine.stop()
        scroll.cancel()
        dictation.shutdown()
        EnsembleLog.flush()
    }

    func calibrate() {
        guard !calibrationPending, !state.calibrating else { EnsembleLog.write("calibrate ignored: already in progress"); return }
        EnsembleLog.write("calibrate requested (engine running=\(engine.isRunning), face tracker ready=\(health.trackerReady))")
        // Calibrating while off, or while the camera is down, turns Ensemble on or restarts the camera and waits
        // (up to 30 s: a first camera prompt plus the model load) for the face tracker to produce a reading.
        if !engine.isRunning || !health.trackerReady || ctx.latestHead == nil {
            calibrationPending = true
            if !settings.enabled { settings.enabled = true } else if !health.running || !engine.isRunning { start() }   // the enabled sink starts it
            Task { @MainActor in
                defer { self.calibrationPending = false }
                for _ in 0..<300 where !(self.engine.isRunning && self.health.trackerReady && self.ctx.latestHead != nil) {
                    if self.health.cameraFailed { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                guard self.engine.isRunning, self.health.trackerReady, self.ctx.latestHead != nil else {
                    if !self.health.cameraAllowed { self.ctx.refuse("Calibration needs Camera permission") }
                    else { self.ctx.refuse("The camera did not start: \(self.health.failure ?? "no reading within 30 s")") }
                    return
                }
                self.calibrationPending = false
                self.calibrate()
            }
            return
        }
        // Calibration owns the hands and the head: end any dictation first, because
        // gesture events are ignored while it runs and a held talk pose would never be seen released.
        send.afterStop = false
        gestures.reset()
        scroll.cancel()
        if ctx.listening != nil { dictation.endWhenIdle(reason: "calibrating") }
        let fingerprint = ScreenFacts.displayFingerprint()
        let camera = state.cameraName
        state.calibrating = true
        CalibrationController.shared.run(headSource: { [weak self] in self?.ctx.latestHead }) { [weak self] samples in
            guard let self else { return }
            self.state.calibrating = false
            EnsembleLog.write("calibration samples: \(samples.count)")
            guard !samples.isEmpty else { return }
            guard ScreenFacts.displayFingerprint() == fingerprint, self.state.cameraName == camera else {
                self.ctx.refuse("Calibration discarded: the screens or the camera changed while it ran; try again")
                return
            }
            if self.ctx.pointer.fit(samples), let data = self.ctx.pointer.calibration {
                self.settings.calibration = data
                self.settings.calibratedAt = Date()
                self.settings.calibrationDisplays = fingerprint; self.ctx.invalidateCalibrationCache()
                self.ctx.pointer.resetFilter()
            } else {
                self.ctx.refuse("Calibration did not fit; try again sitting where you normally work")
            }
            self.health.update()
        }
    }

    // MARK: - Inputs

    private func handle(head: HeadObservation) {
        ctx.latestHead = head
        if head.faceCount == 1 {
            let returned = head.t - ctx.lastOneFaceT >= Self.sessionScanFaceWindow
            ctx.lastOneFaceT = head.t
            if returned { refreshSessions() }
        }
        logHeadStats(head)
        guard !state.calibrating else { return }
        if head.faceCount == 1, ctx.calibratedHere, let p = ctx.pointer.point(for: head) {
            // A pinch or scroll in progress holds everything still: the hand is in front of the face.
            let under = focus.observe(nose: p, at: head.t, held: gestures.pinchHeld || scroll.isActive)
            dot.follow(nose: p, onSession: under != nil)
            EnsembleTrace.write(head.t, "head nose=\(Int(p.x)),\(Int(p.y)) under=\(under?.id ?? "-") \(focus.traceState(at: head.t)) faces=\(head.faceCount)")
        } else if head.faceCount != 1 && head.t - ctx.lastOneFaceT <= 1.5 {
            // A hand in front of the face hides it or reads as a second face for a moment: keep the last target and dot.
        } else {
            dot.clear()
            focus.forgetTarget()
        }
        dot.place(target: focus.target)
        pushOverlay()
    }

    private func logHeadStats(_ head: HeadObservation) {
        headStats.n += 1; headStats.faces[min(head.faceCount, 2)] += 1
        guard head.t - headStats.since >= 30 else { return }
        let nose = ctx.pointer.point(for: head).map { "\(Int($0.x)),\(Int($0.y))" } ?? "none"
        EnsembleLog.write("head: \(headStats.n) readings in 30 s, faces 0/1/2+ = \(headStats.faces), nose at \(nose), accessibility \(AXIsProcessTrusted()), Claude running \(ctx.bridge.claudeIsRunning()), sessions \(ctx.sessions.count), nose on Claude: \(focus.target != nil), \(ctx.bridge.micSnapshot)")
        headStats = (head.t, 0, [0, 0, 0])
    }

    private func handle(hand: HandObservation) {
        dictation.heartbeat()
        guard !state.calibrating else { return }
        let intents = gestures.push(hand)
        EnsembleTrace.write(hand.t, "hand present=\(hand.present ? 1 : 0) pose=\(hand.pose?.rawValue ?? "-") pinch=\(hand.pinch.map { String(format: "%.3f", $0) } ?? "-") palm=\(hand.palmCenter.map { String(format: "%.3f,%.3f", $0.x, $0.y) } ?? "-") \(gestures.traceState)\(intents.isEmpty ? "" : " -> \(intents)")")
        for intent in intents { apply(intent) }
        let onClaude = focus.target != nil || ctx.listening != nil
        let progress = ctx.cover.covered || !settings.enabled || !onClaude ? nil : gestures.progress
        ctx.gestureShowing = progress != nil
        ctx.overlay.setGesture(progress)
        dot.place(target: focus.target)
        pushOverlay()
    }

    private func handle(light: FrameLight) {
        guard let covered = ctx.cover.push(light) else { return }
        if covered {
            if ctx.listening != nil { dictation.end(reason: "camera covered") }
            send.afterStop = false
            scroll.cancel()
            gestures.reset()
            Notifier.shared.notify(title: "Camera covered", body: "Gestures are off until the camera is uncovered.")
        }
        health.update()
    }

    private func tick() {
        dropStaleReadings()
        focus.tick()
        for intent in gestures.tick(now: CACurrentMediaTime()) { apply(intent) }
        engine.setForceFullRate(needsFullRate)
        ctx.overlay.setHandsOnInput(ClaudeBridge.secondsSincePhysicalInput() < 1.2)
        scroll.tick()
        let now = CACurrentMediaTime()
        if now - lastAwayCheck >= 0.5 {
            lastAwayCheck = now
            if ctx.listening != nil ? !ctx.busy : scroll.isRunning, ScreenFacts.sessionAway() { interrupt("screen locked") }
        }
        dictation.supervise(now: now)
    }

    /// Every hand frame is needed while dictating, calibrating, or a gesture is in progress.
    private var needsFullRate: Bool {
        ctx.listening != nil || ctx.busy || send.afterStop || state.calibrating || calibrationPending
            || scroll.isActive || scroll.isCoasting || gestures.pinchHeld || gestures.progress != nil
    }

    /// When head readings stop (camera lost, face tracker stalled) the highlight and dot go away instead of freezing.
    private func dropStaleReadings() {
        guard let head = ctx.latestHead, CACurrentMediaTime() - head.t > Self.staleHeadSeconds else { return }
        guard focus.hasTargetOrCandidate || dot.hasDot || state.nosePoint != nil else { return }
        EnsembleLog.write("head readings stopped; clearing the highlight")
        focus.forgetTargetAndCandidate(); dot.clear()
        dot.place(target: nil)
        pushOverlay()
    }

    private func refreshSessions() {
        health.checkPermissions()
        let claudeUp = ctx.bridge.claudeIsRunning()
        dictation.dropIfClaudeGone(running: claudeUp)
        guard claudeUp else {
            ctx.sessions = []; focus.forgetAll(); send.forget(); scroll.cancel(); health.update(); return
        }
        // No refresh while dictating: a slow Claude tree walk would otherwise trip the Accessibility stall limit mid-hold.
        guard !refreshInFlight, ctx.listening == nil else { return }
        // Nobody in front of the camera for 5 s: the window scan (which also costs Claude's own process) runs
        // every 5 s instead of every second, and immediately when a face comes back.
        let now = CACurrentMediaTime()
        guard now - ctx.lastOneFaceT < Self.sessionScanFaceWindow || now - lastSessionScan >= Self.sessionScanIdleInterval else { return }
        lastSessionScan = now
        refreshInFlight = true
        Task { @MainActor in
            defer { self.refreshInFlight = false }
            let found = await self.ctx.bridge.refreshSessions()
            if found.map(\.id) != self.ctx.sessions.map(\.id) { EnsembleLog.write("Claude sessions found: \(found.count) (named \(found.filter { $0.title != nil }.count)) \(found.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" })") }
            self.ctx.sessions = found
            self.health.update()
        }
    }

    // MARK: - Intents and cross-cutting steps

    private func apply(_ intent: GestureIntent) {
        switch intent {
        case .scroll, .dragScroll: break
        default: EnsembleLog.write("gesture: \(intent)")
        }
        if intent == .talkBegan || intent == .sendRequested { ctx.overlay.clearBanner() }
        switch intent {
        case .talkBegan: dictation.begin()
        case .talkEnded(let reason): if ctx.listening != nil { dictation.end(reason: reason.rawValue) }
        case .sendRequested:
            if ctx.listening != nil || ctx.busy { send.afterStop = true; EnsembleLog.write("send after stop") } else { send.request() }
        case .cancelRequested: break
        case .scroll(let dy): scroll.scroll(dy, target: focus.target)
        case .dragScrollEnded: scroll.released()
        case .dragScroll(let handDy): scroll.drag(handDy: handDy, target: focus.target)
        }
    }

    /// The Mac is going to sleep, the screen locked, or the safety check ended the hold: stop dictation now (no
    /// tail wait), and forget anything that was about to act. The text stays; nothing is sent.
    private func interrupt(_ reason: String) {
        EnsembleLog.write("interrupt: \(reason)")
        send.afterStop = false; focus.clearDeferred()
        send.forget()
        scroll.cancel()
        gestures.reset()
        guard ctx.listening != nil else { pushOverlay(); return }
        if ctx.busy {
            dictation.endWhenIdle(reason: reason, immediate: true)
        } else {
            dictation.end(reason: reason, immediate: true)
        }
    }

    private func screensChanged() {
        ctx.invalidateCalibrationCache()
        EnsembleLog.write("screens changed; calibration valid here: \(ctx.calibratedHere)")
        if ctx.listening != nil { dictation.end(reason: "screens changed") }
        if state.calibrating { CalibrationController.shared.cancel() }
        scroll.cancel()
        focus.forgetTarget()
        health.update()
    }

    private func pushOverlay() {
        dictation.restoreAudioIfIdle()
        let acting = ctx.listening ?? (gestures.progress?.action == .send ? send.lastSpoken?.session : nil) ?? focus.target
        ctx.overlay.setSession(name: acting.map(ctx.name(of:)), switching: focus.switching())
        ctx.overlay.update(target: state.targetFrame, nose: state.nosePoint, listening: state.listening,
                           showNoseDot: settings.showNoseDot, showHighlight: settings.showHighlight)
        health.update()
    }
}
