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
    private let headphone: HeadphoneRemote
    /// Return while dictating: the first press stops, a second sends. See `handleKey`.
    private let keyTap = ReturnKeyTap()
    private var returnKeys = ReturnKeys()
    private var state: AppState { ctx.state }
    private var settings: SettingsStore { ctx.settings }
    private var gestures: GestureMachine { ctx.gestures }

    private var tickTimer: Timer?
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var headStats: (since: TimeInterval, n: Int, faces: [Int]) = (0, 0, [0, 0, 0])
    private var refreshInFlight = false
    private var promptedAccessibility = false
    private var recoveredAtLaunch = false
    private var lastAwayCheck: TimeInterval = 0
    private var lastSessionScan: TimeInterval = 0
    /// Set only while the tour's gesture-practice step is open; see `enterGesturePractice`.
    private var practiceSink: TourPracticeSink?
    /// True while the tour window is open: Ensemble keeps reading the camera (the tour calibrates and practises with
    /// it) but acts on nothing, so looking at the tour never moves Claude's focus or raises a session behind it.
    private var tourOpen = false
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
        headphone = HeadphoneRemote(settingOn: { [weak settings] in (settings?.headphonePresses ?? false) && (settings?.enabled ?? false) },
                                    claudeRunning: { [weak ctx] in ctx?.bridge.claudeIsRunning() ?? false })
        headphone.onAction = { [weak self] in self?.apply(headphone: $0) }
        ctx.changed = { [weak self] in self?.pushOverlay() }
        focus.stopDictation = { [weak self] reason in self?.dictation.end(reason: reason) }
        dictation.interrupt = { [weak self] reason in self?.interrupt(reason) }
        dictation.stopResolved = { [weak self] confirmed in self?.stopResolved(confirmed: confirmed) }
        keyTap.onKey = { [weak self] isReturn, modified, isRepeat in
            self?.handleKey(isReturn: isReturn, modified: modified, isRepeat: isRepeat) ?? false
        }
        keyTap.onReturnUp = { [weak self] in self?.returnKeys.returnReleased() }
        keyTap.onUnseenKeys = { [weak self] in self?.returnKeys.noteUnseenKeys(now: CACurrentMediaTime()) }
        send.returnInputAge = { [weak self] in
            let clicks = ClaudeBridge.secondsSinceClick()
            guard let self else { return clicks }
            return ReturnKeys.inputAge(clickAge: clicks, lastOtherKeyAt: self.returnKeys.lastOtherKeyAt, now: CACurrentMediaTime())
        }

        ctx.pointer.correctsForPosition = settings.correctForPosition
        ctx.pointer.screenSizeProvider = { ScreenGeometry.physicalSizeCm(ofScreenID: $0) }
        if let data = settings.calibration { ctx.pointer.calibration = data }
        ctx.setup.startFullCalibration = { [weak self] in self?.calibrate() }
        ctx.setup.runPlan = { [weak self] plan in self?.runCalibration(plan) }
        gestures.mapping = settings.mapping
        ctx.pointer.setSmoothing(settings.pointerSmoothing)
        gestures.sendHold = settings.sendCountdownSeconds

        settings.$mapping.dropFirst().sink { [weak self] m in self?.gestures.mapping = m; self?.gestures.reset() }.store(in: &cancellables)
        settings.$sendCountdownSeconds.dropFirst().sink { [weak self] v in self?.gestures.sendHold = v }.store(in: &cancellables)
        settings.$correctForPosition.dropFirst().sink { [weak self] on in self?.ctx.pointer.correctsForPosition = on }.store(in: &cancellables)
        settings.$pointerSmoothing.dropFirst().sink { [weak self] k in self?.ctx.pointer.setSmoothing(k) }.store(in: &cancellables)
        settings.$enabled.removeDuplicates().dropFirst().sink { [weak self] on in
            guard let self else { return }
            // @Published fires before the stored value changes, so read settings on the next turn of the run loop.
            DispatchQueue.main.async { on ? self.start() : self.stop(disarm: true) }
        }.store(in: &cancellables)
        settings.$headphonePresses.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.headphone.refresh() }
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
        if recoveredAtLaunch { recoveredAtLaunch = false } else { recoverAtLaunch() }
        guard settings.enabled else { state.status = .off; return }
        if !Permissions.accessibilityTrusted {
            EnsembleLog.write("accessibility permission missing (if Ensemble is already listed in Settings, remove it and add it again)")
            // Never over the tour: its permissions step has the button, and closing the tour asks (exitTour).
            if !tourOpen { promptAccessibilityOnce() }
        }
        health.begin()
        headphone.start()
        ctx.latestHead = nil
        engine.start(cameraName: settings.cameraName)
        tickTimer?.invalidate()
        tickTimer = commonModeTimer(1.0 / 20.0) { [weak self] in self?.tick() }
        refreshTimer?.invalidate()
        refreshTimer = commonModeTimer(1.0) { [weak self] in self?.refreshSessions() }
        refreshSessions()
        health.update()
    }

    /// Crash recovery that must not wait for the camera: a record or mute left by an earlier run is put right at
    /// launch even when the first-run tour holds `start()` back.
    func recoverAtLaunch() {
        recoveredAtLaunch = true
        dictation.sweep()
        MediaDucker.recoverAfterCrash()
    }

    private func promptAccessibilityOnce() {
        guard !promptedAccessibility else { return }
        promptedAccessibility = true
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
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
        headphone.stop()
        if disarm { dictation.clearAndDisarm() } else if ctx.listening != nil { dictation.end(reason: "turned off") }
        engine.stop()
        gestures.reset()
        scroll.cancel()
        focus.clearDeferred(); send.afterStop = false; send.forget()
        focus.forgetTarget()
        returnKeys.reset(); keyTap.setActive(false)
        state.status = .off
        pushOverlay()
    }

    /// Quit path: blocks (at most about two seconds) until Claude's microphone is confirmed off and our mute is undone.
    func shutdown() {
        EnsembleLog.write("shutdown")
        health.running = false
        tickTimer?.invalidate(); tickTimer = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        headphone.stop()
        ctx.bridge.beginShutdown()
        engine.stop()
        scroll.cancel()
        dictation.shutdown()
        EnsembleLog.flush()
    }

    func calibrate() { calibrate(.recalibrate) }

    func calibrate(_ request: CalibrationRequest) {
        let clickedAt = CACurrentMediaTime()
        guard !state.calibrating else { EnsembleLog.write("calibrate ignored: already in progress"); return }
        guard let plan = ctx.setup.plan(for: request) else { ctx.refuse("That screen is no longer connected"); return }
        EnsembleLog.write("calibrate requested (\(request), \(plan.purpose), enabled=\(settings.enabled), engine running=\(engine.isRunning), face tracker ready=\(health.trackerReady))")
        // The window goes up first, before anything that can take time. Calibrating while off, or while the camera is
        // down, then turns Ensemble on or restarts the camera behind the window, which says what it is waiting for.
        runCalibration(plan, clickedAt: clickedAt)
        if !settings.enabled { settings.enabled = true } else if !health.running || !engine.isRunning { start() }   // the enabled sink starts it
    }

    func removeCalibrationSpot(_ id: String) {
        guard !state.calibrating else { return }
        EnsembleLog.write("calibration position \(id) removed")
        ctx.setup.removeSpot(id)
        health.update()
    }

    /// Runs one calibration plan: every screen or only some, for the position in use or a new one. What the
    /// run collected is stored as the plan's purpose says.
    private func runCalibration(_ plan: CalibrationPlan, clickedAt: TimeInterval = CACurrentMediaTime()) {
        let fingerprint = ScreenFacts.displayFingerprint()
        let camera = state.cameraName
        state.calibrating = true
        let feed = CalibrationFeed(
            head: { [weak self] in self?.ctx.latestHead },
            waitingFor: { [weak self] in
                guard let self else { return "Looking for your face\u{2026}" }
                if !self.health.cameraAllowed { return "Waiting for Camera permission\u{2026}" }
                if !self.engine.isRunning { return "Starting the camera\u{2026}" }
                if !self.health.trackerReady { return "Loading face tracking\u{2026}" }
                return "Looking for your face\u{2026}"
            },
            failure: { [weak self] in
                // Only once the camera path has been (re)started for this run: an earlier failure is not this run's.
                guard let self, self.health.running, self.health.cameraFailed else { return nil }
                return self.health.cameraAllowed ? "The camera did not start: \(self.health.failure ?? "no reading")" : "Calibration needs Camera permission"
            })
        CalibrationController.shared.run(screens: plan.screens, note: plan.note, feed: feed, clickedAt: clickedAt) { [weak self] results in
            guard let self else { return }
            self.state.calibrating = false
            EnsembleLog.write("calibration samples: \(results.map(\.samples.count))")
            let failure = CalibrationController.shared.failure
            guard !results.isEmpty else {
                if let failure { self.ctx.refuse(failure) }
                return
            }
            guard ScreenFacts.displayFingerprint() == fingerprint, self.state.cameraName == camera else {
                self.ctx.refuse("Calibration discarded: the screens or the camera changed while it ran; try again")
                return
            }
            let ok = self.ctx.setup.storeCalibration(results, purpose: plan.purpose)
            if !ok { self.ctx.refuse("Calibration did not fit; try again sitting where you normally work") }
            else if let failure { self.ctx.refuse(failure) }
            self.health.update()
        }
        // Calibration owns the hands and the head: end any dictation first, because
        // gesture events are ignored while it runs and a held talk pose would never be seen released.
        send.afterStop = false
        gestures.reset()
        scroll.cancel()
        if ctx.listening != nil { dictation.endWhenIdle(reason: "calibrating") }
    }

    /// While the tour practices gestures, real intents and head readings go to `sink` instead of acting on
    /// Claude: nothing is pressed, dictated or sent. Ends any dictation already in progress first, the same
    /// as `calibrate()` does, so a hold left over from real use cannot fire once the tour reads it.
    func enterGesturePractice(_ sink: TourPracticeSink) {
        send.afterStop = false
        gestures.reset()
        scroll.cancel()
        if ctx.listening != nil { dictation.endWhenIdle(reason: "tour practice") }
        practiceSink = sink
    }

    func exitGesturePractice() {
        practiceSink = nil
        gestures.reset()
        scroll.cancel()
    }

    func enterTour() {
        tourOpen = true
        send.afterStop = false
        gestures.reset()
        scroll.cancel()
        if ctx.listening != nil { dictation.endWhenIdle(reason: "tour opened") }
        focus.forgetTargetAndCandidate()
        dot.clear()
        dot.place(target: nil)
        ctx.overlay.setGesture(nil)
        pushOverlay()
    }

    func exitTour() {
        tourOpen = false
        if settings.enabled, !Permissions.accessibilityTrusted { promptAccessibilityOnce() }
        gestures.reset()
        scroll.cancel()
    }

    // MARK: - Inputs

    private func handle(head: HeadObservation) {
        ctx.latestHead = head
        if let sink = practiceSink { sink.tourPractice(head: head); return }
        if tourOpen { return }
        if head.faceCount == 1 {
            let returned = head.t - ctx.lastOneFaceT >= Self.sessionScanFaceWindow
            ctx.lastOneFaceT = head.t
            if returned { refreshSessions() }
        }
        logHeadStats(head)
        guard !state.calibrating else { return }
        if head.faceCount == 1, ctx.calibratedHere, let p = ctx.pointer.point(for: head), ctx.setup.isUsable(p) {
            // A pinch or scroll in progress holds everything still: the hand is in front of the face.
            state.set(\.spotInUse, ctx.setup.spotInUseID)
            let under = focus.observe(nose: p, at: head.t, held: gestures.pinchHeld || scroll.isActive)
            dot.follow(nose: p, at: head.t, onSession: under != nil)
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
        practiceSink?.tourPractice(hand: hand)
        if let sink = practiceSink {
            for intent in intents { sink.tourPractice(intent: intent) }
            return
        }
        if tourOpen { return }
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
        for intent in gestures.tick(now: CACurrentMediaTime()) {
            if let sink = practiceSink { sink.tourPractice(intent: intent) } else if !tourOpen { apply(intent) }
        }
        engine.setForceFullRate(needsFullRate)
        ctx.overlay.setHandsOnInput(ClaudeBridge.secondsSincePhysicalInput() < 1.2)
        scroll.tick()
        let now = CACurrentMediaTime()
        if now - lastAwayCheck >= 0.5 {
            lastAwayCheck = now
            if ctx.listening != nil ? !ctx.busy : scroll.isRunning, ScreenFacts.sessionAway() { interrupt("screen locked") }
        }
        dictation.supervise(now: now)
        if returnKeys.expire(now: now) { ctx.refuse("Not sent: the stop was not confirmed") }
        keyTap.setActive(health.running && (ctx.listening != nil || returnKeys.wantsKeys(now: now)))
    }

    /// Every hand frame is needed while dictating, calibrating, or a gesture is in progress.
    private var needsFullRate: Bool {
        ctx.listening != nil || ctx.busy || send.afterStop || state.calibrating
            || scroll.isActive || scroll.isCoasting || gestures.pinchHeld || gestures.progress != nil || practiceSink != nil
    }

    /// When head readings stop (camera lost, face tracker stalled) the highlight and dot go away instead of freezing.
    private func dropStaleReadings() {
        guard let head = ctx.latestHead, CACurrentMediaTime() - head.t > Self.staleHeadSeconds else { return }
        guard focus.hasTargetOrCandidate || dot.hasDot || dot.hasEdgeWarning || state.nosePoint != nil else { return }
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
            // While the setup prompt shows, the held thumbs-up answers it instead of sending.
            if ctx.setup.isPromptShowing { ctx.setup.start(); return }
            if ctx.listening != nil || ctx.busy { send.afterStop = true; EnsembleLog.write("send after stop") } else { send.request() }
        case .cancelRequested: break
        case .scroll(let dy): scroll.scroll(dy, target: focus.target)
        case .dragScrollEnded: scroll.released()
        case .dragScroll(let handDy): scroll.drag(handDy: handDy, target: focus.target)
        }
    }

    /// A stem press. Both go through the same guards as the gestures: a press is the double pinch (dictation
    /// begins only on the session the nose is on, with calibration and every common refusal), a double press is the
    /// thumbs-up (the narrow send rules in SendController, unchanged).
    private func apply(headphone action: HeadphoneAction) {
        // Tour practice promises nothing reaches Claude; a stem press is no exception.
        guard practiceSink == nil, !tourOpen else { return }
        ctx.headphoneUntil = CACurrentMediaTime() + 5
        ctx.overlay.clearBanner()
        switch action {
        case .press:
            guard !ctx.busy else { ctx.refuse("A step is still in flight"); return }
            if ctx.listening != nil {
                ctx.overlay.showBanner(title: "Headphone press", body: "Stopping dictation", style: .info, seconds: 1.5)
                dictation.end(reason: "headphone press")
            } else {
                ctx.overlay.showBanner(title: "Headphone press", body: "Starting dictation", style: .info, seconds: 1.5)
                // The machine takes the state a double pinch leaves: a later double pinch stops this dictation, and
                // a refusal inside begin() flips it back.
                gestures.beginTalkExternally()
                dictation.begin()
            }
        case .doublePress:
            guard settings.mapping.send != nil else { ctx.refuse("Send is off in Settings"); return }
            guard !ctx.busy else { ctx.refuse("Send ignored: a step is still in flight"); return }
            ctx.overlay.showBanner(title: "Headphone double press", body: "Sending the draft", style: .info, seconds: 1.5)
            if ctx.listening != nil {
                // Same as the thumbs-up held from the talk pose: stop, then send once the stop is confirmed.
                send.afterStop = true
                dictation.end(reason: "headphone double press")
            } else {
                send.request()
            }
        }
    }

    /// A key press while the key watch is on (an Ensemble dictation, or just after one). Only Return without
    /// modifiers, with Claude in front, is ever kept from Claude; the rules are in `ReturnKeys`.
    private func handleKey(isReturn: Bool, modified: Bool, isRepeat: Bool) -> Bool {
        let now = CACurrentMediaTime()
        let decision = returnKeys.press(isReturn: isReturn, modified: modified, isRepeat: isRepeat,
                                        claudeInFront: ctx.bridge.claudeIsFrontmost(), dictating: ctx.listening != nil, now: now)
        switch decision {
        case .pass:
            return false
        case .swallow:
            return true
        case .swallowAndStop:
            EnsembleLog.write("Return: stopping dictation")
            ctx.overlay.clearBanner()
            // A start or stop press may be in flight; the stop then waits for it, the same as calibrating does.
            if ctx.busy { dictation.endWhenIdle(reason: "Return") } else { dictation.end(reason: "Return") }
            return true
        case .swallowAndSendAfterStop:
            EnsembleLog.write("Return twice: send after stop")
            send.afterStop = true
            send.afterStopByReturn = true
            return true
        case .swallowAndSend:
            EnsembleLog.write("Return twice: sending")
            // The stop was confirmed a moment ago; Claude finalises the transcript shortly after the mic stops.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                self.send.request(byReturn: true)
            }
            return true
        }
    }

    private func stopResolved(confirmed: Bool) {
        if confirmed {
            returnKeys.stopConfirmed(now: CACurrentMediaTime())
        } else if returnKeys.stopFailed() {
            ctx.refuse("Not sent: the stop was not confirmed")
        }
    }

    /// The Mac is going to sleep, the screen locked, or the safety check ended the hold: stop dictation now (no
    /// tail wait), and forget anything that was about to act. The text stays; nothing is sent.
    private func interrupt(_ reason: String) {
        EnsembleLog.write("interrupt: \(reason)")
        send.afterStop = false; focus.clearDeferred()
        returnKeys.reset()
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
        ctx.setup.screensChanged()
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
        ctx.overlay.setEdge(dot.overlayEdge(focus: focus))
        ctx.overlay.update(target: state.targetFrame, nose: state.nosePoint, listening: state.listening,
                           showNoseDot: settings.showNoseDot, showHighlight: settings.showHighlight)
        health.update()
    }
}
