import AppKit
import ApplicationServices
import EnsembleCore
import Foundation

extension ClaudeBridge {
    private static let confirmWindow: TimeInterval = 1.5
    private static let pollInterval: TimeInterval = 0.075
    private static let stopCooldown: TimeInterval = 2.5

    /// Brings Claude forward and puts the cursor in the session's composer. Never touches the pointer.
    /// With `unlessTypedWithin`, the check runs on the bridge queue right before Claude is raised, so a keystroke
    /// or click that arrived while this call waited behind a slow Accessibility walk still wins.
    func focus(_ s: ClaudeSession, unlessTypedWithin quiet: TimeInterval = 0) async -> BridgeResult {
        await run {
            if quiet > 0, Self.secondsSinceTypingOrClick() < quiet { return .refused("you just typed or clicked") }
            return self.focusNow(s)
        }
    }

    func focusNow(_ s: ClaudeSession) -> BridgeResult {
        guard let entry = liveEntry(s), let pid = claudePID else { return .refused(self.sessionNotFound) }
        DispatchQueue.main.async {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
        AX.set(AX.application(pid: pid), kAXFrontmostAttribute, kCFBooleanTrue)
        AX.perform(entry.elements.window, kAXRaiseAction)
        guard let composer = entry.elements.composer else { return .unknown("raised Claude; composer not found") }
        let err = AX.set(composer, kAXFocusedAttribute, kCFBooleanTrue)
        if err != .success { return .unknown("raised Claude; focusing the composer failed (\(err.rawValue))") }
        return AX.bool(composer, kAXFocusedAttribute) == true ? .done : .unknown("raised Claude; composer focus not confirmed")
    }

    /// Puts the keyboard in the session's message box once dictation is on, so a key typed meanwhile lands there.
    /// Never raises Claude or moves it in front: with another app in front nothing is touched. Returns a log note.
    func focusComposerIfNeeded(_ s: ClaudeSession) async -> String {
        await run {
            guard let composer = self.liveEntry(s)?.elements.composer else { return "message box not found" }
            guard ReturnKeys.focusComposerAfterStart(claudeInFront: self.claudeIsFrontmost(),
                                                     composerFocused: AX.bool(composer, kAXFocusedAttribute)) else {
                return "message box left as is"
            }
            let err = AX.set(composer, kAXFocusedAttribute, kCFBooleanTrue)
            if err != .success { return "focusing the message box failed (\(err.rawValue))" }
            return AX.bool(composer, kAXFocusedAttribute) == true ? "message box focused" : "message box focus not confirmed"
        }
    }

    /// Starts Claude's dictation: exactly one press, and only when the mic is verifiably off.
    func startDictation(_ s: ClaudeSession) async -> BridgeResult {
        await run(onStartQueue: true) { self.startNow(s) }
    }

    private func startNow(_ s: ClaudeSession) -> BridgeResult {
        if isShuttingDown { return .refused("Ensemble is quitting") }
        guard let before = liveEntry(s) else { return .refused(self.sessionNotFound) }
        let state = micStateSync(mic: before.elements.mic)
        guard state == .off else { return .refused("mic is not verifiably off: \(describe(state))") }

        _ = focusNow(s)

        // Focusing can re-render the pane; re-resolve the element and re-check right before the press.
        guard let entry = liveEntry(s) else { return .refused("session vanished while focusing") }
        let recheck = micStateSync(mic: entry.elements.mic)
        guard recheck == .off else { return .refused("mic state changed while focusing: \(describe(recheck))") }

        if isShuttingDown { return .refused("Ensemble is quitting") }
        let err = AX.perform(entry.elements.mic, kAXPressAction)
        let last = pollMic(entry.elements.mic, until: .on)
        if last == .on { return .done }
        let note = err == .success ? "" : " (press error \(err.rawValue))"
        return .unknown("pressed once; mic not confirmed on, last state \(describe(last))\(note)")
    }

    /// Stops dictation: presses only when the mic is verifiably on, at most once, never when off or unknown.
    func stopDictation(_ s: ClaudeSession) async -> BridgeResult {
        await run(urgent: true) { self.stopNow(s) }
    }

    func stopNow(_ s: ClaudeSession) -> BridgeResult {
        guard let entry = liveEntry(s) else { return .refused(self.sessionNotFound) }
        let mic = entry.elements.mic
        switch micStateSync(mic: mic) {
        case .off:
            return .done
        case .unknown(let why):
            return .refused("mic state unknown, not pressing: \(why)")
        case .on:
            break
        }
        if let since = secondsSinceStopPress(), since < Self.stopCooldown {
            return .refused("a stop press was sent \(String(format: "%.1f", since)) s ago; waiting before pressing again")
        }
        let err = AX.perform(mic, kAXPressAction)
        notePress(stop: true)
        let last = pollMic(mic, until: .off)
        if last == .off { return .done }
        let note = err == .success ? "" : " (press error \(err.rawValue))"
        return .unknown("pressed once; mic not confirmed off, last state \(describe(last))\(note)")
    }

    /// Stops whichever session shows an active mic. Used when the session that started the recording is gone.
    func stopAnyDictation() async -> BridgeResult {
        await run(urgent: true) { self.stopAnyNow() }
    }

    func stopAnyNow() -> BridgeResult {
        var worst: BridgeResult = .done
        var confirmed: [Bool] = []
        for entry in discover() {
            let result = stopNow(entry.session)
            if case .done = result { confirmed.append(true); continue }
            confirmed.append(false)
            worst = result
        }
        if DictationRules.stopAll(paneConfirmedOff: confirmed) == .nothingFound {
            return .refused("no Claude session pane found; nothing pressed")
        }
        return worst
    }

    /// For process exit, where nothing can be awaited: stops on the urgent queue and waits at most `timeout`
    /// seconds. Falls back to any session with an active mic when `s` is nil or its stop is refused.
    /// nil = it did not finish in time.
    func stopDictationBlocking(_ s: ClaudeSession?, timeout: TimeInterval) -> BridgeResult? {
        let finished = DispatchSemaphore(value: 0)
        let box = BlockingResult()
        urgentQueue.async {
            var result: BridgeResult = s.map { self.stopNow($0) } ?? self.stopAnyNow()
            if s != nil, case .refused = result { result = self.stopAnyNow() }
            box.value = result
            finished.signal()
        }
        return finished.wait(timeout: .now() + timeout) == .success ? box.value : nil
    }

    private func pollMic(_ mic: AXUIElement, until target: MicState) -> MicState {
        var last = micStateSync(mic: mic)
        let deadline = Date().addingTimeInterval(Self.confirmWindow)
        while last != target, Date() < deadline {
            Thread.sleep(forTimeInterval: Self.pollInterval)
            last = micStateSync(mic: mic)
        }
        return last
    }

    func describe(_ state: MicState) -> String {
        switch state {
        case .on: return "on"
        case .off: return "off"
        case .unknown(let why): return "unknown (\(why))"
        }
    }
}

/// Written once before its semaphore is signalled and read only after the wait succeeds.
private final class BlockingResult: @unchecked Sendable {
    var value: BridgeResult?
}
