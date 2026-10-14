import AppKit
import ApplicationServices
import ClutchCore
import CoreGraphics
import Foundation

extension ClaudeBridge {
    enum CheckboxReading: Equatable {
        case on, off, unreadable, conflict
    }

    /// The mic checkbox's own view of itself: AXValue (1/0) and its label ("Stop dictation" while recording).
    static func readCheckbox(_ el: AXUIElement) -> CheckboxReading {
        let v = AX.multi(el, [kAXValueAttribute, kAXDescriptionAttribute])
        let byValue: Bool? = (v[0] as? NSNumber).flatMap { $0.intValue == 1 ? true : ($0.intValue == 0 ? false : nil) }
        let byLabel: Bool? = (v[1] as? String).flatMap {
            $0 == ClaudeLabels.micActive ? true : ($0 == ClaudeLabels.micIdle ? false : nil)
        }
        switch (byValue, byLabel) {
        case let (a?, b?): return a == b ? (a ? .on : .off) : .conflict
        case let (a?, nil): return a ? .on : .off
        case let (nil, b?): return b ? .on : .off
        case (nil, nil): return .unreadable
        }
    }

    /// Whether any Claude process (helpers included, and anything descended from Claude) is capturing input.
    /// nil = the CoreAudio process list could not be read.
    func claudeCaptureActive() -> Bool? {
        guard let processes = CoreAudioInput.processes() else { return nil }
        let roots = Set(NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeLabels.bundleID).map(\.processIdentifier))
        for p in processes where p.isRunningInput {
            if p.bundleID.hasPrefix(ClaudeLabels.bundleID) { return true }
            if ProcessInfoLookup.isDescendant(p.pid, ofAny: roots) { return true }
        }
        return false
    }

    func micStateSync(mic: AXUIElement) -> MicState {
        guard let capture = claudeCaptureActive() else { return .unknown("CoreAudio process list unreadable") }
        switch Self.readCheckbox(mic) {
        case .on:
            return capture ? .on : .unknown("checkbox says recording but Claude is not capturing audio")
        case .off:
            return capture ? .unknown("Claude is capturing audio but the checkbox says idle") : .off
        case .unreadable:
            return capture ? .on : .off
        case .conflict:
            return .unknown("checkbox value and label disagree")
        }
    }

    /// Fresh read of both sources: the checkbox and CoreAudio capture. `.on` needs both to agree.
    func micState(_ s: ClaudeSession) async -> MicState {
        await run { self.micStateNow(s) }
    }

    func micStateNow(_ s: ClaudeSession) -> MicState {
        guard let entry = liveEntry(s) else { return .unknown("session not found") }
        return micStateSync(mic: entry.elements.mic)
    }

    // MARK: Who else is listening

    /// Display name of any process other than Claude (and its helpers) and this app that is capturing input.
    func otherProcessCapturingInput() -> String? {
        guard let processes = CoreAudioInput.processes() else { return nil }
        let roots = Set(NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeLabels.bundleID).map(\.processIdentifier))
        let me = ProcessInfo.processInfo.processIdentifier
        let myBundle = Bundle.main.bundleIdentifier
        for p in processes where p.isRunningInput {
            if p.pid == me || (myBundle != nil && p.bundleID == myBundle) { continue }
            if p.bundleID.hasPrefix(ClaudeLabels.bundleID) || ProcessInfoLookup.isDescendant(p.pid, ofAny: roots) { continue }
            if Self.ambientInputAllowlist.contains(p.bundleID) { continue }
            return ProcessInfoLookup.name(of: p.pid) ?? (p.bundleID.isEmpty ? "pid \(p.pid)" : p.bundleID)
        }
        return nil
    }

    func defaultInputDeviceName() -> String? {
        CoreAudioInput.defaultInputDevice().flatMap { CoreAudioInput.deviceName($0) }
    }

    /// Seconds since the user last pressed a key, moved or clicked the mouse, or scrolled.
    static func secondsSinceUserInput() -> Double {
        let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
    }
}
