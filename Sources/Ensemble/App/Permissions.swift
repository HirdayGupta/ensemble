import AppKit
import AVFoundation

/// Live permission facts and the Settings panes that fix them. Nothing here is cached: grants change while Ensemble runs.
enum Permissions {
    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// False when the user has denied the camera or it is restricted; "not yet asked" counts as allowed.
    static var cameraAllowed: Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted: return false
        default: return true
        }
    }

    /// Shows the system's "would like to control this computer" prompt if Accessibility is not already granted.
    /// Harmless to call again once granted.
    static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    static func openSettings(for what: String) {
        let pane = what == "Camera" ? "Privacy_Camera" : "Privacy_Accessibility"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    /// What to do next, shown under the status. A grant that is listed but does not work is stale after a rebuild.
    static func guidance(for what: String) -> String {
        "Turn Ensemble on in the \(what) list, then press Restart Ensemble. Already on and still stuck? Press Reset, then turn it on again."
    }

    /// Quits and opens Ensemble again so macOS applies a grant made while it ran. Quitting stops any dictation first
    /// (the normal terminate path); a detached shell reopens the same bundle a moment after this process exits.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// A grant that shows on but does not work belongs to an earlier signature of the app (gotcha 1). Clearing
    /// Ensemble's own entry and asking again puts the current app in the list; then a restart applies it.
    static func resetAndAsk(for what: String) {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let service = what == "Camera" ? "Camera" : "Accessibility"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", service, id]
        try? task.run()
        task.waitUntilExit()
        if service == "Accessibility" { requestAccessibility() } else { AVCaptureDevice.requestAccess(for: .video) { _ in } }
        openSettings(for: what)
    }
}
