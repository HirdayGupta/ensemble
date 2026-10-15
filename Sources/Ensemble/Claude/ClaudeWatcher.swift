import AppKit
import ApplicationServices
import EnsembleCore
import Foundation

/// Claude tells Ensemble when its windows and panes change, so the 1 s check reads pane frames and walks the tree only
/// then, instead of reading every frame each second and walking whenever a window moved. Read-only: it registers for
/// notifications and never sets or presses anything. What Claude was measured to post is in docs/gotchas.md, 2.
///
/// Notifications arrive on the main run loop. Each is folded into `ChangeCoalescer`, which calls `onChange` once
/// `ChangeCoalescer.delay` after the first of a burst; the refresh then takes the changes with `take()`.
final class ClaudeWatcher: @unchecked Sendable {
    /// Runs on the main thread when a refresh is due.
    var onChange: (@MainActor () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return changeHandler }
        set { lock.lock(); changeHandler = newValue; lock.unlock() }
    }

    private let lock = NSLock()
    private var changeHandler: (@MainActor () -> Void)?
    private var coalescer = ChangeCoalescer()
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    /// Registrations on single elements, replaced after each walk that found different elements.
    private var registered: [(element: AXUIElement, name: String)] = []
    private var workspaceTokens: [NSObjectProtocol] = []
    /// Registration talks to Claude; its own queue keeps it off the bridge queues that dictation waits on.
    private let queue = DispatchQueue(label: "ensemble.claude.watch", qos: .utility)

    /// On the application: every window's moves and resizes, and windows appearing. Value changes and element
    /// destruction are not taken app-wide: Claude posts a value change for every keystroke in a message box.
    private static let appNotifications = [kAXWindowCreatedNotification, kAXWindowMovedNotification,
                                           kAXWindowResizedNotification, kAXFocusedWindowChangedNotification,
                                           kAXMainWindowChangedNotification, kAXLayoutChangedNotification,
                                           kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]

    /// True while notifications from the running Claude are being received.
    func isObserving(_ pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return observer != nil && observedPID == pid
    }

    /// Launch, quit, activation and Space changes. Called once, on the main thread.
    func startWorkspaceWatch() {
        guard workspaceTokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        func isClaude(_ note: Notification) -> Bool {
            (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == ClaudeLabels.bundleID
        }
        workspaceTokens = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
                if isClaude(n) { self?.noted(.structure) }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                guard isClaude(n), let self else { return }
                self.forget()
                self.noted(.structure)
            },
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                if isClaude(n) { self?.noted(.frames) }
            },
            // A Space change takes windows on or off screen; the window server's list says which.
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.noted(.frames)
            },
        ]
    }

    /// The changes reported since the last call. Called by the refresh on a bridge queue.
    func take() -> ClaudeChanges {
        lock.lock(); defer { lock.unlock() }
        return coalescer.take()
    }

    /// After a walk: watch Claude `pid`'s application element and what the walk found. Windows, panes and checkboxes
    /// report being destroyed (a pane closed); checkboxes and dividers report value changes (a divider moved, which
    /// moves the panes beside it). Registrations are replaced only when the elements differ from the last walk's.
    func watch(pid: pid_t, windows: [AXUIElement], panes: [AXUIElement], mics: [AXUIElement], dividers: [AXUIElement]) {
        queue.async { [self] in
            if !attach(pid) { return }
            var wanted: [(element: AXUIElement, name: String)] = []
            for w in windows + panes { wanted.append((w, kAXUIElementDestroyedNotification)) }
            for e in mics + dividers {
                wanted.append((e, kAXValueChangedNotification))
                wanted.append((e, kAXUIElementDestroyedNotification))
            }
            lock.lock()
            let same = wanted.count == registered.count
                && zip(wanted, registered).allSatisfy { $0.name == $1.name && CFEqual($0.element, $1.element) }
            let old = registered
            let observer = self.observer
            lock.unlock()
            guard !same, let observer else { return }
            for r in old { AXObserverRemoveNotification(observer, r.element, r.name as CFString) }
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            var added: [(element: AXUIElement, name: String)] = []
            for r in wanted where AXObserverAddNotification(observer, r.element, r.name as CFString, refcon) == .success {
                added.append(r)
            }
            lock.lock(); registered = added; lock.unlock()
        }
    }

    /// Claude is not running: drop the observer. Pending changes stay for the refresh that sees Claude gone.
    func forget() { queue.async { self.drop() } }

    private func drop() {
        lock.lock()
        let old = observer
        observer = nil
        observedPID = 0
        registered = []
        lock.unlock()
        if let old { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .commonModes) }
    }

    /// Creates the observer for `pid` (dropping one for an earlier Claude). False when it cannot be created or the
    /// application refuses its notifications; the refresh then reads everything every second, as before.
    private func attach(_ pid: pid_t) -> Bool {
        lock.lock()
        let current = observer != nil && observedPID == pid
        lock.unlock()
        if current { return true }
        drop()
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, name, refcon in
            guard let refcon else { return }
            Unmanaged<ClaudeWatcher>.fromOpaque(refcon).takeUnretainedValue().noted(ClaudeChanges(notification: name as String))
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return false }
        let app = AX.application(pid: pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let accepted = Self.appNotifications.filter {
            AXObserverAddNotification(created, app, $0 as CFString, refcon) == .success
        }
        guard !accepted.isEmpty else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        lock.lock(); observer = created; observedPID = pid; lock.unlock()
        EnsembleLog.write("watching Claude's window changes (\(accepted.count) of \(Self.appNotifications.count) notifications)")
        return true
    }

    private func noted(_ change: ClaudeChanges) {
        lock.lock()
        let schedule = coalescer.note(change)
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + ChangeCoalescer.delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.coalescer.fired()
            let handler = self.changeHandler
            self.lock.unlock()
            MainActor.assumeIsolated { handler?() }
        }
    }
}
