import AppKit
import AudioToolbox
import CoreAudio

/// Other audio playing through speakers would be heard by the microphone and transcribed. While dictating, this
/// fades the system output down in 0.25 s and presses play/pause; afterwards it presses play again and fades the
/// volume back in 0.4 s. Headphones and Bluetooth output are left alone: the microphone cannot hear them.
///
/// macOS 15.4 removed apps' access to which app is playing, so play/pause goes to whatever macOS treats as
/// "now playing". If the audio is still playing half a second later, that press reached the wrong app and is
/// undone; the volume stays down either way, so the transcript is protected even then.
///
/// The volume to return to is saved before it is touched: a crash mid-dictation is put right on the next launch.
@MainActor
final class MediaDucker {
    private var device: AudioObjectID?
    private var savedVolume: Float32?
    private var paused = false
    private var work: Task<Void, Never>?
    private static let savedKey = "duck.savedVolume"
    private static let savedUIDKey = "duck.deviceUID"

    var isActive: Bool { device != nil }

    func duck() {
        guard device == nil, let dev = Self.defaultOutput(), Self.isPlaying(dev), !Self.isHeadphones(dev) else { return }
        device = dev
        let volume = Self.volume(dev)
        savedVolume = volume
        if let volume, let uid = Self.uid(dev) {
            UserDefaults.standard.set(volume, forKey: Self.savedKey)
            UserDefaults.standard.set(uid, forKey: Self.savedUIDKey)
        }
        EnsembleLog.write("audio playing on speakers: fading out and pausing")
        work = Task { @MainActor in
            if let volume { await Self.ramp(dev, from: volume, to: 0, seconds: 0.25) }
            guard !Task.isCancelled else { return }
            Self.pressPlayPause()
            self.paused = true
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            if Self.isPlaying(dev) {
                Self.pressPlayPause()
                self.paused = false
                EnsembleLog.write("play/pause did not stop the audio; press undone, volume stays down while dictating")
            }
        }
    }

    func restore() {
        guard let dev = device else { return }
        work?.cancel(); work = nil
        device = nil
        if paused { Self.pressPlayPause(); paused = false }
        let target = savedVolume
        savedVolume = nil
        Task { @MainActor in
            if let target {
                try? await Task.sleep(nanoseconds: 150_000_000)      // let playback resume under the fade
                await Self.ramp(dev, from: Self.volume(dev) ?? 0, to: target, seconds: 0.4)
            }
            UserDefaults.standard.removeObject(forKey: Self.savedKey)
            UserDefaults.standard.removeObject(forKey: Self.savedUIDKey)
        }
    }

    /// Quit path: put the volume back at once, no fade.
    func restoreNow() {
        guard let dev = device else { return }
        work?.cancel(); work = nil
        device = nil
        if paused { Self.pressPlayPause(); paused = false }
        if let v = savedVolume { Self.setVolume(dev, v) }
        savedVolume = nil
        UserDefaults.standard.removeObject(forKey: Self.savedKey)
        UserDefaults.standard.removeObject(forKey: Self.savedUIDKey)
    }

    /// Launch: a volume left down by a crash goes back to where it was.
    static func recoverAfterCrash() {
        let d = UserDefaults.standard
        guard let v = d.object(forKey: savedKey) as? Float, let uid = d.string(forKey: savedUIDKey) else { return }
        if let dev = device(forUID: uid) { setVolume(dev, v); EnsembleLog.write("restored the output volume left down by an earlier run") }
        d.removeObject(forKey: savedKey); d.removeObject(forKey: savedUIDKey)
    }

    // MARK: CoreAudio

    private static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ initial: T) -> T? {
        var a = address(sel, scope), v = initial, size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func defaultOutput() -> AudioObjectID? {
        guard let d: AudioObjectID = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, 0), d != 0 else { return nil }
        return d
    }

    static func isPlaying(_ dev: AudioObjectID) -> Bool {
        (read(dev, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0) != 0
    }

    /// Bluetooth output, or the built-in headphone jack: the microphone cannot hear it.
    static func isHeadphones(_ dev: AudioObjectID) -> Bool {
        let transport: UInt32 = read(dev, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, 0) ?? 0
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE { return true }
        if transport == kAudioDeviceTransportTypeBuiltIn,
           let source: UInt32 = read(dev, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput, 0) {
            return source == 0x6864706E   // 'hdpn'
        }
        return false
    }

    static func volume(_ dev: AudioObjectID) -> Float32? {
        read(dev, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput, Float32(0))
    }

    static func setVolume(_ dev: AudioObjectID, _ v: Float32) {
        var a = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        var value = max(0, min(1, v))
        _ = AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    /// Eased volume ramp in 60 Hz steps.
    static func ramp(_ dev: AudioObjectID, from: Float32, to: Float32, seconds: Double) async {
        let steps = max(1, Int(seconds * 60))
        for i in 1...steps {
            if Task.isCancelled { return }
            let x = Float32(i) / Float32(steps)
            let eased = x * x * (3 - 2 * x)
            setVolume(dev, from + (to - from) * eased)
            try? await Task.sleep(nanoseconds: UInt64(seconds / Double(steps) * 1e9))
        }
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
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: (16 << 16) | (state << 8), data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
