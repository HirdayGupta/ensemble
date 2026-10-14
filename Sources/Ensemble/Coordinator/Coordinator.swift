import AppKit
import AVFoundation
import Combine
import EnsembleCore

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
    /// The latest smoothed nose point, wherever it is (also off Claude): drives the edge marker while listening.
    private var lastNose: CGPoint?
    /// Where the gesture bubble sits while a gesture is held or dictation runs; it does not move meanwhile.
    private var frozenPoint: CGPoint?
    private var gestureShowing = false
    private let dotLeash: CGFloat = 24
    /// Last time exactly one face was seen, and the last time more than one was.
    private var lastOneFaceT: TimeInterval = -.infinity

    private var headStats: (since: TimeInterval, n: Int, faces: [Int]) = (0, 0, [0, 0, 0])
    private var sessions: [ClaudeSession] = []
    private var target: ClaudeSession?
    /// A session (or none) the nose moved onto, waiting out `switchDwell` before the highlight follows.
    private var candidate: (session: ClaudeSession?, since: TimeInterval)?
    /// 0.075 s (2026-10-14: 0.6 s felt slow): focus follows the nose almost at once; the border margin
    /// below keeps it from flipping between two neighbouring panes.
    private let switchDwell = 0.075
    /// Moving from one session to another, the nose must be this far inside the new one: no flip-flopping
    /// on the border between two panes.
    private let switchMargin: CGFloat = 28
    /// While dictating, the nose must stay on another session this long before focus moves there.
    private let listeningSwitchDwell = 2.0
    /// A Claude session the nose rests on while another app's window covers it; raised after `raiseDwell`.
    private var covered: (id: String, since: TimeInterval)?
    private let raiseDwell = 0.8
    private var lastRaiseBlockLog: TimeInterval = 0
    /// Session to focus once a dictation stop (caused by looking at it) completes.
    private var focusAfterStop: ClaudeSession?
    /// The session Ensemble last moved focus to.
    private var lastFocusedId: String?
    private var pendingFocus: (session: ClaudeSession, until: TimeInterval)?   // a look-away focus that was deferred by busy or typing
    private var listeningSession: ClaudeSession?
    private var lastSpoken: (session: ClaudeSession, stoppedAt: Date)?
    private var pendingSend: (session: ClaudeSession, started: Date, text: String)?
    private var scrollSession: (session: ClaudeSession, lastAt: Date)?
    private var pendingScroll = 0.0
    /// Smooth scrolling: hand motion adds distance to `scrollRemaining`; a 60 Hz loop delivers a fixed share of
    /// it each frame (an exponential glide that irons out hand-tracking jitter), and a short coast continues the
    /// last velocity after the pinch is released, like a trackpad flick.
    private var scrollRemaining = 0.0
    private var scrollVelocity = 0.0          // points per second, smoothed, for the coast
    private var scrollTarget: CGPoint?
    private var scrollTimer: Timer?
    private let scrollEase = 0.2              // share of the remaining distance delivered per 1/60 s frame
    /// Upward pinch strokes are naturally shorter than downward ones, so they count this much more.
    private let upStrokeGain = 1.6
    /// Recent scroll output, for the release velocity.
    private var recentScroll: [(t: TimeInterval, dy: Double)] = []
    /// Momentum after a fast release: points per second, decaying each frame. A slow release stops dead.
    private var inertia = 0.0
    private let flickThreshold = 2500.0       // points per second at release to start momentum
    private let inertiaFriction = 0.955       // per 1/60 s frame
    private let meter = AudioLevelMeter()
    /// Fades out and pauses other audio on speakers while dictating, so it is not transcribed.
    private let ducker = MediaDucker()
    private var duckWanted = false
    private var busy = false                 // a start/stop/send is in flight
    private var disarming = false            // "Clear and disarm" is stopping the microphone
    /// Thumbs-up made straight from the fist: send once the stop is confirmed.
    private var sendAfterStop = false
    private var tickTimer: Timer?
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var running = false
    /// What the camera engine last reported, kept apart from `state.status` so every pass recomputes the status from facts.
    private var cameraProblem: String?
    private var trackerFailure: String?
    private var trackerReady = false
    private var accessibilityTrusted = true
    private var cameraAllowed = true
    private var lastCameraRestart = Date.distantPast
    private var calibrationPending = false
    private var refreshInFlight = false
    private var promptedAccessibility = false
    /// Front-window check cache: who owns the window under the nose, refreshed at most every 0.15 s.
    private var topOwner: (at: CGPoint, t: TimeInterval, pid: pid_t?)?
    /// Input device and other-capturer state at the start of a hold; a change mid-hold stops dictation.
    private var holdInputDevice: String?
    private var lastHoldAudioCheck: TimeInterval = 0
    private var audioCheckInFlight = false
    private var calibratedCache: (value: Bool, at: TimeInterval)?
    private var claudeRunningCache: (value: Bool, at: TimeInterval)?
    private var listeningSince: TimeInterval = 0
    /// Claude's process when the dictation began: a different (or missing) one later means the dictation is gone.
    private var listeningPID: pid_t?
    private var lastAwayCheck: TimeInterval = 0
    private var lastScrollOwnerCheck: TimeInterval = 0

    /// Gestures are refused within this long after the keyboard, mouse or trackpad was used.
    private let inputQuiet = 1.5
    /// A thumbs-up sends only this soon after dictation stopped.
    private let sendWindow = 30.0
    /// Wait this long after the hand opens before stopping, so the last word is caught.
    private let stopTail = 0.4
    private static let staleHeadSeconds = 2.0
    private static let sessionScanFaceWindow = 5.0
    private static let sessionScanIdleInterval = 5.0
    private var lastSessionScan: TimeInterval = 0

    var cameraNames: [String] { VisionEngine.cameraNames() }

    init(state: AppState, settings: SettingsStore, overlay: OverlayController) {
        self.state = state
        self.settings = settings
        self.overlay = overlay
        if let data = settings.calibration { pointer.calibration = data }
        if pointer.isCalibrated, settings.calibrationDisplays == nil { settings.calibrationDisplays = ScreenFacts.displayFingerprint() }
        gestures.mapping = settings.mapping
        pointer.setSmoothing(settings.pointerSmoothing)
        gestures.sendHold = settings.sendCountdownSeconds

        settings.$mapping.dropFirst().sink { [weak self] m in self?.gestures.mapping = m; self?.gestures.reset() }.store(in: &cancellables)
        settings.$sendCountdownSeconds.dropFirst().sink { [weak self] v in self?.gestures.sendHold = v }.store(in: &cancellables)
        settings.$pointerSmoothing.dropFirst().sink { [weak self] k in self?.pointer.setSmoothing(k) }.store(in: &cancellables)
        settings.$enabled.removeDuplicates().dropFirst().sink { [weak self] on in
            guard let self else { return }
            // @Published fires before the stored value changes, so read settings on the next turn of the run loop.
            DispatchQueue.main.async { on ? self.start() : self.stop() }
        }.store(in: &cancellables)
        settings.$cameraName.removeDuplicates().dropFirst().sink { [weak self] _ in
            guard let self, self.running else { return }
            DispatchQueue.main.async { self.stop(); self.start() }
        }.store(in: &cancellables)

        engine.onHand = { [weak self] in self?.handle(hand: $0) }
        meter.onLevel = { [weak self] v in self?.overlay.setAudioLevel(v) }
        overlay.setLiveSoundBars(settings.liveSoundBars)
        settings.$liveSoundBars.dropFirst().sink { [weak self] on in
            guard let self else { return }
            self.overlay.setLiveSoundBars(on)
            if !on { self.meter.stop() } else if self.listeningSession != nil { self.meter.start() }
        }.store(in: &cancellables)
        engine.onHead = { [weak self] in self?.handle(head: $0) }
        engine.onLight = { [weak self] in self?.handle(light: $0) }
        engine.onStatus = { [weak self] in self?.handle(status: $0) }
        engine.onDiagnostic = { note in EnsembleLog.write("engine: \(note)") }
        safety.onAlarm = { [weak self] msg in
            self?.refuse("Alarm: \(msg)")
            Notifier.shared.notify(title: "Claude's microphone may still be on", body: msg)
        }
        safety.onMuted = { [weak self] muted in self?.state.muted = muted }
        safety.onHoldEnded = { [weak self] why in
            MainActor.assumeIsolated {
                guard let self, self.listeningSession != nil else { return }
                self.refuse("The safety check stopped dictation (\(why))")
                self.interrupt("safety check: \(why)")
            }
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.interrupt("system: \(note.name.rawValue)") }
            }
        }
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.interrupt("screen locked") }
            }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier?.hasPrefix("com.anthropic.claudefordesktop") == true else { return }
            MainActor.assumeIsolated { EnsembleLog.write("Claude launched; sweeping"); self?.sweep() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    // MARK: - AppCoordinating

    func start() {
        EnsembleLog.write("start (enabled=\(settings.enabled), camera=\(settings.cameraName ?? "automatic"), calibrated=\(pointer.isCalibrated), accessibility=\(AXIsProcessTrusted()), screens=\(ScreenFacts.displayFingerprint()))")
        state.cameraNames = cameraNames
        sweep()
        MediaDucker.recoverAfterCrash()
        guard settings.enabled else { state.status = .off; return }
        if !Permissions.accessibilityTrusted {
            EnsembleLog.write("accessibility permission missing (if Ensemble is already listed in Settings, remove it and add it again)")
            if !promptedAccessibility {
                promptedAccessibility = true
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
        }
        running = true
        accessibilityTrusted = Permissions.accessibilityTrusted
        cameraAllowed = Permissions.cameraAllowed
        cameraProblem = nil; trackerFailure = nil; trackerReady = false
        latestHead = nil
        lastCameraRestart = Date()
        engine.start(cameraName: settings.cameraName)
        tickTimer?.invalidate()
        tickTimer = commonModeTimer(1.0 / 20.0) { [weak self] in self?.tick() }
        refreshTimer?.invalidate()
        refreshTimer = commonModeTimer(1.0) { [weak self] in self?.refreshSessions() }
        refreshSessions()
        updateStatus()
    }

    /// Common run-loop mode keeps the timers firing while a slider is dragged or a menu is open.
    private func commonModeTimer(_ interval: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { fire() } }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    func stop() {
        EnsembleLog.write("stop")
        running = false
        latestHead = nil
        tickTimer?.invalidate(); tickTimer = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        if listeningSession != nil { endTalk(reason: "turned off") }
        engine.stop()
        gestures.reset()
        cancelScroll()
        pendingSend = nil
        pendingFocus = nil; focusAfterStop = nil; sendAfterStop = false; lastSpoken = nil
        target = nil
        state.status = .off
        pushOverlay()
    }

    func calibrate() {
        guard !calibrationPending, !state.calibrating else { EnsembleLog.write("calibrate ignored: already in progress"); return }
        EnsembleLog.write("calibrate requested (engine running=\(engine.isRunning), face tracker ready=\(trackerReady))")
        // Calibrating while off, or while the camera is down, turns Ensemble on or restarts the camera and waits
        // (up to 30 s: a first camera prompt plus the model load) for the face tracker to produce a reading.
        if !engine.isRunning || !trackerReady || latestHead == nil {
            calibrationPending = true
            if !settings.enabled { settings.enabled = true } else if !running || !engine.isRunning { start() }   // the enabled sink starts it
            Task { @MainActor in
                defer { self.calibrationPending = false }
                for _ in 0..<300 where !(self.engine.isRunning && self.trackerReady && self.latestHead != nil) {
                    if !self.cameraAllowed || self.cameraProblem != nil || self.trackerFailure != nil { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                guard self.engine.isRunning, self.trackerReady, self.latestHead != nil else {
                    if !self.cameraAllowed { self.refuse("Calibration needs Camera permission") }
                    else { self.refuse("The camera did not start: \(self.cameraProblem ?? self.trackerFailure ?? "no reading within 30 s")") }
                    return
                }
                self.calibrationPending = false
                self.calibrate()
            }
            return
        }
        // Calibration owns the hands and the head: end any dictation and drop any pending send first, because
        // gesture events are ignored while it runs and a held talk pose would never be seen released.
        pendingSend = nil; state.countdown = nil; sendAfterStop = false
        gestures.reset()
        cancelScroll()
        if listeningSession != nil { endTalkWhenIdle(reason: "calibrating") }
        let fingerprint = ScreenFacts.displayFingerprint()
        let camera = state.cameraName
        state.calibrating = true
        CalibrationController.shared.run(headSource: { [weak self] in self?.latestHead }) { [weak self] samples in
            guard let self else { return }
            self.state.calibrating = false
            EnsembleLog.write("calibration samples: \(samples.count)")
            guard !samples.isEmpty else { return }
            guard ScreenFacts.displayFingerprint() == fingerprint, self.state.cameraName == camera else {
                self.refuse("Calibration discarded: the screens or the camera changed while it ran; try again")
                return
            }
            if self.pointer.fit(samples), let data = self.pointer.calibration {
                self.settings.calibration = data
                self.settings.calibratedAt = Date()
                self.settings.calibrationDisplays = fingerprint; self.calibratedCache = nil
                self.pointer.resetFilter()
            } else {
                self.refuse("Calibration did not fit; try again sitting where you normally work")
            }
            self.updateStatus()
        }
    }

    private func endTalkWhenIdle(reason: String, immediate: Bool = false) {
        Task { @MainActor in
            for _ in 0..<30 where self.busy { try? await Task.sleep(nanoseconds: 100_000_000) }
            if self.listeningSession != nil { self.endTalk(reason: reason, immediate: immediate) }
        }
    }

    /// Quit path: blocks (at most about two seconds) until Claude's microphone is confirmed off and our mute is undone.
    func shutdown() {
        EnsembleLog.write("shutdown")
        running = false
        tickTimer?.invalidate(); tickTimer = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        bridge.beginShutdown()
        engine.stop()
        cancelScroll()
        let session = listeningSession
        listeningSession = nil
        pendingSend = nil
        ducker.restoreNow()
        safety.stopForTermination(session: session)
        EnsembleLog.flush()
    }

    func clearAndDisarm() {
        guard !disarming else { return }
        disarming = true
        pendingSend = nil
        sendAfterStop = false
        state.countdown = nil
        gestures.reset()
        EnsembleLog.write("clear and disarm requested")
        Task { @MainActor in
            for _ in 0..<30 where self.busy { try? await Task.sleep(nanoseconds: 100_000_000) }
            let result = await self.bridge.stopAnyDictation()
            var capture = self.bridge.claudeCaptureActive()
            for _ in 0..<15 where capture == true {
                try? await Task.sleep(nanoseconds: 100_000_000)
                capture = self.bridge.claudeCaptureActive()
            }
            self.disarming = false
            self.listeningSession = nil
            self.state.listening = false
            if capture == true || !self.safety.clearAndDisarm() {
                EnsembleLog.write("clear and disarm: microphone still recording (stop \(result)); the safety check keeps watching")
                self.safety.episodeEnded()
                self.refuse("Could not confirm the microphone is off; the safety check keeps watching")
            } else {
                EnsembleLog.write("clear and disarm: microphone confirmed off")
            }
            self.pushOverlay()
            self.settings.enabled = false
        }
    }

    // MARK: - Inputs

    private func handle(head: HeadObservation) {
        latestHead = head
        faceCount = head.faceCount
        if head.faceCount == 1 {
            let returned = head.t - lastOneFaceT >= Self.sessionScanFaceWindow
            lastOneFaceT = head.t
            if returned { refreshSessions() }
        }

        headStats.n += 1; headStats.faces[min(head.faceCount, 2)] += 1
        if head.t - headStats.since >= 30 {
            let nose = pointer.point(for: head).map { "\(Int($0.x)),\(Int($0.y))" } ?? "none"
            EnsembleLog.write("head: \(headStats.n) readings in 30 s, faces 0/1/2+ = \(headStats.faces), nose at \(nose), accessibility \(AXIsProcessTrusted()), Claude running \(bridge.claudeIsRunning()), sessions \(sessions.count), nose on Claude: \(target != nil), \(bridge.micSnapshot)")
            headStats = (head.t, 0, [0, 0, 0])
        }
        guard !state.calibrating else { return }
        if head.faceCount == 1, calibratedHere, let p = pointer.point(for: head) {
            lastNose = p
            // Claude only: the nose counts only over a Claude session whose window is actually in front there.
            var under = sessions.first { $0.frame.contains(p) && claudeInFront(at: p, t: head.t) }
            // Near the border between the current session and another, stay with the current one.
            if let u = under, let t = target, u.id != t.id, !u.frame.insetBy(dx: switchMargin, dy: switchMargin).contains(p),
               let still = sessions.first(where: { $0.id == t.id }), still.frame.insetBy(dx: -switchMargin, dy: -switchMargin).contains(p) {
                under = still
            }
            if under == nil {
                dotPoint = nil
            } else if let d = dotPoint {
                let dist = hypot(p.x - d.x, p.y - d.y)
                if dist > dotLeash { let k = (dist - dotLeash) / dist; dotPoint = CGPoint(x: d.x + (p.x - d.x) * k, y: d.y + (p.y - d.y) * k) }
            } else {
                dotPoint = p
            }
            if gestures.pinchHeld || scrollSession != nil {
                candidate = nil                                   // hand in front of the face: hold everything still
            } else if under?.id == target?.id {
                candidate = nil
            } else if let c = candidate, c.session?.id == under?.id {
                let dwell = listeningSession != nil && under != nil ? listeningSwitchDwell : switchDwell
                if head.t - c.since >= dwell { target = under; candidate = nil; if let t = under { lookedAt(t) } }
            } else {
                candidate = (under, head.t)
            }
            // A Claude session hidden behind another app's window: resting the nose on it brings Claude forward.
            if under == nil, !gestures.pinchHeld, scrollSession == nil, let hidden = sessions.first(where: { $0.frame.contains(p) }) {
                if covered?.id != hidden.id { covered = (hidden.id, head.t) }
                else if let c = covered, head.t - c.since >= raiseDwell {
                    let typed = ClaudeBridge.secondsSinceTypingOrClick() < inputQuiet
                    if busy || typed {
                        if head.t - lastRaiseBlockLog > 5 { lastRaiseBlockLog = head.t; EnsembleLog.write("raise held back: \(busy ? "busy" : "typing or clicking")") }
                    } else {
                        covered = nil
                        EnsembleLog.write("raising Claude: nose rested on a covered session")
                        overlay.flashArrival(hidden.frame)
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 120_000_000)   // let the glow lead the window
                            let r = await self.bridge.focus(hidden, unlessTypedWithin: self.inputQuiet)
                            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
                            EnsembleLog.write("raise result: \(r), frontmost now \(front)")
                        }
                    }
                }
            } else {
                covered = nil
            }
            EnsembleTrace.write(head.t, "head nose=\(Int(p.x)),\(Int(p.y)) under=\(under?.id ?? "-") target=\(target?.id ?? "-") cand=\(candidate.map { "\($0.session?.id ?? "none")@\(String(format: "%.2f", head.t - $0.since))" } ?? "-") faces=\(head.faceCount)")
        } else if head.faceCount != 1 && head.t - lastOneFaceT <= 1.5 {
            // A hand in front of the face hides it or reads as a second face for a moment: keep the target.
            // face hidden for a moment (hand in front): keep the last target and dot
        } else {
            dotPoint = nil
            target = nil
        }
        updateDot()
        pushOverlay()
    }

    private func handle(hand: HandObservation) {
        if listeningSession != nil { safety.heartbeat() }   // a fresh camera frame: the engine is alive
        guard !state.calibrating else { return }
        let intents = gestures.push(hand)
        EnsembleTrace.write(hand.t, "hand present=\(hand.present ? 1 : 0) pose=\(hand.pose?.rawValue ?? "-") pinch=\(hand.pinch.map { String(format: "%.3f", $0) } ?? "-") palm=\(hand.palmCenter.map { String(format: "%.3f,%.3f", $0.x, $0.y) } ?? "-") \(gestures.traceState)\(intents.isEmpty ? "" : " -> \(intents)")")
        for intent in intents { apply(intent) }
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
            sendAfterStop = false
            cancelScroll()
            gestures.reset()
            Notifier.shared.notify(title: "Camera covered", body: "Gestures are off until the camera is uncovered.")
        }
        updateStatus()
    }

    private func handle(status: EngineStatus) {
        if case .running = status {} else { EnsembleLog.write("engine: \(status)") }
        switch status {
        case .starting:
            cameraProblem = nil; trackerFailure = nil; trackerReady = false
        case .running(let fps, let camera):
            cameraProblem = nil
            state.set(\.fps, fps)
            state.set(\.cameraName, camera)
        case .permissionDenied:
            cameraAllowed = false
        case .noCamera:
            cameraProblem = "No camera found"
        case .error(let msg):
            cameraProblem = msg
        case .faceTrackerReady:
            trackerReady = true; trackerFailure = nil
        case .faceTrackerRestarting:
            trackerReady = false
        case .faceTrackerFailed(let msg):
            trackerReady = false; trackerFailure = msg
        case .stopped:
            trackerReady = false
        }
        updateStatus()
    }

    private func tick() {
        dropStaleReadings()
        if let p = pendingFocus {
            if CACurrentMediaTime() > p.until || target?.id != p.session.id { pendingFocus = nil }
            else if !busy, ClaudeBridge.secondsSinceTypingOrClick() >= inputQuiet { pendingFocus = nil; lookedAt(p.session) }
        }
        for intent in gestures.tick(now: CACurrentMediaTime()) { apply(intent) }
        engine.setForceFullRate(needsFullRate)
        overlay.setHandsOnInput(ClaudeBridge.secondsSincePhysicalInput() < 1.2)
        if let send = pendingSend { advanceCountdown(send) }
        if let s = scrollSession, pendingScroll != 0 {
            scrollRemaining += pendingScroll
            scrollVelocity = 0.7 * scrollVelocity + 0.3 * (pendingScroll * 20)     // the tick runs at 20 Hz
            let frame = sessions.first { $0.id == s.session.id }?.frame ?? s.session.frame
            scrollTarget = CGPoint(x: frame.midX, y: frame.midY)
            pendingScroll = 0
            startScrollLoop()
        }
        if let s = scrollSession, Date().timeIntervalSince(s.lastAt) > 0.6 { scrollSession = nil }
        let now = CACurrentMediaTime()
        if now - lastAwayCheck >= 0.5 {
            lastAwayCheck = now
            if listeningSession != nil ? !busy : (scrollTimer != nil || pendingSend != nil), ScreenFacts.sessionAway() { interrupt("screen locked") }
        }
        // With the hand free while dictating, other signals end it: you take the keyboard or mouse, or you leave.
        if listeningSession != nil, !busy, now - listeningSince > 1.5 {
            if ClaudeBridge.secondsSinceTypingOrClick() < 0.3 { refuse("Typing or a click; dictation stopped"); endTalk(reason: "input"); return }
            if now - lastOneFaceT > 10 { refuse("No face for 10 seconds; dictation stopped"); endTalk(reason: "away"); return }
        }
        if let session = listeningSession, !busy, !audioCheckInFlight, now - lastHoldAudioCheck >= 0.5 {
            lastHoldAudioCheck = now
            audioCheckInFlight = true
            let bridge = self.bridge, device = holdInputDevice
            // CoreAudio can stall for a while when a device is changing; never wait on it from the main thread.
            Task.detached {
                let other = bridge.otherProcessCapturingInput()
                let current = device == nil ? nil : bridge.defaultInputDeviceName()
                await MainActor.run {
                    self.audioCheckInFlight = false
                    guard self.listeningSession?.id == session.id, !self.busy else { return }
                    if let other {
                        self.refuse("\(other) started using a microphone; dictation stopped"); self.endTalk(reason: "other capturer")
                    } else if let device, current != device {
                        self.refuse("The input device changed; dictation stopped"); self.endTalk(reason: "input device changed")
                    }
                }
            }
        }
    }

    /// Every hand frame is needed while dictating, a send is pending, calibrating, or a gesture is in progress.
    private var needsFullRate: Bool {
        listeningSession != nil || pendingSend != nil || busy || sendAfterStop || state.calibrating || calibrationPending
            || scrollSession != nil || inertia != 0 || gestures.pinchHeld || gestures.progress != nil
    }

    /// When head readings stop (camera lost, face tracker stalled) the highlight and dot go away instead of freezing.
    private func dropStaleReadings() {
        guard let head = latestHead, CACurrentMediaTime() - head.t > Self.staleHeadSeconds else { return }
        guard target != nil || dotPoint != nil || candidate != nil || state.nosePoint != nil else { return }
        EnsembleLog.write("head readings stopped; clearing the highlight")
        target = nil; candidate = nil; dotPoint = nil
        updateDot()
        pushOverlay()
    }

    private func refreshSessions() {
        checkPermissions()
        let claudeUp = bridge.claudeIsRunning()
        if listeningSession != nil, !busy, !claudeUp || bridge.claudePID != listeningPID {
            // Claude quit (or restarted) during the dictation: its microphone went with it, so there is nothing left
            // to stop. Leaving the flag set would keep the red marker up and feed the safety heartbeat forever.
            EnsembleLog.write("Claude quit or restarted during dictation; clearing the listening state")
            dropListening()
            refuse("Claude quit; dictation ended")
        }
        guard claudeUp else {
            sessions = []; target = nil; candidate = nil; covered = nil; lastSpoken = nil; cancelScroll(); updateStatus(); return
        }
        // No refresh while dictating: a slow Claude tree walk would otherwise trip the Accessibility stall limit mid-hold.
        guard !refreshInFlight, listeningSession == nil else { return }
        // Nobody in front of the camera for 5 s: the window scan (which also costs Claude's own process) runs
        // every 5 s instead of every second, and immediately when a face comes back.
        let now = CACurrentMediaTime()
        guard now - lastOneFaceT < Self.sessionScanFaceWindow || now - lastSessionScan >= Self.sessionScanIdleInterval else { return }
        lastSessionScan = now
        refreshInFlight = true
        Task { @MainActor in
            defer { self.refreshInFlight = false }
            let found = await self.bridge.refreshSessions()
            if found.map(\.id) != self.sessions.map(\.id) { EnsembleLog.write("Claude sessions found: \(found.count) (named \(found.filter { $0.title != nil }.count)) \(found.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" })") }
            self.sessions = found
            self.updateStatus()
        }
    }

    // MARK: - Intents and guards

    private func apply(_ intent: GestureIntent) {
        switch intent {
        case .scroll, .dragScroll: break
        default: EnsembleLog.write("gesture: \(intent)")
        }
        if intent == .talkBegan || intent == .sendRequested { overlay.clearBanner() }
        switch intent {
        case .talkBegan: beginTalk()
        case .talkEnded(let reason): if listeningSession != nil { endTalk(reason: reason.rawValue) }
        case .sendRequested:
            if listeningSession != nil || busy { sendAfterStop = true; EnsembleLog.write("send after stop") } else { requestSend() }
        case .cancelRequested: if pendingSend != nil { EnsembleLog.write("send cancelled by open hand"); pendingSend = nil; state.countdown = nil; Notifier.shared.playCue(.refused); pushOverlay() }
        case .scroll(let dy): scroll(dy)
        case .dragScrollEnded:
            // The pinch is gone. A slow release stops dead; a fast flick throws the page with momentum.
            let now = CACurrentMediaTime()
            recentScroll.removeAll { now - $0.t > 0.12 }
            let v = recentScroll.reduce(0) { $0 + $1.dy } / 0.12
            recentScroll.removeAll()
            pendingScroll = 0; scrollRemaining = 0; scrollVelocity = 0
            if abs(v) >= flickThreshold, scrollTarget != nil {
                inertia = max(-15000, min(15000, v))
                EnsembleLog.write("flick: \(Int(inertia)) pt/s")
                startScrollLoop()
            } else {
                inertia = 0
                scrollTimer?.invalidate(); scrollTimer = nil
            }
            scrollSession = nil
        case .dragScroll(let rawHandDy):
            inertia = 0                                         // a new drag catches the page
            let handDy = rawHandDy > 0 ? rawHandDy * upStrokeGain : rawHandDy
            // Natural scrolling: the content follows the hand, so a hand moving up shows later content (scrolls down).
            scroll(handDy * SystemPointer.speedFactor * (SystemPointer.naturalScrolling ? 1 : -1) * (settings.reverseScroll ? -1 : 1))
        }
    }

    /// Shared guards for every gesture that acts on Claude. Returns a refusal reason, or nil when allowed.
    private func commonRefusal() -> String? {
        if !settings.enabled { return "Ensemble is off" }
        if cover.covered { return "Camera is covered" }
        if ScreenFacts.sessionAway() { return "The screen is locked" }
        // The hand often covers the face as it rises: one face within the last 1.5 s counts. Two faces block only
        // when they persist: a stray two-face reading is a false alarm.
        let now = CACurrentMediaTime()
        if now - lastOneFaceT > 1.5 { return "No face in view" }
        if ClaudeBridge.secondsSinceTypingOrClick() < inputQuiet { return "You just typed or clicked" }
        return nil
    }

    /// The machine already flipped to talking when it announced the start; a refusal must flip it back,
    /// or the next double tap would be read as a stop.
    private func refuseStart(_ why: String) {
        gestures.abortTalk()
        refuse(why, title: "Dictation not started")
    }

    private func beginTalk() {
        guard listeningSession == nil, !busy, !disarming else {
            if listeningSession == nil || busy { gestures.abortTalk() }
            return
        }
        if let why = commonRefusal() { refuseStart(why); return }
        guard calibratedHere else { refuseStart("Calibrate first (or recalibrate for this screen arrangement)"); return }
        guard let session = target else { refuseStart("Your nose is not on a Claude session"); return }
        if let other = bridge.otherProcessCapturingInput() { refuseStart("\(other) is using a microphone"); return }
        pendingSend = nil; state.countdown = nil
        sendAfterStop = false; focusAfterStop = nil; pendingFocus = nil
        guard safety.episodeStarting(session: session) else { refuseStart("Could not write the safety record; not starting"); return }
        busy = true
        listeningSession = session
        listeningPID = bridge.claudePID
        state.listening = true
        pushOverlay()
        Task { @MainActor in
            let result = await self.bridge.startDictation(session)
            self.busy = false
            switch result {
            case .done:
                EnsembleLog.write("dictation started")
                if self.settings.liveSoundBars { self.meter.start() }
                self.listeningSince = CACurrentMediaTime()
                self.holdInputDevice = self.bridge.defaultInputDeviceName()
                self.safety.episodeConfirmed()
                Notifier.shared.playCue(.listenStart)
            case .refused(let why), .unknown(let why):
                self.listeningSession = nil
                self.state.listening = false
                self.safety.episodeEnded()
                self.gestures.abortTalk()
                EnsembleLog.write("start dictation \(result): \(self.bridge.micSnapshot)")
                self.refuse("Could not start dictation: \(why)", title: "Dictation not started")
                self.checkClaudeUpdate()
            }
            // The hand may already have opened while the press was in flight.
            if !self.gestures.talking, self.listeningSession != nil { self.endTalk(reason: "released") }
            self.pushOverlay()
        }
    }

    private func endTalk(reason: String, immediate: Bool = false) {
        guard let session = listeningSession, !busy else { return }
        busy = true
        Task { @MainActor in
            if !immediate { try? await Task.sleep(nanoseconds: UInt64(self.stopTail * 1e9)) }
            let result = await self.bridge.stopDictation(session)
            self.busy = false
            self.listeningSession = nil
            self.state.listening = false
            self.meter.stop()
            self.safety.episodeEnded()
            if self.gestures.talking { self.gestures.reset() }
            if case .done = result {} else { self.sendAfterStop = false; self.focusAfterStop = nil }
            switch result {
            case .done:
                EnsembleLog.write("dictation stopped")
                if let next = self.focusAfterStop {
                    self.focusAfterStop = nil
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        // Typing or a new dictation during the pause means the user is working here: do not move focus.
                        guard self.listeningSession == nil, !self.busy, ClaudeBridge.secondsSinceTypingOrClick() >= self.inputQuiet else { return }
                        _ = await self.bridge.focus(next, unlessTypedWithin: self.inputQuiet)
                    }
                }
                self.settings.lastClaudeVersion = self.bridge.claudeVersion
                // An interrupted dictation (sleep, lock, safety stop) is never sent by a later thumbs-up.
                if !immediate { self.lastSpoken = (session, Date()) }
                if !self.sendAfterStop {
                    self.overlay.showBanner(title: "Dictation stopped", body: self.name(of: session), style: .stopped, seconds: 2.5)
                }
                if self.sendAfterStop {
                    self.sendAfterStop = false
                    // Claude finalises the transcript a moment after the mic stops.
                    Task { @MainActor in try? await Task.sleep(nanoseconds: 600_000_000); self.requestSend() }
                }
                Notifier.shared.playCue(.listenEnd)
            case .refused(let why), .unknown(let why):
                EnsembleLog.write("stop dictation \(result): \(self.bridge.micSnapshot)")
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
        if ClaudeBridge.secondsSinceTypingOrClick() < Date().timeIntervalSince(spoken.stoppedAt) { refuse("Typed or clicked since dictation; not sending"); return }
        if let other = bridge.otherProcessCapturingInput() { refuse("\(other) is using a microphone"); return }
        Task { @MainActor in
            guard let text = await self.bridge.draftText(session), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.refuse("The draft is empty"); return
            }
            // The draft read takes a moment; a new dictation, countdown or keystroke may have started meanwhile.
            guard self.pendingSend == nil, self.listeningSession == nil, !self.busy else { self.refuse("Send dropped: something else started"); return }
            if ClaudeBridge.secondsSinceTypingOrClick() < Date().timeIntervalSince(spoken.stoppedAt) { self.refuse("Typed or clicked since dictation; not sending"); return }
            EnsembleLog.write("sending (\(text.count) characters)")
            self.sendNow(session, shown: text)
        }
    }

    private func sendNow(_ session: ClaudeSession, shown: String) {
        busy = true
        Task { @MainActor in
            let result = await self.bridge.sendDraft(session, shown: shown)
            self.busy = false
            switch result {
            case .done:
                EnsembleLog.write("sent"); self.lastSpoken = nil; Notifier.shared.playCue(.send)
                self.overlay.showBanner(title: "Sent", body: self.name(of: session), style: .sent, seconds: 1.5)
            case .refused(let why): self.refuse("Not sent: \(why)")
            case .unknown(let why):
                // Send was pressed but not confirmed: a second thumbs-up must not press it again.
                self.lastSpoken = nil
                self.refuse("Not sent: \(why)")
            }
        }
    }

    /// The session's name as Claude shows it now, for the island.
    private func name(of session: ClaudeSession) -> String {
        (sessions.first { $0.id == session.id }?.title ?? session.title) ?? "this session"
    }

    private func advanceCountdown(_ send: (session: ClaudeSession, started: Date, text: String)) {
        let words = Double(send.text.split(separator: " ").count)
        let duration = settings.sendCountdownSeconds + words * 0.03
        let elapsed = Date().timeIntervalSince(send.started)
        // Cancel on any keyboard or mouse use, or when the nose leaves the session.
        if ClaudeBridge.secondsSinceTypingOrClick() < elapsed || cover.covered {
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
            let result = await self.bridge.sendDraft(send.session, shown: send.text)
            self.busy = false
            switch result {
            case .done: EnsembleLog.write("sent"); self.lastSpoken = nil; Notifier.shared.playCue(.send)
            case .refused(let why): self.refuse("Not sent: \(why)")
            case .unknown(let why): self.lastSpoken = nil; self.refuse("Not sent: \(why)")
            }
        }
    }

    private func scroll(_ dy: Double) {
        guard dy.isFinite, pendingSend == nil, commonRefusal() == nil else { return }
        let session: ClaudeSession
        if let s = scrollSession { session = s.session } else if let t = listeningSession ?? target { session = t } else { return }
        if scrollSession == nil { EnsembleLog.write("scroll started") }
        scrollSession = (session, Date())
        pendingScroll += dy           // flushed on the tick, so the pointer is touched at most 20 times a second
        recentScroll.append((CACurrentMediaTime(), dy))
    }

    /// The nose settled on a different session. Focus follows it; a dictation running elsewhere stops first,
    /// keeping its text unsent (switching sessions in Claude while recording would discard it).
    private func lookedAt(_ session: ClaudeSession) {
        // Coming back to the session that already has focus (after the target dropped for a moment) is not a
        // switch: no focus call, no glow.
        if session.id == lastFocusedId, NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.hasPrefix("com.anthropic.claudefordesktop") == true {
            pendingFocus = nil
            return
        }
        guard !busy, ClaudeBridge.secondsSinceTypingOrClick() >= inputQuiet else {
            // The nose has already settled and will not "settle" again, so retry from the tick for a few seconds.
            pendingFocus = (session, CACurrentMediaTime() + 3)
            return
        }
        pendingFocus = nil
        if let listening = listeningSession {
            guard listening.id != session.id else { return }
            focusAfterStop = session
            EnsembleLog.write("looked at another session; dictation stopped and kept")
            endTalk(reason: "looked at another session")
            return
        }
        overlay.flashArrival(session.frame)
        lastFocusedId = session.id
        EnsembleLog.write("focus moved to a session")
        Task {
            if case .refused = await self.bridge.focus(session, unlessTypedWithin: self.inputQuiet) { self.lastFocusedId = nil }
        }
    }

    private func startScrollLoop() {
        guard scrollTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollFrame() }
        }
        RunLoop.main.add(t, forMode: .common)
        scrollTimer = t
    }

    private func scrollFrame() {
        if inertia != 0 {
            // Momentum: stopped by a new pinch, by hands on the keyboard/mouse/trackpad, or when it dies out.
            if gestures.pinchHeld || ClaudeBridge.secondsSincePhysicalInput() < 0.2 || abs(inertia) < 60 { inertia = 0 }
            else { scrollRemaining += inertia / 60; inertia *= inertiaFriction }
        }
        let step = scrollRemaining * scrollEase
        guard abs(scrollRemaining) >= 0.5 || inertia != 0, let at = scrollTarget else {
            scrollRemaining = 0
            scrollTimer?.invalidate(); scrollTimer = nil
            return
        }
        // Every 0.15 s: the window under the scroll point must still be Claude's, or the page would scroll
        // whatever another app has put there since the pinch began.
        let now = CACurrentMediaTime()
        if now - lastScrollOwnerCheck >= 0.15 {
            lastScrollOwnerCheck = now
            if ScreenFacts.topWindowOwner(at: at) != bridge.claudePID {
                EnsembleLog.write("scroll stopped: Claude is no longer the window under the scroll point")
                cancelScroll()
                return
            }
        }
        // Whole pixels only; the fraction stays in `scrollRemaining` so nothing is lost.
        let px = step.rounded() != 0 ? step.rounded() : (step > 0 ? 1 : -1)
        scrollRemaining -= px
        ClaudeBridge.postScroll(at: at, dy: px)
    }

    /// Drops every piece of scrolling state, so nothing glides or coasts after this call.
    private func cancelScroll() {
        scrollTimer?.invalidate(); scrollTimer = nil
        scrollSession = nil
        pendingScroll = 0; scrollRemaining = 0; scrollVelocity = 0; inertia = 0
        scrollTarget = nil
        recentScroll.removeAll()
    }

    /// The Mac is going to sleep, the screen locked, or the safety check ended the hold: stop dictation now (no
    /// tail wait), and forget anything that was about to act. The text stays; nothing is sent.
    private func interrupt(_ reason: String) {
        EnsembleLog.write("interrupt: \(reason)")
        pendingSend = nil; state.countdown = nil
        sendAfterStop = false; focusAfterStop = nil; pendingFocus = nil
        lastSpoken = nil
        cancelScroll()
        gestures.reset()
        guard listeningSession != nil else { pushOverlay(); return }
        if busy {
            endTalkWhenIdle(reason: reason, immediate: true)
        } else {
            endTalk(reason: reason, immediate: true)
        }
    }

    /// Local teardown for a dictation whose Claude process is gone; there is no microphone to press.
    private func dropListening() {
        listeningSession = nil
        listeningPID = nil
        state.listening = false
        meter.stop()
        safety.episodeEnded()
        sendAfterStop = false; focusAfterStop = nil
        gestures.reset()
        pushOverlay()
    }

    // MARK: - Dot placement

    /// What the dot shows. While dictating: hidden, except near the session's edges (where you may be looking
    /// away). While a gesture is being held: frozen in place as the gesture bubble. Otherwise: the dot follows
    /// the nose whenever it is over a Claude session and the dot setting is on.
    private func updateDot() {
        if let session = listeningSession {
            frozenPoint = nil
            if let d = lastNose {
                let inner = session.frame.insetBy(dx: session.frame.width * 0.15, dy: session.frame.height * 0.15)
                state.set(\.nosePoint, inner.contains(d) ? nil : d)
            } else {
                state.set(\.nosePoint, nil)
            }
        } else if gestureShowing {
            if frozenPoint == nil { frozenPoint = dotPoint }
            state.set(\.nosePoint, frozenPoint)
        } else {
            frozenPoint = nil
            state.set(\.nosePoint, settings.showNoseDot ? dotPoint : nil)
        }
        state.set(\.targetFrame, listeningSession?.frame ?? target?.frame)
    }

    // MARK: - Screen and version checks

    /// The calibration is usable only on the screen arrangement it was made on.
    private var calibratedHere: Bool {
        guard pointer.isCalibrated else { return false }
        // Read on every camera frame; the screen arrangement only changes in screensChanged, so cache briefly.
        let now = CACurrentMediaTime()
        if let c = calibratedCache, now - c.at < 1 { return c.value }
        let value = settings.calibrationDisplays == ScreenFacts.displayFingerprint()
        calibratedCache = (value, now)
        return value
    }

    private var claudeRunning: Bool {
        let now = CACurrentMediaTime()
        if let c = claudeRunningCache, now - c.at < 1 { return c.value }
        let value = bridge.claudeIsRunning()
        claudeRunningCache = (value, now)
        return value
    }

    private func claudeInFront(at p: CGPoint, t: TimeInterval) -> Bool {
        if let c = topOwner, t - c.t < 0.15, hypot(c.at.x - p.x, c.at.y - p.y) < 40 { return c.pid == bridge.claudePID }
        let pid = ScreenFacts.topWindowOwner(at: p)
        topOwner = (p, t, pid)
        return pid != nil && pid == bridge.claudePID
    }

    private func screensChanged() {
        calibratedCache = nil
        EnsembleLog.write("screens changed; calibration valid here: \(calibratedHere)")
        if listeningSession != nil { endTalk(reason: "screens changed") }
        if state.calibrating { CalibrationController.shared.cancel() }
        cancelScroll()
        pendingSend = nil
        target = nil
        updateStatus()
    }

    /// A failure right after Claude updated may mean its controls changed: switch off and say why.
    private func checkClaudeUpdate() {
        guard let now = bridge.claudeVersion, let last = settings.lastClaudeVersion, now != last else { return }
        EnsembleLog.write("Claude updated \(last) -> \(now) and a dictation step failed; switching off")
        Notifier.shared.notify(title: "Ensemble switched off", body: "Claude updated to \(now) and its microphone controls did not respond as before.")
        settings.enabled = false
    }

    // MARK: - Output

    private func sweep() {
        Task { await self.safety.launchSweep() }
    }

    private func refuse(_ why: String, title: String? = nil) {
        state.lastRefusal = why
        if gestureShowing || pendingSend != nil || why.hasPrefix("Send") || why.hasPrefix("Not sent") {
            let sendRelated = why.hasPrefix("Send") || why.hasPrefix("Not sent")
            let body = why.hasPrefix("Not sent: ") ? String(why.dropFirst("Not sent: ".count)) : why
            overlay.showBanner(title: title ?? (sendRelated ? "Not sent" : "Nothing done"), body: body.prefix(1).uppercased() + body.dropFirst(), style: .refused, seconds: 2.5)
        }
        EnsembleLog.write("refused: \(why)")
    }

    private func updateStatus() {
        state.set(\.status, currentStatus())
    }

    private func currentStatus() -> AppStatus {
        if !settings.enabled || !running { return .off }
        if !accessibilityTrusted { return .needsPermission("Accessibility") }
        if !cameraAllowed { return .needsPermission("Camera") }
        if let problem = cameraProblem { return .error(problem) }
        if let failure = trackerFailure { return .error("Face tracking stopped: \(failure)") }
        if cover.covered { return .cameraCovered }
        if !calibratedHere { return .needsCalibration }
        if !claudeRunning { return .claudeNotRunning }
        return state.listening ? .listening : .watching
    }

    /// Re-reads both permissions every second. A grant that arrives while Ensemble runs clears the status and
    /// restarts the camera; a camera that stopped for another reason is retried every 5 s.
    private func checkPermissions() {
        guard running else { return }
        let trusted = Permissions.accessibilityTrusted && !bridge.accessibilityDisabled
        if trusted != accessibilityTrusted { EnsembleLog.write("accessibility permission is now \(trusted ? "granted" : "missing")") }
        accessibilityTrusted = trusted
        let allowed = Permissions.cameraAllowed
        let flippedOn = allowed && !cameraAllowed
        if allowed != cameraAllowed { EnsembleLog.write("camera permission is now \(allowed ? "granted" : "denied")") }
        cameraAllowed = allowed
        if flippedOn {
            restartCamera("camera permission granted")
        } else if allowed, !engine.isRunning, Date().timeIntervalSince(lastCameraRestart) >= 5 {
            restartCamera("the camera was not running")
        }
        updateStatus()
    }

    private func restartCamera(_ why: String) {
        EnsembleLog.write("camera restart: \(why)")
        lastCameraRestart = Date()
        cameraProblem = nil; trackerFailure = nil; trackerReady = false
        latestHead = nil
        engine.start(cameraName: settings.cameraName)
    }

    private func pushOverlay() {
        // Every dictation start and end passes through here: fade other audio out for its length, back in after.
        let wantDuck = listeningSession != nil && settings.pauseMediaWhileDictating
        if wantDuck != duckWanted { duckWanted = wantDuck; if wantDuck { ducker.duck() } else { ducker.restore() } }
        let acting = listeningSession ?? (gestures.progress?.action == .send ? lastSpoken?.session : nil) ?? target
        var switching: SessionSwitch?
        if listeningSession != nil {
            if let next = focusAfterStop {
                switching = SessionSwitch(name: name(of: next), progress: 1)
            } else if let c = candidate, let to = c.session, to.id != listeningSession?.id, let now = latestHead?.t {
                switching = SessionSwitch(name: name(of: to), progress: min(max((now - c.since) / listeningSwitchDwell, 0), 1))
            }
        }
        overlay.setSession(name: acting.map(name(of:)), switching: switching)
        overlay.update(target: state.targetFrame, nose: state.nosePoint, listening: state.listening,
                       countdown: state.countdown, showNoseDot: settings.showNoseDot, showHighlight: settings.showHighlight)
        updateStatus()
    }
}
