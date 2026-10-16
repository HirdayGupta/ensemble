import AppKit
import CoreAudio
import EnsembleCore
import MediaPlayer

/// Headphone stem presses. macOS has no "headphone tapped" event: AirPods send a single press as play/pause and a
/// double press as next track, as media remote commands, and only to the app macOS treats as Now Playing.
///
/// Becoming Now Playing took no audio at all. Measured on macOS 26.4 (2026-10-14) with a throwaway probe that
/// posted the real play/pause and next-track keys: commands arrived once command handlers were registered AND
/// the Now Playing info was set AND the playback state was `.playing`. Handlers alone, or info with `.paused`,
/// received nothing. A silent AVAudioEngine added nothing, so none is used: Ensemble plays no sound, opens no
/// input and asks for no permission.
///
/// The claim is held only while it cannot get in the way: the setting is on, the default output is Bluetooth,
/// Claude is running and no other app is playing audio. If music starts, the claim is dropped at once and the
/// presses belong to the music again.
@MainActor
final class HeadphoneRemote {
    /// When Ensemble last posted a play/pause key itself (MediaDucker). The system may hand that key back to us
    /// as a remote command; commands inside `HeadphoneInputFilter.selfKeyWindow` after it are dropped.
    static var lastSyntheticKeyAt: TimeInterval = -.infinity

    /// When a microphone capture last started or stopped (Ensemble's own dictation or Claude's); see
    /// `HeadphoneInputFilter.micChangeWindow`.
    static var lastMicChangeAt: TimeInterval = -.infinity
    static func noteMicChange() { lastMicChangeAt = CACurrentMediaTime() }

    var onAction: (HeadphoneAction) -> Void = { _ in }
    private let settingOn: () -> Bool
    private let claudeRunning: () -> Bool
    private var gate = HeadphoneClaimGate()
    private var filter = HeadphoneInputFilter()
    private var timer: Timer?
    private var polling = false
    private var tokens: [(MPRemoteCommand, Any)] = []
    private var logged: Bool?

    init(settingOn: @escaping () -> Bool, claudeRunning: @escaping () -> Bool) {
        self.settingOn = settingOn
        self.claudeRunning = claudeRunning
    }

    /// Polls once a second while Ensemble is on; `apply` makes and drops the claim.
    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { self.poll() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        gate = HeadphoneClaimGate()
        release()
    }

    /// The setting changed: re-evaluate now instead of at the next poll.
    func refresh() { poll() }

    private func poll() {
        guard !polling else { return }
        let on = settingOn(), running = claudeRunning()
        guard on, running else {
            apply(HeadphoneConditions(settingOn: on, outputIsBluetooth: false, claudeRunning: running, otherAudioPlaying: false))
            return
        }
        polling = true
        // CoreAudio can stall while a device is changing; never wait on it from the main thread.
        Task.detached {
            let (bluetooth, other) = Self.audioFacts()
            await MainActor.run {
                self.polling = false
                self.apply(HeadphoneConditions(settingOn: self.settingOn(), outputIsBluetooth: bluetooth,
                                               claudeRunning: self.claudeRunning(), otherAudioPlaying: other))
            }
        }
    }

    private func apply(_ c: HeadphoneConditions) {
        let want = gate.update(c)
        guard want != !tokens.isEmpty else { return }
        if want { claim() } else { release() }
        EnsembleLog.write(want ? "headphone presses: holding Now Playing"
                               : "headphone presses: released Now Playing (setting \(c.settingOn), bluetooth \(c.outputIsBluetooth), Claude \(c.claudeRunning), other audio \(c.otherAudioPlaying))")
    }

    // MARK: Now Playing

    private func claim() {
        let center = MPRemoteCommandCenter.shared()
        func hook(_ command: MPRemoteCommand, _ kind: HeadphoneCommand) {
            command.isEnabled = true
            tokens.append((command, command.addTarget { [weak self] _ in
                let t = CACurrentMediaTime()
                Task { @MainActor in self?.received(kind, at: t) }
                return .success
            }))
        }
        hook(center.togglePlayPauseCommand, .togglePlayPause)
        hook(center.playCommand, .play)
        hook(center.pauseCommand, .pause)
        hook(center.nextTrackCommand, .nextTrack)
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = [MPMediaItemPropertyTitle: "Ensemble headphone presses"]
        info.playbackState = .playing
    }

    private func release() {
        guard !tokens.isEmpty else { return }
        for (command, token) in tokens { command.removeTarget(token); command.isEnabled = false }
        tokens = []
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = nil
        info.playbackState = .stopped
    }

    private func received(_ command: HeadphoneCommand, at t: TimeInterval) {
        guard let action = filter.accept(command, at: t, lastSyntheticKeyAt: Self.lastSyntheticKeyAt,
                                     lastMicChangeAt: Self.lastMicChangeAt) else {
            EnsembleLog.write("headphone command \(command) ignored")
            return
        }
        EnsembleLog.write("headphone command \(command) -> \(action)")
        onAction(action)
    }

    // MARK: CoreAudio

    /// Whether the default output is Bluetooth, and whether some app other than Ensemble, Claude or the system
    /// sound player is sending audio out (the audio pause's per-process check: the device itself stays "running"
    /// for a while after any short sound).
    nonisolated private static func audioFacts() -> (bluetooth: Bool, otherPlaying: Bool) {
        guard let dev = MediaDucker.defaultOutput() else { return (false, false) }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE else { return (false, false) }
        return (true, MediaDucker.mediaPlaying(dev))
    }
}
