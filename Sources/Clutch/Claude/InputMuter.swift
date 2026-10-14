import CoreAudio
import Foundation

/// Last-resort safeguard: silence the input device Claude is recording from when Claude's own stop
/// control cannot be confirmed. Every change is recorded in mute.json first so that a later launch can
/// undo it. Not thread-safe; owned by DictationSafety's queue.
struct InputMuter {
    private(set) var records: [MuteRecord] = SafetyFiles.readMutes()

    var isActive: Bool { !records.isEmpty }

    /// Devices Claude is capturing from, falling back to the default input device.
    static func targetDevices() -> [AudioObjectID] {
        var devices: [AudioObjectID] = []
        for p in CoreAudioInput.processes() ?? [] where p.isRunningInput && p.bundleID.hasPrefix(ClaudeLabels.bundleID) {
            devices += CoreAudioInput.inputDevices(of: p)
        }
        if devices.isEmpty, let d = CoreAudioInput.defaultInputDevice() { devices = [d] }
        return Array(Set(devices))
    }

    /// Returns true when at least one device is now silenced by us.
    mutating func apply() -> Bool {
        for device in Self.targetDevices() {
            guard let uid = CoreAudioInput.deviceUID(device), !records.contains(where: { $0.deviceUID == uid }) else { continue }
            var record: MuteRecord?
            if CoreAudioInput.muteIsSettable(device), let muted = CoreAudioInput.isMuted(device) {
                if muted { continue }
                record = MuteRecord(deviceUID: uid, method: .mute, priorMuted: false, priorVolume: nil, appliedAt: Date())
            } else if CoreAudioInput.volumeIsSettable(device), let volume = CoreAudioInput.volume(device) {
                if volume < 0.001 { continue }
                record = MuteRecord(deviceUID: uid, method: .volume, priorMuted: nil, priorVolume: volume, appliedAt: Date())
            }
            guard let record else { continue }
            records.append(record)
            try? SafetyFiles.writeMutes(records)
            switch record.method {
            case .mute: CoreAudioInput.setMuted(device, true)
            case .volume: CoreAudioInput.setVolume(device, 0)
            }
        }
        return isActive
    }

    /// Undo what this app did, but only where its change is still in effect. Returns true if anything was undone.
    @discardableResult
    mutating func restore() -> Bool {
        var restored = false
        for record in records {
            guard let device = CoreAudioInput.device(withUID: record.deviceUID) else { continue }
            switch record.method {
            case .mute:
                if CoreAudioInput.isMuted(device) == true {
                    CoreAudioInput.setMuted(device, record.priorMuted ?? false)
                    restored = true
                }
            case .volume:
                if let v = CoreAudioInput.volume(device), v < 0.001 {
                    CoreAudioInput.setVolume(device, record.priorVolume ?? 0.5)
                    restored = true
                }
            }
        }
        records = []
        SafetyFiles.deleteMutes()
        return restored
    }
}
