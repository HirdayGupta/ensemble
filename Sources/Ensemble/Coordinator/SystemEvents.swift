import AppKit
import EnsembleCore

/// The Mac's own events that matter to Ensemble: sleep and lock end a dictation at once and switch the camera off
/// until you are back, a wake or a Claude launch triggers the safety sweep, and a change of screens invalidates
/// the calibration.
@MainActor
enum SystemEvents {
    /// `away`: each reason is set by its own "going" notification and cleared by the matching "back" one.
    static func observe(interrupt: @escaping @MainActor (String) -> Void,
                        away: @escaping @MainActor (AwayReason, Bool) -> Void,
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
        let workspacePairs: [(NSNotification.Name, AwayReason, Bool)] = [
            (NSWorkspace.willSleepNotification, .systemSleep, true), (NSWorkspace.didWakeNotification, .systemSleep, false),
            (NSWorkspace.screensDidSleepNotification, .displaySleep, true), (NSWorkspace.screensDidWakeNotification, .displaySleep, false),
            (NSWorkspace.sessionDidResignActiveNotification, .session, true), (NSWorkspace.sessionDidBecomeActiveNotification, .session, false),
        ]
        for (name, reason, on) in workspacePairs {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { away(reason, on) }
            }
        }
        let distributedPairs: [(String, AwayReason, Bool)] = [
            ("com.apple.screenIsLocked", .locked, true), ("com.apple.screenIsUnlocked", .locked, false),
            ("com.apple.screensaver.didstart", .screenSaver, true), ("com.apple.screensaver.didstop", .screenSaver, false),
        ]
        for (name, reason, on) in distributedPairs {
            DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { away(reason, on) }
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
