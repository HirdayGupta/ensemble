import AppKit
import Combine
import EnsembleCore

/// Starts and stops Claude's dictation and keeps it safe while it runs: pauses other audio, watches for typing,
/// leaving, another microphone user or a changed input device, and records each episode for the safety check.
@MainActor
final class DictationController {
    private let ctx: CoordinatorContext
    private let focus: FocusController
    private let send: SendController
    private let safety: DictationSafety
    private let meter = AudioLevelMeter()
    /// Fades out and pauses other audio on speakers while dictating, so it is not transcribed.
    private let ducker = MediaDucker()
    private var duckWanted = false
    private var disarming = false            // "Clear and disarm" is stopping the microphone
    /// A start press is between the press request and its result; it could still turn the microphone on.
    private var startInFlight = false
    /// Switching off gave up waiting for a start press: stop that dictation the moment the press lands.
    private var stopWhenStarted = false
    private var cancellables = Set<AnyCancellable>()
    /// Claude's process when the dictation began: a different (or missing) one later means the dictation is gone.
    private var processID: pid_t?
    private var startedAt: TimeInterval = 0
    /// Input device at the start of the dictation; a change mid-dictation stops it.
    private var inputDevice: String?
    private var lastAudioCheck: TimeInterval = 0
    private var audioCheckInFlight = false
    /// Wait this long after the hand opens before stopping, so the last word is caught.
    private static let stopTail = 0.4

    /// Ends everything that was about to act and stops the dictation (wired by the Coordinator).
    var interrupt: (String) -> Void = { _ in }
    /// Every stop's outcome, by any route: true when the microphone was confirmed off (wired by the Coordinator).
    var stopResolved: (Bool) -> Void = { _ in }

    init(ctx: CoordinatorContext, focus: FocusController, send: SendController) {
        self.ctx = ctx
        self.focus = focus
        self.send = send
        safety = DictationSafety(bridge: ctx.bridge)
        meter.onLevel = { [weak self] v in
            guard let self else { return }
            self.ctx.overlay.setAudioLevel(v)
            if self.meter.isRunning { self.ctx.speech.note(level: v, at: CACurrentMediaTime()) } else { self.ctx.speech.meterStopped() }
        }
        ctx.overlay.setLiveSoundBars(ctx.settings.liveSoundBars)
        ctx.settings.$liveSoundBars.dropFirst().sink { [weak self] on in
            guard let self else { return }
            self.ctx.overlay.setLiveSoundBars(on)
            if !on { self.meter.stop() } else if self.ctx.listening != nil { self.meter.start() }
        }.store(in: &cancellables)
        safety.onAlarm = { [weak self] msg in
            self?.ctx.refuse("Alarm: \(msg)")
            Notifier.shared.alarm(title: "Claude's microphone may still be on", body: msg)
        }
        safety.onMuted = { [weak self] muted in
            self?.ctx.state.muted = muted
            if !muted { Notifier.shared.resolveAlarm() }   // the mute is undone only after a definite "off"
        }
        safety.onHoldEnded = { [weak self] why in
            MainActor.assumeIsolated {
                guard let self, self.ctx.listening != nil else { return }
                self.ctx.refuse("The safety check stopped dictation (\(why))")
                self.interrupt("safety check: \(why)")
            }
        }
    }

    // MARK: - Start and stop

    func begin() {
        guard ctx.listening == nil, !ctx.busy, !disarming else {
            if ctx.listening == nil || ctx.busy { ctx.gestures.abortTalk() }
            return
        }
        if let why = ctx.commonRefusal() { refuseStart(why); return }
        guard ctx.calibratedHere else { refuseStart("Calibrate first (or recalibrate for this screen arrangement)"); return }
        guard let session = focus.target else { refuseStart("Your nose is not on a Claude session"); return }
        if let other = ctx.bridge.otherProcessCapturingInput() { refuseStart("\(other) is using a microphone"); return }
        send.afterStop = false; focus.clearDeferred()
        guard safety.episodeStarting(session: session) else { refuseStart("Could not write the safety record; not starting"); return }
        ctx.busy = true
        startInFlight = true
        ctx.listening = session
        processID = ctx.bridge.claudePID
        ctx.state.listening = true
        ctx.changed()
        Task { @MainActor in
            // Other audio is paused before the microphone opens, so neither it nor the pause is transcribed.
            if self.ctx.settings.pauseMediaWhileDictating { self.duckWanted = true; await self.ducker.duck() }
            let result = await self.ctx.bridge.startDictation(session)
            self.ctx.busy = false
            self.startInFlight = false
            let switchedOff = self.disarming || self.stopWhenStarted
            self.stopWhenStarted = false
            var confirmedOn = false
            if case .done = result { confirmedOn = true }
            // The hand may already have opened, or Ensemble been switched off, while the press was in flight.
            let next = DictationRules.afterStart(confirmedOn: confirmedOn, switchedOff: switchedOff, poseHeld: self.ctx.gestures.talking)
            switch result {
            case .done:
                EnsembleLog.write(next == .stopSwitchedOff ? "dictation started after Ensemble was switched off; stopping it now" : "dictation started")
                if self.ctx.settings.liveSoundBars, next != .stopSwitchedOff { self.meter.start() }
                self.startedAt = CACurrentMediaTime()
                self.inputDevice = self.ctx.bridge.defaultInputDeviceName()
                self.safety.episodeConfirmed()
                if next != .stopSwitchedOff { Notifier.shared.playCue(.listenStart) }
                // Pressing the microphone can leave the keyboard on the button; a key typed while dictating belongs in
                // this session's message box.
                if next == .keepListening {
                    Task { @MainActor in EnsembleLog.write(await self.ctx.bridge.focusComposerIfNeeded(session)) }
                }
            case .refused(let why), .unknown(let why):
                self.ctx.listening = nil
                self.ctx.state.listening = false
                self.safety.episodeEnded()
                self.ctx.gestures.abortTalk()
                EnsembleLog.write("start dictation \(result): \(self.ctx.bridge.micSnapshot)")
                self.ctx.refuse("Could not start dictation: \(why)", title: "Dictation not started")
                self.checkClaudeUpdate()
            }
            switch next {
            // The record stays until the stop is confirmed and capture has been off for the settle window.
            case .stopSwitchedOff: self.end(reason: "switched off while starting", immediate: true)
            case .stopReleased: self.end(reason: "released")
            case .keepListening, .notStarted: break
            }
            self.ctx.changed()
        }
    }

    func end(reason: String, immediate: Bool = false) {
        guard let session = ctx.listening, !ctx.busy else { return }
        ctx.busy = true
        Task { @MainActor in
            if !immediate { try? await Task.sleep(nanoseconds: UInt64(Self.stopTail * 1e9)) }
            let result = await self.ctx.bridge.stopDictation(session)
            self.ctx.busy = false
            self.ctx.listening = nil
            self.ctx.state.listening = false
            self.meter.stop()
            self.safety.episodeEnded()
            if self.ctx.gestures.talking { self.ctx.gestures.reset() }
            let sendByReturn = self.send.afterStopByReturn
            if case .done = result {} else { self.send.afterStop = false; self.focus.clearAfterStop() }
            switch result {
            case .done:
                EnsembleLog.write("dictation stopped")
                if let next = self.focus.afterStop {
                    self.focus.clearAfterStop()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        // Typing or a new dictation during the pause means the user is working here: do not move focus.
                        guard self.ctx.listening == nil, !self.ctx.busy, !self.focus.userLeftClaude, ClaudeBridge.secondsSinceTypingOrClick() >= CoordinatorContext.inputQuiet else { return }
                        _ = await self.ctx.bridge.focus(next, unlessTypedWithin: CoordinatorContext.inputQuiet)
                    }
                }
                self.ctx.settings.lastClaudeVersion = self.ctx.bridge.claudeVersion
                // An interrupted dictation (sleep, lock, safety stop) is never sent by a later thumbs-up.
                if !immediate { self.send.spoke(in: session) }
                if !self.send.afterStop {
                    self.ctx.overlay.showBanner(title: "Dictation stopped", body: self.ctx.name(of: session), style: .stopped, seconds: 2.5)
                }
                if self.send.afterStop {
                    self.send.afterStop = false
                    // Claude finalises the transcript a moment after the mic stops.
                    Task { @MainActor in try? await Task.sleep(nanoseconds: 600_000_000); self.send.request(byReturn: sendByReturn) }
                }
                Notifier.shared.playCue(.listenEnd)
                self.stopResolved(true)
            case .refused(let why), .unknown(let why):
                EnsembleLog.write("stop dictation \(result): \(self.ctx.bridge.micSnapshot)")
                self.ctx.refuse("Stop not confirmed (\(why)); the safety check keeps watching")
                self.stopResolved(false)
                self.checkClaudeUpdate()
            }
            self.ctx.changed()
        }
    }

    func endWhenIdle(reason: String, immediate: Bool = false) {
        Task { @MainActor in
            for _ in 0..<30 where self.ctx.busy { try? await Task.sleep(nanoseconds: 100_000_000) }
            if self.ctx.listening != nil { self.end(reason: reason, immediate: immediate) }
        }
    }

    /// The machine already flipped to talking when it announced the start; a refusal must flip it back,
    /// or the next double tap would be read as a stop.
    private func refuseStart(_ why: String) {
        ctx.gestures.abortTalk()
        ctx.refuse(why, title: "Dictation not started")
    }

    // MARK: - While it runs

    /// A fresh camera frame arrived: the engine is alive.
    func heartbeat() {
        if ctx.listening != nil { safety.heartbeat() }
    }

    /// From the 20 Hz tick. With the hand free while dictating, other signals end it: you take the keyboard or
    /// mouse, you leave, another app opens a microphone, or the input device changes.
    func supervise(now: TimeInterval) {
        if ctx.listening != nil, !ctx.busy, now - startedAt > 1.5 {
            if ClaudeBridge.secondsSinceTypingOrClick() < 0.3 { ctx.refuse("Typing or a click; dictation stopped"); end(reason: "input"); return }
            if now - ctx.lastOneFaceT > 10 { ctx.refuse("No face for 10 seconds; dictation stopped"); end(reason: "away"); return }
        }
        if let session = ctx.listening, !ctx.busy, !audioCheckInFlight, now - lastAudioCheck >= 0.5 {
            lastAudioCheck = now
            audioCheckInFlight = true
            let bridge = ctx.bridge, device = inputDevice
            // CoreAudio can stall for a while when a device is changing; never wait on it from the main thread.
            Task.detached {
                let other = bridge.otherProcessCapturingInput()
                let current = device == nil ? nil : bridge.defaultInputDeviceName()
                await MainActor.run {
                    self.audioCheckInFlight = false
                    guard self.ctx.listening?.id == session.id, !self.ctx.busy else { return }
                    if let other {
                        self.ctx.refuse("\(other) started using a microphone; dictation stopped"); self.end(reason: "other capturer")
                    } else if let device, current != device {
                        self.ctx.refuse("The input device changed; dictation stopped"); self.end(reason: "input device changed")
                    }
                }
            }
        }
    }

    /// Claude quit (or restarted) during the dictation: its microphone went with it, so there is nothing left
    /// to stop. Leaving the flag set would keep the red marker up and feed the safety heartbeat forever.
    func dropIfClaudeGone(running claudeUp: Bool) {
        guard ctx.listening != nil, !ctx.busy, !claudeUp || ctx.bridge.claudePID != processID else { return }
        EnsembleLog.write("Claude quit or restarted during dictation; clearing the listening state")
        drop()
        ctx.refuse("Claude quit; dictation ended")
    }

    /// Local teardown for a dictation whose Claude process is gone; there is no microphone to press.
    private func drop() {
        ctx.listening = nil
        processID = nil
        ctx.state.listening = false
        meter.stop()
        safety.episodeEnded()
        send.afterStop = false; focus.clearAfterStop()
        ctx.gestures.reset()
        stopResolved(false)
        ctx.changed()
    }

    /// Every dictation end passes through the overlay refresh: audio paused for it resumes.
    func restoreAudioIfIdle() {
        if duckWanted, ctx.listening == nil { duckWanted = false; ducker.restore() }
    }

    // MARK: - Leaving

    func sweep() {
        Task { await self.safety.launchSweep() }
    }

    func clearAndDisarm() {
        guard !disarming else { return }
        disarming = true
        send.afterStop = false
        ctx.gestures.reset()
        EnsembleLog.write("clear and disarm requested")
        Task { @MainActor in
            // A start press still in flight could turn the microphone on after the check below reads it off.
            let began = CACurrentMediaTime()
            waiting: while true {
                switch DictationRules.disarmStep(stepInFlight: self.ctx.busy, startInFlight: self.startInFlight, waited: CACurrentMediaTime() - began) {
                case .wait:
                    try? await Task.sleep(nanoseconds: 100_000_000)
                case .proceed:
                    break waiting
                case .stopWhenStarted:
                    // The listening state and the safety record stay with the start; it stops the moment the press lands.
                    self.disarming = false
                    self.stopWhenStarted = true
                    EnsembleLog.write("clear and disarm: a start press is still in flight after \(Int(DictationRules.disarmWait)) s; it is stopped when it lands and the safety record stays")
                    self.ctx.refuse("Could not confirm the microphone is off; the safety check keeps watching")
                    self.ctx.changed()
                    return
                }
            }
            let result = await self.ctx.bridge.stopAnyDictation()
            var capture = self.ctx.bridge.claudeCaptureActive()
            for _ in 0..<15 where !DictationRules.confirmedOff(capture: capture) {
                try? await Task.sleep(nanoseconds: 100_000_000)
                capture = self.ctx.bridge.claudeCaptureActive()
            }
            self.disarming = false
            self.ctx.listening = nil
            self.ctx.state.listening = false
            // An unreadable microphone state is not off: the record and any mute stay for the standing check.
            if !DictationRules.confirmedOff(capture: capture) || !self.safety.clearAndDisarm() {
                EnsembleLog.write("clear and disarm: microphone still recording (stop \(result)); the safety check keeps watching")
                self.safety.episodeEnded()
                self.ctx.refuse("Could not confirm the microphone is off; the safety check keeps watching")
            } else {
                EnsembleLog.write("clear and disarm: microphone confirmed off")
            }
            self.ctx.changed()
        }
    }

    /// Quit path: blocks (at most about two seconds) until Claude's microphone is confirmed off and our mute is undone.
    func shutdown() {
        let session = ctx.listening
        ctx.listening = nil
        ducker.restoreNow()
        safety.stopForTermination(session: session)
    }

    /// A failure right after Claude updated may mean its controls changed: switch off and say why.
    private func checkClaudeUpdate() {
        guard let now = ctx.bridge.claudeVersion, let last = ctx.settings.lastClaudeVersion, now != last else { return }
        EnsembleLog.write("Claude updated \(last) -> \(now) and a dictation step failed; switching off")
        Notifier.shared.notify(title: "Ensemble switched off", body: "Claude updated to \(now) and its microphone controls did not respond as before.")
        ctx.settings.enabled = false
    }
}
