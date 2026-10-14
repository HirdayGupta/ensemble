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
            // No durable record, no mute: an unrecorded mute could never be undone by a later launch.
            records.append(record)
            do { try SafetyFiles.writeMutes(records) } catch {
                records.removeLast()
                EnsembleLog.write("mute skipped: could not write the mute record (\(error))")
                continue
            }
            switch record.method {
            case .mute: CoreAudioInput.setMuted(device, true)
            case .volume: CoreAudioInput.setVolume(device, 0)
            }
        }
        return isActive
    }

    /// Undo what this app did, but only where its change is still in effect. A record stays on disk while its
    /// device is absent or its restore could not be confirmed, so a later launch can try again.
    /// Returns true if anything was undone.
    @discardableResult
    mutating func restore() -> Bool {
        var restored = false
        var remaining: [MuteRecord] = []
        for record in records {
            guard let device = CoreAudioInput.device(withUID: record.deviceUID) else { remaining.append(record); continue }
            switch record.method {
            case .mute:
                switch CoreAudioInput.isMuted(device) {
                case true?:
                    CoreAudioInput.setMuted(device, record.priorMuted ?? false)
                    if CoreAudioInput.isMuted(device) == (record.priorMuted ?? false) { restored = true } else { remaining.append(record) }
                case nil: remaining.append(record)
                case false?: break
                }
            case .volume:
                guard let v = CoreAudioInput.volume(device) else { remaining.append(record); continue }
                if v < 0.001 {
                    let prior = record.priorVolume ?? 0.5
                    CoreAudioInput.setVolume(device, prior)
                    if let after = CoreAudioInput.volume(device), after > 0.001 { restored = true } else { remaining.append(record) }
                }
            }
        }
        records = remaining
        if remaining.isEmpty {
            SafetyFiles.deleteMutes()
        } else {
            try? SafetyFiles.writeMutes(remaining)
            EnsembleLog.write("mute restore incomplete: \(remaining.count) record(s) kept for a later attempt")
        }
        return restored
    }
}
