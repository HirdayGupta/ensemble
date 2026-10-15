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
        "Turn Ensemble on in the \(what) list. If it is already on but this stays, remove Ensemble with the minus button and add it again."
    }
}
