import AppKit
import ClutchCore
import Foundation

/// The rule this class enforces: Claude's microphone is never left recording because of this app.
/// It owns the crash-recovery episode file, a deadman for the hold, a standing check that runs even
/// when nothing is wrong, and the alarm + input-mute fallback for when stopping cannot be confirmed.
final class DictationSafety: @unchecked Sendable {
    private let bridge: ClaudeBridge
    private let queue = DispatchQueue(label: "clutch.dictation-safety", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    private let callbackLock = NSLock()
    private var alarmHandler: ((String) -> Void)?
    private var mutedHandler: ((Bool) -> Void)?

    var onAlarm: ((String) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return alarmHandler }
        set { callbackLock.lock(); alarmHandler = newValue; callbackLock.unlock() }
    }
    var onMuted: ((Bool) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return mutedHandler }
        set { callbackLock.lock(); mutedHandler = newValue; callbackLock.unlock() }
    }

    // Everything below is confined to `queue`.
    private var episode: EpisodeRecord?
    private var session: ClaudeSession?
    private var holdActive = false
    private var lastHeartbeat = Date.distantPast
    private var holdEndedAt = Date.distantPast
    private var offSince: Date?
    private var stopInFlight = false
    private var stopStartedAt: Date?
    private var stopReason = ""
    private var escalated = false
    private var sound: NSSound?
    private var muter = InputMuter()
    private var ticks = 0

    static let heartbeatTimeout: TimeInterval = 1.0
    static let axStallLimit: TimeInterval = 3.0
    static let settleWindow: TimeInterval = 3.0
    static let escalateAfter: TimeInterval = 3.0

    init(bridge: ClaudeBridge) {
        self.bridge = bridge
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    deinit { timer?.cancel() }

    // MARK: Episode lifecycle

    /// Records the episode on disk (fsynced) before anything presses the microphone control.
    /// Returns false if the record could not be written; callers must not press in that case.
    @discardableResult
    func episodeStarting(session: ClaudeSession) -> Bool {
        queue.sync {
            let record = EpisodeRecord(id: UUID().uuidString, startedAt: Date(), pid: ProcessInfo.processInfo.processIdentifier,
                                       bootSessionUUID: SafetyFiles.bootSessionUUID(), sessionID: session.id,
                                       claudeVersion: bridge.claudeVersion)
            do { try SafetyFiles.writeEpisode(record) } catch { return false }
            episode = record
            self.session = session
            holdActive = true
            lastHeartbeat = Date()
            offSince = nil
            stopStartedAt = nil
            escalated = false
            return true
        }
    }

    func episodeConfirmed() {
        queue.async { self.lastHeartbeat = Date() }
    }

    /// Call on every fresh frame in which the talk pose is held.
    func heartbeat() {
        let now = Date()
        queue.async { if self.holdActive { self.lastHeartbeat = now } }
    }

    /// The hold is over. The episode file stays until capture has been off for the settle window.
    func episodeEnded() {
        queue.async {
            self.holdActive = false
            self.holdEndedAt = Date()
            self.offSince = nil
        }
    }

    /// Forget everything: delete the episode file, undo our mute, silence the alarm. Refuses (returns false)
    /// while Claude is still capturing: the episode stays and the standing check keeps trying to stop it.
    @discardableResult
    func clearAndDisarm() -> Bool {
        queue.sync {
            holdActive = false
            if bridge.claudeCaptureActive() == true {
                holdEndedAt = Date()
                offSince = nil
                return false
            }
            stopInFlight = false
            stopStartedAt = nil
            escalated = false
            episode = nil
            session = nil
            SafetyFiles.deleteEpisode()
            stopAlarm()
            restoreMute()
            return true
        }
    }

    /// Quit path: stops Claude's dictation and undoes our mute before the process exits. The caller blocks for at
    /// most `timeout` seconds. If the stop cannot be confirmed, the input is muted and the episode file is left
    /// for the next launch's sweep, which restores the mute once capture is off.
    func stopForTermination(session: ClaudeSession?, timeout: TimeInterval = 2) {
        timer?.cancel()
        bridge.beginShutdown()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            self.terminationStop(session: session, deadline: Date().addingTimeInterval(timeout))
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeout + 0.5) == .timedOut {
            ClutchLog.write("quit: the microphone stop did not finish within \(timeout) s")
        }
    }

    private func terminationStop(session: ClaudeSession?, deadline: Date) {
        let (episodeOpen, remembered) = queue.sync { (episode != nil || holdActive || stopStartedAt != nil, self.session) }
        guard session != nil || episodeOpen || SafetyFiles.episodeFileExists() else {
            queue.sync { restoreMute() }
            return
        }
        var off = bridge.claudeCaptureActive() == false
        if !off {
            let left = deadline.timeIntervalSinceNow
            let result = left > 0.1 ? bridge.stopDictationBlocking(session ?? remembered, timeout: left) : nil
            var capture = bridge.claudeCaptureActive()
            while capture == true, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.075)
                capture = bridge.claudeCaptureActive()
            }
            if case .done? = result { off = capture != true } else { off = capture == false }
        }
        ClutchLog.write("quit: microphone \(off ? "confirmed off" : "NOT confirmed off; muting the input")")
        queue.sync {
            if off {
                holdActive = false
                stopStartedAt = nil
                episode = nil
                self.session = nil
                SafetyFiles.deleteEpisode()
                stopAlarm()
                restoreMute()
            } else {
                _ = muter.apply()
            }
        }
    }

    // MARK: Timer

    private func tick() {
        ticks += 1
        let now = Date()
        if holdActive {
            if now.timeIntervalSince(lastHeartbeat) > Self.heartbeatTimeout {
                endHoldAndStop("no talk-pose heartbeat for 1 s")
            } else if bridge.longestAXCallSeconds > Self.axStallLimit {
                endHoldAndStop("an Accessibility call stalled for more than 3 s")
            }
        }
        if stopStartedAt != nil { driveStop(now) }
        if ticks % 4 == 0 { standingCheck(now) }
    }

    private func endHoldAndStop(_ reason: String) {
        holdActive = false
        holdEndedAt = Date()
        beginStop(reason)
    }

    /// Runs once a second: an episode on disk, Claude capturing, and no hold active means a stop is owed.
    private func standingCheck(_ now: Date) {
        guard episode != nil, !holdActive, now.timeIntervalSince(holdEndedAt) > 1.0 else { return }
        switch bridge.claudeCaptureActive() {
        case .some(true):
            offSince = nil
            if stopStartedAt == nil { beginStop("Claude is capturing audio with no hold active") }
        case .some(false):
            if stopStartedAt != nil { stopConfirmed() }
            if offSince == nil { offSince = now }
            if now.timeIntervalSince(offSince!) >= Self.settleWindow { finishEpisode() }
        case .none:
            offSince = nil
        }
    }

    // MARK: Stopping

    private func beginStop(_ reason: String) {
        if stopStartedAt == nil {
            stopStartedAt = Date()
            stopReason = reason
        }
        driveStop(Date())
    }

    /// One stop attempt at a time; retried every tick until capture is confirmed off.
    private func driveStop(_ now: Date) {
        if bridge.claudeCaptureActive() == false {
            stopConfirmed()
            return
        }
        if let started = stopStartedAt, !escalated, now.timeIntervalSince(started) >= Self.escalateAfter {
            escalate("Claude's microphone could not be confirmed off (\(stopReason))")
        }
        guard !stopInFlight else { return }
        stopInFlight = true
        let target = session
        Task { [weak self] in
            guard let self else { return }
            if let target { _ = await self.bridge.stopDictation(target) } else { _ = await self.bridge.stopAnyDictation() }
            self.queue.async { self.stopInFlight = false }
        }
    }

    private func stopConfirmed() {
        stopStartedAt = nil
        stopInFlight = false
        escalated = false
        stopAlarm()
        restoreMute()
    }

    private func finishEpisode() {
        episode = nil
        session = nil
        offSince = nil
        SafetyFiles.deleteEpisode()
        restoreMute()
    }

    // MARK: Alarm and mute

    private func escalate(_ message: String) {
        escalated = true
        startAlarm()
        if muter.apply() { notifyMuted(true) }
        let handler = onAlarm
        DispatchQueue.main.async { handler?(message) }
    }

    private func startAlarm() {
        DispatchQueue.main.async {
            if self.sound == nil { self.sound = NSSound(named: "Sosumi") ?? NSSound(named: "Basso") }
            self.sound?.loops = true
            self.sound?.play()
        }
    }

    private func stopAlarm() {
        DispatchQueue.main.async {
            self.sound?.stop()
            self.sound = nil
        }
    }

    private func restoreMute() {
        guard muter.isActive || !SafetyFiles.readMutes().isEmpty else { return }
        muter = InputMuter()
        if muter.restore() { notifyMuted(false) }
    }

    private func notifyMuted(_ muted: Bool) {
        let handler = onMuted
        DispatchQueue.main.async { handler?(muted) }
    }

    // MARK: Launch and wake

    /// Run at launch and after wake. Acts only on evidence this app left behind: an episode file from the
    /// current boot while Claude is capturing means a recording of ours may still be running.
    func launchSweep() async {
        let hadLiveEpisode: Bool = queue.sync {
            guard let record = SafetyFiles.readEpisode() else { return false }
            if record.bootSessionUUID != SafetyFiles.bootSessionUUID() {
                SafetyFiles.deleteEpisode()
                return false
            }
            if episode == nil {
                episode = record
                session = nil
                holdActive = false
                holdEndedAt = .distantPast
            }
            return true
        }

        guard hadLiveEpisode else {
            queue.sync { if !holdActive { restoreMute() } }
            return
        }

        switch bridge.claudeCaptureActive() {
        case .some(false):
            queue.sync { finishEpisode() }
        case .some(true):
            queue.sync { if stopStartedAt == nil { beginStop("recording found at launch from a previous run") } }
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if queue.sync(execute: { episode == nil || escalated }) { break }
            }
        case .none:
            break
        }
    }

    // MARK: Test hooks

    var debugState: String {
        queue.sync {
            "episode=\(episode?.id ?? "none") hold=\(holdActive) stopping=\(stopStartedAt != nil) escalated=\(escalated) muteActive=\(muter.isActive)"
        }
    }
}
