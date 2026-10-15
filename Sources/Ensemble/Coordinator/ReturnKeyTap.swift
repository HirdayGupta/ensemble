import AppKit
import EnsembleCore

/// Watches key presses only while the Coordinator asks (an Ensemble dictation, and a moment after it), and lets the
/// Coordinator keep a Return from Claude. Every other key, and every key while it is off, passes untouched. It fails
/// open: if macOS disables the watch it is switched back on, and if it cannot be created the feature is simply off.
/// Nothing about a key is logged except that it was Return.
@MainActor
final class ReturnKeyTap {
    /// Return (36) and keypad Enter (76).
    private static let returnCodes: Set<Int64> = [36, 76]
    private static let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]

    /// Answers true to keep the key from Claude. Called on the main thread.
    var onKey: (_ isReturn: Bool, _ modified: Bool, _ isRepeat: Bool) -> Bool = { _, _, _ in false }
    /// macOS turned the watch off for a while; keys may have gone by unseen.
    var onUnseenKeys: () -> Void = {}
    /// Return was released.
    var onReturnUp: () -> Void = {}

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var failed = false
    private var wanted = false

    /// Turns the watch on or off. Created on first use; when creation fails it stays off for this run.
    func setActive(_ on: Bool) {
        guard on != wanted else { return }
        wanted = on
        if on, tap == nil, !failed { create() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: on) }
    }

    private func create() {
        // Key up too, so a held Return's repeats stay kept from Claude until it is released.
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<ReturnKeyTap>.fromOpaque(info).takeUnretainedValue()
            // The source is on the main run loop, so this runs on the main thread.
            let keep = MainActor.assumeIsolated { me.handle(type: type, event: event) }
            return keep ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            failed = true
            EnsembleLog.write("Return key watch unavailable; Return keeps its normal behaviour while dictating")
            return
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Switching the watch off ourselves arrives here too; that hid no key and must not count as typing.
            guard ReturnKeys.pauseMeansUnseenKeys(watchWanted: wanted) else { return false }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            EnsembleLog.write("Return key watch was paused by macOS; switched back on")
            onUnseenKeys()
            return false
        case .keyDown:
            guard wanted else { return false }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let isReturn = Self.returnCodes.contains(code)
            let modified = !event.flags.intersection(Self.modifiers).isEmpty
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            return onKey(isReturn, modified, isRepeat)
        case .keyUp:
            if wanted, Self.returnCodes.contains(event.getIntegerValueField(.keyboardEventKeycode)) { onReturnUp() }
            return false
        default:
            return false
        }
    }
}
