import AppKit
import ApplicationServices
import ClutchCore
import CoreAudio
import Foundation

/// Read-only report on what this Mac exposes: Accessibility trust, Claude's session panes and their
/// controls, and CoreAudio's view of who is capturing input. Never presses, types, scrolls or mutes.
enum ClaudeProbe {
    static func run() async -> String {
        var out: [String] = []
        func line(_ s: String = "") { out.append(s) }

        let bridge = ClaudeBridge()
        line("AXIsProcessTrusted: \(AXIsProcessTrusted())")
        line("Claude running: \(bridge.claudeIsRunning())  frontmost: \(bridge.claudeIsFrontmost())  version: \(bridge.claudeVersion ?? "nil")  pid: \(bridge.claudePID.map(String.init) ?? "nil")")

        if let pid = bridge.claudePID {
            let app = AX.application(pid: pid)
            let before = AX.nodeCount(app)
            let err = AX.set(app, "AXManualAccessibility", kCFBooleanTrue)
            var after = AX.nodeCount(app)
            for _ in 0..<10 where after <= before {
                try? await Task.sleep(nanoseconds: 300_000_000)
                after = AX.nodeCount(app)
            }
            line("AX node count before flag: \(before)  set AXManualAccessibility error: \(err.rawValue)  after: \(after)")
        }

        let t0 = Date()
        let sessions = await bridge.refreshSessions()
        line("refreshSessions: \(sessions.count) session(s) in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")

        for s in sessions {
            line()
            line("SESSION \(s.id)  window#\(s.windowNumber)  frame \(fmt(s.frame))")
            guard let entry = bridge.liveEntry(s, rescanPane: true) else { line("  (could not resolve)"); continue }
            let e = entry.elements
            line("  mic: \(describe(e.mic, extra: [kAXValueAttribute, kAXEnabledAttribute, kAXSubroleAttribute]))")
            line("       actions: \(AX.actionNames(e.mic))  parent: \(AX.parent(e.mic).map { describe($0, extra: []) } ?? "nil")")
            line("       checkbox reading: \(ClaudeBridge.readCheckbox(e.mic))")
            line("  composer: \(e.composer.map { "role \(AX.role($0) ?? "?") desc \(AX.desc($0) ?? "nil") value length \((AX.string($0, kAXValueAttribute) ?? "").count) focused \(AX.bool($0, kAXFocusedAttribute).map(String.init) ?? "nil")" } ?? "NOT FOUND")")
            line("  send button: \(e.sendButton.map { describe($0, extra: [kAXEnabledAttribute]) } ?? "NOT PRESENT")")
            line("  stop button: \(e.stopButton.map { describe($0, extra: [kAXEnabledAttribute]) } ?? "not present")")
            line("  mode control: \(e.modeControl.map { describe($0, extra: []) } ?? "NOT FOUND")  actions: \(e.modeControl.map { AX.actionNames($0) } ?? [])")
            line("  transcript group: \(e.transcript.map { describe($0, extra: []) + " frame " + (AX.frame($0).map(fmt) ?? "nil") } ?? "NOT FOUND")")
            line("  AXScrollArea inside pane: \(ClaudeBridge.findScrollArea(in: e.pane) != nil)")
            line("  permissionMode(): \(await bridge.permissionMode(s) ?? "nil")")
            line("  isGenerating(): \(await bridge.isGenerating(s).map(String.init) ?? "nil")")
            line("  draftText() length: \(await bridge.draftText(s)?.count.description ?? "nil")")
            line("  micState(): \(describe(await bridge.micState(s)))")
        }

        line()
        line("CoreAudio processes (\(CoreAudioInput.processes()?.count ?? -1)); * = input running")
        for p in CoreAudioInput.processes() ?? [] {
            let devices = CoreAudioInput.inputDevices(of: p).compactMap { CoreAudioInput.deviceName($0) }
            line("  \(p.isRunningInput ? "*" : " ") pid \(p.pid)  \(p.bundleID.isEmpty ? "(no bundle id)" : p.bundleID)  input=\(p.isRunningInput) output=\(p.isRunningOutput)\(devices.isEmpty ? "" : " devices=\(devices)")  name=\(ProcessInfoLookup.name(of: p.pid) ?? "?")")
        }
        line("claudeCaptureActive(): \(bridge.claudeCaptureActive().map(String.init) ?? "nil")")
        line("otherProcessCapturingInput(): \(bridge.otherProcessCapturingInput() ?? "none")")
        line("secondsSinceUserInput(): \(String(format: "%.1f", ClaudeBridge.secondsSinceUserInput()))")

        if let device = CoreAudioInput.defaultInputDevice() {
            line("default input device: \(CoreAudioInput.deviceName(device) ?? "?")  uid \(CoreAudioInput.deviceUID(device) ?? "?")")
            line("  mute settable: \(CoreAudioInput.muteIsSettable(device))  muted now: \(CoreAudioInput.isMuted(device).map(String.init) ?? "nil")")
            line("  volume settable: \(CoreAudioInput.volumeIsSettable(device))  volume now: \(CoreAudioInput.volume(device).map { String(format: "%.2f", $0) } ?? "nil")")
        } else {
            line("default input device: none")
        }
        line("safety files: episode.json exists=\(SafetyFiles.episodeFileExists())  mute.json records=\(SafetyFiles.readMutes().count)")
        return out.joined(separator: "\n")
    }

    private static func fmt(_ r: CGRect) -> String {
        "[\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))]"
    }

    private static func describe(_ state: MicState) -> String {
        switch state {
        case .on: return "on"
        case .off: return "off"
        case .unknown(let why): return "unknown (\(why))"
        }
    }

    private static func describe(_ el: AXUIElement, extra: [String]) -> String {
        var parts = ["role \(AX.role(el) ?? "?")"]
        if let t = AX.title(el), !t.isEmpty { parts.append("title \"\(t)\"") }
        if let d = AX.desc(el), !d.isEmpty { parts.append("desc \"\(d)\"") }
        for a in extra {
            if let v = AX.copy(el, a) { parts.append("\(a.replacingOccurrences(of: "AX", with: "")) \(v)") }
        }
        if let f = AX.frame(el) { parts.append("frame \(fmt(f))") }
        return parts.joined(separator: ", ")
    }
}
