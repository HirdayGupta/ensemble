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
    /// The drawn dot: follows the filtered nose on a leash so small head wobble never moves it.
    private var dotPoint: CGPoint?
    /// Where the gesture bubble sits while a gesture is held or dictation runs; it does not move meanwhile.
    private var frozenPoint: CGPoint?
    private var gestureShowing = false
    private let dotLeash: CGFloat = 36
    /// Last time exactly one face was seen, and the last time more than one was.
    private var lastOneFaceT: TimeInterval = -.infinity
    private var lastManyFacesT: TimeInterval = -.infinity
    private var manyFaceTimes: [TimeInterval] = []
    private var headStats: (since: TimeInterval, n: Int, faces: [Int]) = (0, 0, [0, 0, 0])
    private var sessions: [ClaudeSession] = []
    private var target: ClaudeSession?
    /// A session (or none) the nose moved onto, waiting out `switchDwell` before the highlight follows.
    private var candidate: (session: ClaudeSession?, since: TimeInterval)?
    private let switchDwell = 0.25
    private var listeningSession: ClaudeSession?
    private var lastSpoken: (session: ClaudeSession, stoppedAt: Date)?
    private var pendingSend: (session: ClaudeSession, started: Date, text: String)?
    private var scrollSession: (session: ClaudeSession, lastAt: Date)?
    private var busy = false                 // a start/stop/send is in flight
    /// Thumbs-up made straight from the fist: send once the stop is confirmed.
    private var sendAfterStop = false
    private var tickTimer: Timer?
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var running = false
    /// Front-window check cache: who owns the window under the nose, refreshed at most every 0.15 s.
    private var topOwner: (at: CGPoint, t: TimeInterval, pid: pid_t?)?
    /// Input device and other-capturer state at the start of a hold; a change mid-hold stops dictation.
    private var holdInputDevice: String?
    private var lastHoldAudioCheck: TimeInterval = 0

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
        pointer.setSmoothing(settings.pointerSmoothing)

        settings.$mapping.dropFirst().sink { [weak self] m in self?.gestures.mapping = m; self?.gestures.reset() }.store(in: &cancellables)
        settings.$pointerSmoothing.dropFirst().sink { [weak self] k in self?.pointer.setSmoothing(k) }.store(in: &cancellables)
        settings.$enabled.dropFirst().removeDuplicates().sink { [weak self] on in
            guard let self else { return }
            // @Published fires before the stored value changes, so read settings on the next turn of the run loop.
            DispatchQueue.main.async { on ? self.start() : self.stop() }
        }.store(in: &cancellables)
        settings.$cameraName.dropFirst().removeDuplicates().sink { [weak self] _ in
            guard let self, self.running else { return }
            DispatchQueue.main.async { self.stop(); self.start() }
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
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier?.hasPrefix("com.anthropic.claudefordesktop") == true else { return }
            MainActor.assumeIsolated { ClutchLog.write("Claude launched; sweeping"); self?.sweep() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    // MARK: - AppCoordinating

    func start() {
        ClutchLog.write("start (enabled=\(settings.enabled), camera=\(settings.cameraName ?? "automatic"), calibrated=\(pointer.isCalibrated), accessibility=\(AXIsProcessTrusted()), screens=\(ScreenFacts.displayFingerprint()))")
        state.cameraNames = cameraNames
        sweep()
        guard settings.enabled else { state.status = .off; return }
        if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
            ClutchLog.write("accessibility permission missing")
        }
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
        latestHead = nil
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
        // Calibrating while off turns Clutch on first and waits for the camera's first face reading.
        if !engine.isRunning || latestHead == nil {
            if !settings.enabled { settings.enabled = true } else if !running { start() }   // the enabled sink starts it
            Task { @MainActor in
                for _ in 0..<50 where self.latestHead?.faceCount != 1 { try? await Task.sleep(nanoseconds: 100_000_000) }
                guard self.engine.isRunning, self.latestHead != nil else { self.refuse("The camera did not start; check Camera permission"); return }
                self.calibrate()
            }
            return
        }
        state.calibrating = true
        CalibrationController.shared.run(headSource: { [weak self] in self?.latestHead }) { [weak self] samples in
            guard let self else { return }
            self.state.calibrating = false
            ClutchLog.write("calibration samples: \(samples.count)")
            guard !samples.isEmpty else { return }
            if self.pointer.fit(samples), let data = self.pointer.calibration {
                self.settings.calibration = data
                self.settings.calibratedAt = Date()
                self.settings.calibrationDisplays = ScreenFacts.displayFingerprint()
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
        if head.faceCount == 1 { lastOneFaceT = head.t }
        // A second face counts only when it persists: 5 or more of the readings in the last second.
        manyFaceTimes.append(contentsOf: head.faceCount > 1 ? [head.t] : [])
        manyFaceTimes.removeAll { head.t - $0 > 1.0 }
        if manyFaceTimes.count >= 5 { lastManyFacesT = head.t }
        headStats.n += 1; headStats.faces[min(head.faceCount, 2)] += 1
        if head.t - headStats.since >= 5 {
            let nose = pointer.point(for: head).map { "\(Int($0.x)),\(Int($0.y))" } ?? "none"
            ClutchLog.write("head: \(headStats.n) readings in 5 s, faces 0/1/2+ = \(headStats.faces), nose at \(nose), accessibility \(AXIsProcessTrusted()), Claude running \(bridge.claudeIsRunning()), sessions \(sessions.count), nose on Claude: \(target != nil)")
            headStats = (head.t, 0, [0, 0, 0])
        }
        guard !state.calibrating else { return }
        if head.faceCount == 1, calibratedHere, let p = pointer.point(for: head) {
            // Claude only: the nose counts only over a Claude session whose window is actually in front there.
            let under = sessions.first { $0.frame.contains(p) && claudeInFront(at: p, t: head.t) }
            if under == nil {
                dotPoint = nil
            } else if let d = dotPoint {
                let dist = hypot(p.x - d.x, p.y - d.y)
                if dist > dotLeash { let k = (dist - dotLeash) / dist; dotPoint = CGPoint(x: d.x + (p.x - d.x) * k, y: d.y + (p.y - d.y) * k) }
            } else {
                dotPoint = p
            }
            if under?.id == target?.id {
                candidate = nil
            } else if let c = candidate, c.session?.id == under?.id {
                if head.t - c.since >= switchDwell { target = under; candidate = nil }
            } else {
                candidate = (under, head.t)
            }
        } else if head.faceCount != 1 && head.t - lastOneFaceT <= 1.5 && head.faceCount == 0 {
            // face hidden for a moment (hand in front): keep the last target and dot
        } else {
            dotPoint = nil
            target = nil
        }
        updateDot()
        pushOverlay()
    }

    private func handle(hand: HandObservation) {
        if listeningSession != nil, hand.present, hand.pose == settings.mapping.talk { safety.heartbeat() }
        guard !state.calibrating else { return }
        for intent in gestures.push(hand) { apply(intent) }
        let onClaude = target != nil || listeningSession != nil || pendingSend != nil
        let progress = cover.covered || !settings.enabled || !onClaude ? nil : gestures.progress
        gestureShowing = progress != nil
        overlay.setGesture(progress)
        updateDot()
        pushOverlay()
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
        let now = CACurrentMediaTime()
        if listeningSession != nil, !busy, now - lastHoldAudioCheck >= 0.5 {
            lastHoldAudioCheck = now
            if let other = bridge.otherProcessCapturingInput() {
                refuse("\(other) started using a microphone; dictation stopped"); endTalk(reason: "other capturer")
            } else if let device = holdInputDevice, bridge.defaultInputDeviceName() != device {
                refuse("The input device changed; dictation stopped"); endTalk(reason: "input device changed")
            }
        }
    }

    private func refreshSessions() {
        guard bridge.claudeIsRunning() else {
            sessions = []; target = nil; updateStatus(); return
        }
        Task { @MainActor in
            let found = await self.bridge.refreshSessions()
            if found.map(\.id) != self.sessions.map(\.id) { ClutchLog.write("Claude sessions found: \(found.count) \(found.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" })") }
            self.sessions = found
            self.updateStatus()
        }
    }

    // MARK: - Intents and guards

    private func apply(_ intent: GestureIntent) {
        if case .scroll = intent {} else { ClutchLog.write("gesture: \(intent)") }
        switch intent {
        case .talkBegan: beginTalk()
        case .talkEnded(let reason): if listeningSession != nil { endTalk(reason: reason.rawValue) }
        case .sendRequested:
            if listeningSession != nil { sendAfterStop = true; ClutchLog.write("stop and send") } else { requestSend() }
        case .cancelRequested: if pendingSend != nil { ClutchLog.write("send cancelled by open hand"); pendingSend = nil; state.countdown = nil; Notifier.shared.playCue(.refused); pushOverlay() }
        case .scroll(let dy): scroll(dy)
        }
    }

    /// Shared guards for every gesture that acts on Claude. Returns a refusal reason, or nil when allowed.
    private func commonRefusal() -> String? {
        if !settings.enabled { return "Clutch is off" }
        if cover.covered { return "Camera is covered" }
        // The hand often covers the face as it rises: one face within the last 1.5 s counts, two never do.
        let now = CACurrentMediaTime()
        if now - lastManyFacesT < 1.5 { return "More than one face in view" }
        if now - lastOneFaceT > 1.5 { return "No face in view" }
        if ClaudeBridge.secondsSinceUserInput() < inputQuiet { return "Keyboard or mouse was just used" }
        return nil
    }

    private func beginTalk() {
        guard listeningSession == nil, !busy else { return }
        if let why = commonRefusal() { refuse(why); return }
        guard calibratedHere else { refuse("Calibrate first (or recalibrate for this screen arrangement)"); return }
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
                self.holdInputDevice = self.bridge.defaultInputDeviceName()
                self.safety.episodeConfirmed()
                Notifier.shared.playCue(.listenStart)
            case .refused(let why), .unknown(let why):
                self.listeningSession = nil
                self.state.listening = false
                self.safety.episodeEnded()
                self.refuse("Could not start dictation: \(why)")
                self.checkClaudeUpdate()
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
            if case .done = result {} else { self.sendAfterStop = false }
            switch result {
            case .done:
                ClutchLog.write("dictation stopped")
                self.settings.lastClaudeVersion = self.bridge.claudeVersion
                self.lastSpoken = (session, Date())
                if self.sendAfterStop {
                    self.sendAfterStop = false
                    // Claude finalises the transcript a moment after the mic stops.
                    Task { @MainActor in try? await Task.sleep(nanoseconds: 600_000_000); self.requestSend() }
                }
                Notifier.shared.playCue(.listenEnd)
            case .refused(let why), .unknown(let why):
                self.refuse("Stop not confirmed (\(why)); the safety check keeps watching")
                self.checkClaudeUpdate()
            }
            self.pushOverlay()
        }
    }

    private func requestSend() {
        guard settings.mapping.send != nil else { return }
        guard pendingSend == nil, listeningSession == nil, !busy else { refuse("Send ignored: busy (\(pendingSend != nil ? "countdown running" : listeningSession != nil ? "still listening" : "a step in flight"))"); return }
        if let why = commonRefusal() { refuse(why); return }
        guard let spoken = lastSpoken, Date().timeIntervalSince(spoken.stoppedAt) <= sendWindow else {
            refuse("Nothing dictated in the last \(Int(sendWindow)) seconds"); return
        }
        let session = spoken.session
        if ClaudeBridge.secondsSinceUserInput() < Date().timeIntervalSince(spoken.stoppedAt) { refuse("Keyboard or mouse used since dictation; not sending"); return }
        if let other = bridge.otherProcessCapturingInput() { refuse("\(other) is using a microphone"); return }
        Task { @MainActor in
            guard let text = await self.bridge.draftText(session), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.refuse("The draft is empty"); return
            }
            ClutchLog.write("send countdown started (\(text.count) characters)")
            self.pendingSend = (session, Date(), text)
            Notifier.shared.playCue(.listenStart)
        }
    }

    private func advanceCountdown(_ send: (session: ClaudeSession, started: Date, text: String)) {
        let words = Double(send.text.split(separator: " ").count)
        let duration = settings.sendCountdownSeconds + words * 0.03
        let elapsed = Date().timeIntervalSince(send.started)
        // Cancel on any keyboard or mouse use, or when the nose leaves the session.
        if ClaudeBridge.secondsSinceUserInput() < elapsed || cover.covered {
            refuse(cover.covered ? "Send cancelled: camera covered" : "Send cancelled: keyboard or mouse used")
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
            case .done: ClutchLog.write("sent"); self.lastSpoken = nil; Notifier.shared.playCue(.send)
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

    // MARK: - Dot placement

    /// What the dot shows. While dictating: hidden, except near the session's edges (where you may be looking
    /// away). While a gesture is being held: frozen in place as the gesture bubble. Otherwise: the dot follows
    /// the nose whenever it is over a Claude session and the dot setting is on.
    private func updateDot() {
        if let session = listeningSession {
            frozenPoint = nil
            if let d = dotPoint {
                let inner = session.frame.insetBy(dx: session.frame.width * 0.15, dy: session.frame.height * 0.15)
                state.nosePoint = inner.contains(d) ? nil : d
            } else {
                state.nosePoint = nil
            }
        } else if gestureShowing {
            if frozenPoint == nil { frozenPoint = dotPoint }
            state.nosePoint = frozenPoint
        } else {
            frozenPoint = nil
            state.nosePoint = settings.showNoseDot ? dotPoint : nil
        }
        state.targetFrame = listeningSession?.frame ?? target?.frame
    }

    // MARK: - Screen and version checks

    /// The calibration is usable only on the screen arrangement it was made on.
    private var calibratedHere: Bool {
        guard pointer.isCalibrated else { return false }
        if settings.calibrationDisplays == nil { settings.calibrationDisplays = ScreenFacts.displayFingerprint() }
        return settings.calibrationDisplays == ScreenFacts.displayFingerprint()
    }

    private func claudeInFront(at p: CGPoint, t: TimeInterval) -> Bool {
        if let c = topOwner, t - c.t < 0.15, hypot(c.at.x - p.x, c.at.y - p.y) < 40 { return c.pid == bridge.claudePID }
        let pid = ScreenFacts.topWindowOwner(at: p)
        topOwner = (p, t, pid)
        return pid != nil && pid == bridge.claudePID
    }

    private func screensChanged() {
        ClutchLog.write("screens changed; calibration valid here: \(calibratedHere)")
        if listeningSession != nil { endTalk(reason: "screens changed") }
        pendingSend = nil
        target = nil
        updateStatus()
    }

    /// A failure right after Claude updated may mean its controls changed: switch off and say why.
    private func checkClaudeUpdate() {
        guard let now = bridge.claudeVersion, let last = settings.lastClaudeVersion, now != last else { return }
        ClutchLog.write("Claude updated \(last) -> \(now) and a dictation step failed; switching off")
        Notifier.shared.notify(title: "Clutch switched off", body: "Claude updated to \(now) and its microphone controls did not respond as before.")
        settings.enabled = false
    }

    // MARK: - Output

    private func sweep() {
        Task { await self.safety.launchSweep() }
    }

    private func refuse(_ why: String) {
        state.lastRefusal = why
        if gestureShowing || pendingSend != nil || why.hasPrefix("Send") || why.hasPrefix("Not sent") {
            overlay.showBanner(title: "Clutch", body: why, seconds: 2.5)
        }
        ClutchLog.write("refused: \(why)")
    }

    private func updateStatus() {
        if !settings.enabled || !running { state.status = .off; return }
        if !AXIsProcessTrusted() { state.status = .needsPermission("Accessibility"); return }
        if case .needsPermission = state.status { return }
        if case .error = state.status, !engine.isRunning { return }
        if cover.covered { state.status = .cameraCovered; return }
        if !calibratedHere { state.status = .needsCalibration; return }
        if !bridge.claudeIsRunning() { state.status = .claudeNotRunning; return }
        state.status = state.listening ? .listening : .watching
    }

    private func pushOverlay() {
        overlay.update(target: state.targetFrame, nose: state.nosePoint, listening: state.listening,
                       countdown: state.countdown, showNoseDot: settings.showNoseDot, showHighlight: settings.showHighlight)
        updateStatus()
    }
}
