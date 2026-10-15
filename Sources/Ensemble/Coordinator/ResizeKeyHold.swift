import AppKit
import EnsembleCore

/// Holds back the owner's keys while a pane resize may have a divider holding Claude's keyboard, so an arrow, Home
/// or End typed then never moves a divider and no letter lands on one (`ResizeKeys`). On only from the moment a
/// divider is asked to take the keyboard until the resize has put the keyboard back; the keys it held go out again
/// afterwards, in order. Ensemble's own divider keys carry `ownTag` and pass. Nothing about a key is logged. If the
/// watch cannot be created, the hardware-input check before every divider key still stops the resize.
@MainActor
final class ResizeKeyHold {
    /// Set on every key Ensemble posts for a resize, and on the held keys it posts again.
    nonisolated static let ownTag: Int64 = 0x456E_7365_6D62

    /// A key was held back: the resize stops.
    var onHeld: () -> Void = {}

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var failed = false
    private var active = false
    private var held: [CGEvent] = []

    func begin() {
        guard !active else { return }
        active = true
        held = []
        if tap == nil, !failed { create() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Stops holding and hands back what was held, oldest first.
    func finish() -> [CGEvent] {
        guard active else { return [] }
        active = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        defer { held = [] }
        return held
    }

    /// Posts held keys again to the app in front, tagged so a later resize's watch lets them pass.
    static func repost(_ events: [CGEvent]) {
        for event in events {
            event.setIntegerValueField(.eventSourceUserData, value: ownTag)
            event.post(tap: .cgSessionEventTap)
        }
    }

    private func create() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<ResizeKeyHold>.fromOpaque(info).takeUnretainedValue()
            // The source is on the main run loop, so this runs on the main thread.
            let keep = MainActor.assumeIsolated { me.handle(type: type, event: event) }
            return keep ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            failed = true
            EnsembleLog.write("pane widths: key hold unavailable; the hardware-input check alone stops a resize")
            return
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Keys may have gone by unseen; the hardware-input check before every divider key stops the resize.
            if active, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .keyDown, .keyUp:
            let own = event.getIntegerValueField(.eventSourceUserData) == Self.ownTag
            guard ResizeKeys.holds(resizing: active, ownKey: own), let copy = event.copy() else { return false }
            held.append(copy)
            if type == .keyDown { onHeld() }
            return true
        default:
            return false
        }
    }
}
