import AppKit
import AudioToolbox
import CoreAudio

/// Other audio playing through speakers would be heard by the microphone and transcribed. Before dictation starts,
/// this presses play/pause and checks the media stopped; when dictation ends it waits out Ensemble's stop cue and
/// presses play again. Headphones and Bluetooth output are left alone: the microphone cannot hear them.
///
/// Allowlist model (owner, 2026-10-15): the output volume is never touched, so Claude's sounds and Ensemble's cues
/// always play at the owner's volume; only other apps' media is paused. Silencing other apps without the key would
/// need a CoreAudio process tap, which needs the System Audio Recording permission (docs/gotchas.md, 6).
///
/// macOS 15.4 removed apps' access to which app is playing, so play/pause goes to whatever macOS treats as
/// "now playing". The check that the sound actually stopped runs before Claude's microphone is pressed; if it did
/// not stop, the press is undone and nothing else is touched.
@MainActor
final class MediaDucker {
    /// The speakers whose media this dictation paused.
    private var paused: AudioObjectID?
    /// The resume after a dictation, while it waits out the stop cue.
    private var resumeTask: Task<Void, Never>?
    private var resumePending: AudioObjectID?
    /// Where builds before the allowlist model saved a volume they had lowered.
    private static let savedKey = "duck.savedVolume"
    private static let savedUIDKey = "duck.deviceUID"

    /// Runs before the microphone is pressed; returns once the media is paused (about 0.25 s) or at once when
    /// nothing is playing on speakers.
    func duck() async {
        // A resume from the last dictation may still be waiting: cancel it, and the media stays paused for this one.
        if let pending = resumeTask {
            pending.cancel()
            resumeTask = nil
            if let p = resumePending {
                resumePending = nil
                paused = p
                EnsembleLog.write("a new dictation began before the audio resumed; it stays paused")
                return
            }
        }
        guard paused == nil, let dev = Self.defaultOutput(), Self.mediaPlaying(dev), !Self.isHeadphones(dev) else { return }
        Self.pressPlayPause()
        try? await Task.sleep(nanoseconds: 250_000_000)
        let stopped = !Self.mediaPlaying(dev)
        if !stopped { Self.pressPlayPause() }
        EnsembleLog.write(stopped ? "audio on speakers paused for dictation (volume untouched)"
                                  : "play/pause did not stop the audio; press undone, audio left as it was")
        if stopped { paused = dev }
    }

    /// Dictation ended: after the stop sound (up to 0.35 s late and about 1 s long), resume the media.
    func restore() {
        guard let p = paused else { return }
        paused = nil
        resumePending = p
        resumeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard !Task.isCancelled, self.resumePending != nil else { return }
            self.resumePending = nil
            self.resumeTask = nil
            Self.pressPlayPause()
        }
    }

    /// Quit path: resume at once.
    func restoreNow() {
        resumeTask?.cancel()
        resumeTask = nil
        if let p = resumePending { resumePending = nil; paused = p }
        guard paused != nil else { return }
        paused = nil
        Self.pressPlayPause()
    }

    /// Launch: a volume an earlier build left down when it crashed mid-fade goes back to where it was.
    static func recoverAfterCrash() {
        let d = UserDefaults.standard
        guard let v = d.object(forKey: savedKey) as? Float, let uid = d.string(forKey: savedUIDKey) else { return }
        if let dev = device(forUID: uid) { setVolume(dev, v); EnsembleLog.write("restored the output volume left down by an earlier run") }
        d.removeObject(forKey: savedKey); d.removeObject(forKey: savedUIDKey)
    }

    // MARK: CoreAudio

    nonisolated private static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    nonisolated private static func read<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ initial: T) -> T? {
        var a = address(sel, scope), v = initial, size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    nonisolated static func defaultOutput() -> AudioObjectID? {
        guard let d: AudioObjectID = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, 0), d != 0 else { return nil }
        return d
    }

    /// Some app other than Claude, Ensemble or the system sound player is sending audio out. Per process, because the
    /// output device itself stays "running" for a while after any short sound (measured 2026-10-14: a dictation
    /// chime read as music playing, and the media key went to the wrong app).
    nonisolated static func mediaPlaying(_ dev: AudioObjectID) -> Bool {
        guard let procs = CoreAudioInput.processes() else { return isPlaying(dev) }
        let me = ProcessInfo.processInfo.processIdentifier
        return procs.contains { p in
            p.isRunningOutput && p.pid != me
                && !p.bundleID.hasPrefix("com.anthropic.claudefordesktop")
                && !p.bundleID.localizedCaseInsensitiveContains("systemsound")
                && !p.bundleID.hasPrefix("com.apple.audio")
        }
    }

    nonisolated static func isPlaying(_ dev: AudioObjectID) -> Bool {
        (read(dev, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0) != 0
    }

    nonisolated static func isBluetooth(_ dev: AudioObjectID) -> Bool {
        let transport: UInt32 = read(dev, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, 0) ?? 0
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Bluetooth output, or the built-in headphone jack: the microphone cannot hear it.
    static func isHeadphones(_ dev: AudioObjectID) -> Bool {
        if isBluetooth(dev) { return true }
        let transport: UInt32 = read(dev, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, 0) ?? 0
        if transport == kAudioDeviceTransportTypeBuiltIn,
           let source: UInt32 = read(dev, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput, 0) {
            return source == 0x6864706E   // 'hdpn'
        }
        return false
    }

    private static func setVolume(_ dev: AudioObjectID, _ v: Float32) {
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        var value = max(0, min(1, v))
        _ = AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    static func uid(_ dev: AudioObjectID) -> String? {
        var a = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &uid) == noErr, let u = uid else { return nil }
        return u.takeRetainedValue() as String
    }

    static func device(forUID uid: String) -> AudioObjectID? {
        guard let devices = allDevices() else { return nil }
        return devices.first { Self.uid($0) == uid }
    }

    private static func allDevices() -> [AudioObjectID]? {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return nil }
        return ids
    }

    /// The keyboard's play/pause key (NX_KEYTYPE_PLAY), down then up.
    static func pressPlayPause() {
        // The system can hand this key back to us as a headphone remote command; HeadphoneRemote drops those.
        HeadphoneRemote.lastSyntheticKeyAt = CACurrentMediaTime()
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: (16 << 16) | (state << 8), data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
