import Foundation

/// When Ensemble looks for a new version and what its one update button says. The trust rule holds here: with
/// automatic updates off nothing is checked until the owner presses the button.
public enum UpdatePolicy {
    /// Automatic updates check this often.
    public static let checkInterval: TimeInterval = 3600
    /// The first automatic check waits this long after launch, so it never competes with the camera starting.
    public static let launchDelay: TimeInterval = 15
    /// "Up to date" stays on the button this long after a check the owner started finds nothing.
    public static let upToDateSeconds: TimeInterval = 4

    /// Whether to check shortly after launch: only with updates set up in this build and turned on by the owner.
    public static func checksAtLaunch(configured: Bool, automatic: Bool) -> Bool { configured && automatic }

    /// The update button's title: the version on offer, a brief "Up to date", or the plain check.
    public static func buttonTitle(available: String?, showingUpToDate: Bool) -> String {
        if let available { return "Update to \(available)" }
        return showingUpToDate ? "Up to date" : "Check for Updates"
    }
}
