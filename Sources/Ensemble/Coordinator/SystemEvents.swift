import AppKit
import EnsembleCore

/// The Mac's own events that matter to Ensemble: sleep and lock end a dictation at once, a wake or a Claude
/// launch triggers the safety sweep, and a change of screens invalidates the calibration.
@MainActor
enum SystemEvents {
    static func observe(interrupt: @escaping @MainActor (String) -> Void,
                        sweep: @escaping @MainActor () -> Void,
                        screensChanged: @escaping @MainActor () -> Void) {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { interrupt("system: \(note.name.rawValue)") }
            }
        }
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { interrupt("screen locked") }
            }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { sweep() }
        }
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier?.hasPrefix("com.anthropic.claudefordesktop") == true else { return }
            MainActor.assumeIsolated { EnsembleLog.write("Claude launched; sweeping"); sweep() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { screensChanged() }
        }
    }
}
