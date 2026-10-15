import Foundation

/// Camera access as the tour and the permission cards show it. "Not asked" is its own state: it is neither
/// granted nor a refusal, and only here does pressing a button make macOS show its prompt.
public enum CameraAccess: Equatable, Sendable {
    case notAsked, denied, granted

    public var isGranted: Bool { self == .granted }
}

/// First launch must not stack macOS permission prompts on top of the tour's Welcome step.
public enum FirstRunGate {
    /// True while the tour is still owed to a new owner: Ensemble then waits to start the camera and to ask for
    /// Accessibility until the tour reaches a step that needs them, or is skipped or closed.
    public static func shouldDeferStart(tourCompleted: Bool, tourSkipped: Bool) -> Bool {
        !tourCompleted && !tourSkipped
    }

    /// Welcome only explains; every later step uses the camera, so the first move off Welcome starts it.
    public static func stepNeedsCoordinator(_ step: TourStep) -> Bool {
        step != .welcome
    }
}

/// Where the running copy of Ensemble sits. A copy opened straight from the disk image, or from Downloads,
/// runs from a temporary path (App Translocation) or a read-only volume: the open-at-login file would record a
/// path that disappears, and Sparkle cannot replace the app.
public enum InstallLocation {
    /// A path the app will not stay at, or cannot update itself in.
    public static func isTemporary(bundlePath: String, home: String) -> Bool {
        guard bundlePath.hasSuffix(".app"), !bundlePath.contains("/.build/") else { return false }
        if bundlePath.contains("/AppTranslocation/") { return true }
        if bundlePath.hasPrefix("/Volumes/") { return true }
        let downloads = home.hasSuffix("/") ? home + "Downloads/" : home + "/Downloads/"
        return bundlePath.hasPrefix(downloads)
    }

    /// The message shown when open-at-login is refused, and the line under the move offer.
    public static let explanation = "Ensemble is running from the disk image or Downloads. Move it to Applications first, or open at login would point at a place that goes away and updates could not install."
}
