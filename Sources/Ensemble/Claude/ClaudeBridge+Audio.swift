import AppKit
import ApplicationServices
import EnsembleCore
import CoreGraphics
import Foundation

extension ClaudeBridge {
    enum CheckboxReading: Equatable {
        case on, off, unreadable, conflict
    }

    /// What the mic checkbox reports about itself: AXValue (1/0) and its label ("Stop dictation" while recording).
    struct CheckboxSnapshot {
        var value: Int?
        var label: String?
        var text: String { "AX value=\(value.map(String.init) ?? "none") label=\(label.map { "\"\($0)\"" } ?? "none")" }
    }

    static func checkboxSnapshot(_ el: AXUIElement) -> CheckboxSnapshot {
        let v = AX.multi(el, [kAXValueAttribute, kAXDescriptionAttribute])
        return CheckboxSnapshot(value: (v[0] as? NSNumber)?.intValue, label: v[1] as? String)
    }

    static func reading(of snapshot: CheckboxSnapshot) -> CheckboxReading {
        let byValue: Bool? = snapshot.value.flatMap { $0 == 1 ? true : ($0 == 0 ? false : nil) }
        let byLabel: Bool? = snapshot.label.flatMap {
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
        let roots = Self.claudeRoots()
        return processes.contains { $0.isRunningInput && Self.isClaude($0, roots: roots) }
    }

    /// Claude's own processes, the roots for `isClaude`.
    static func claudeRoots() -> Set<pid_t> {
        Set(NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeLabels.bundleID).map(\.processIdentifier))
    }

    /// The one test for "this audio process is Claude": its bundle id, or descent from a Claude process (helpers
    /// that carry no bundle id). The capture check and the safety mute use it alike, so the mute always lands on
    /// the device of whatever the capture check counted.
    static func isClaude(_ p: AudioProcess, roots: Set<pid_t>) -> Bool {
        p.bundleID.hasPrefix(ClaudeLabels.bundleID) || ProcessInfoLookup.isDescendant(p.pid, ofAny: roots)
    }

    func micStateSync(mic: AXUIElement) -> MicState {
        let snapshot = Self.checkboxSnapshot(mic)
        let captureReading = claudeCaptureActive()
        noteMic("\(snapshot.text) capture=\(captureReading.map(String.init) ?? "unreadable")")
        guard let capture = captureReading else { return .unknown("CoreAudio process list unreadable") }
        switch Self.reading(of: snapshot) {
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
        guard let entry = liveEntry(s) else { return .unknown(self.sessionNotFound) }
        return micStateSync(mic: entry.elements.mic)
    }

    // MARK: Who else is listening

    /// Display name of any process other than Claude (and its helpers) and this app that is capturing input.
    func otherProcessCapturingInput() -> String? {
        guard let processes = CoreAudioInput.processes() else { return nil }
        let roots = Self.claudeRoots()
        let me = ProcessInfo.processInfo.processIdentifier
        let myBundle = Bundle.main.bundleIdentifier
        for p in processes where p.isRunningInput {
            if p.pid == me || (myBundle != nil && p.bundleID == myBundle) { continue }
            if Self.isClaude(p, roots: roots) { continue }
            if Self.ambientInputAllowlist.contains(p.bundleID) { continue }
            return ProcessInfoLookup.name(of: p.pid) ?? (p.bundleID.isEmpty ? "pid \(p.pid)" : p.bundleID)
        }
        return nil
    }

    func defaultInputDeviceName() -> String? {
        CoreAudioInput.defaultInputDevice().flatMap { CoreAudioInput.deviceName($0) }
    }

    /// Seconds since the user last pressed a key, moved or clicked the mouse, or scrolled.
    /// Typing or clicking only (no pointer motion or scrolling): what ends a dictation, since a nudged mouse should not.
    /// Hardware input only (keyboard, mouse, trackpad): the HID state ignores events Ensemble itself posts.
    static func secondsSincePhysicalInput() -> Double {
        let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .leftMouseDragged]
        return types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
    }

    /// When each kind of hardware input last happened, on the `CACurrentMediaTime` clock, for `HandsBusy`. The HID
    /// state never holds the scrolls and keys Ensemble posts itself.
    static func lastHardwareInput(now: TimeInterval) -> (key: TimeInterval, click: TimeInterval, scroll: TimeInterval, move: TimeInterval) {
        func at(_ types: [CGEventType]) -> TimeInterval {
            now - (types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity)
        }
        return (at([.keyDown]), at([.leftMouseDown, .rightMouseDown, .otherMouseDown]), at([.scrollWheel]),
                at([.mouseMoved, .leftMouseDragged, .rightMouseDragged]))
    }

    static func secondsSinceTypingOrClick() -> Double {
        min(secondsSinceOwnerKey(), secondsSinceClick())
    }

    /// Clicks only, for a send asked for with Return: the keys are watched separately.
    static func secondsSinceClick() -> Double {
        [CGEventType.leftMouseDown, .rightMouseDown].map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? .infinity
    }

    /// Seconds since the owner last pressed a key. A key Ensemble posted itself (a pane divider key) is not the
    /// owner typing (`OwnInputWindows`).
    static func secondsSinceOwnerKey() -> Double {
        let now = CACurrentMediaTime()
        let combined = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let hardware = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        ownKeyLock.lock(); defer { ownKeyLock.unlock() }
        return ownKeys.ownerAge(combined: combined, hardware: hardware, now: now)
    }

    private static let ownKeyLock = NSLock()
    nonisolated(unsafe) private static var ownKeys = OwnInputWindows()

    /// Ensemble's own key windows so far, for `HandsBusy`.
    static func ownKeysNow() -> OwnInputWindows {
        ownKeyLock.lock(); defer { ownKeyLock.unlock() }
        return ownKeys
    }

    /// Ensemble starts or ends posting its own keys; see `OwnInputWindows`.
    static func ownKeys(began: Bool) {
        let now = CACurrentMediaTime()
        ownKeyLock.lock(); defer { ownKeyLock.unlock() }
        if began { ownKeys.begin(at: now) } else { ownKeys.end(at: now) }
    }

    static func secondsSinceUserInput() -> Double {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
        let other = types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
        return min(other, secondsSinceOwnerKey())
    }
}
