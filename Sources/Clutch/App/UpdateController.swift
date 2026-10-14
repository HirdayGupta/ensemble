import AppKit
import Sparkle

/// Release-channel settings. The owner edits this file and Info.plist (SUPublicEDKey) once; see docs/RELEASING.md.
enum UpdateConfig {
    // TODO(owner): replace OWNER/REPO with the GitHub account and repository that publishes the appcast.
    static let feedURL = "https://OWNER.github.io/REPO/appcast.xml"

    /// Placeholder shipped in Info.plist until the owner generates a key with Sparkle's generate_keys.
    static let publicKeyPlaceholder = "TODO-REPLACE-WITH-SPARKLE-PUBLIC-ED-KEY"

    /// Sparkle refuses to start without a valid EdDSA public key, so a build without a real key and feed has updates off.
    static var isConfigured: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              key != publicKeyPlaceholder, Data(base64Encoded: key)?.count == 32 else { return false }
        return !feedURL.contains("OWNER")
    }
}

/// Sparkle 2 wrapper. Policy, in order of what matters for a tool that drives dictation:
/// - No network until the user turns on automatic checks (About tab) or presses Check for Updates.
/// - Sparkle's own "check automatically?" prompt is suppressed, so no window appears at login or mid-dictation.
/// - A scheduled check that finds an update never opens a window; it only changes the menu entry to "Update to x.y.z...".
/// - With automatic checks on, Sparkle checks at most once a day (SUScheduledCheckInterval).
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @Published private(set) var availableVersion: String?
    @Published private(set) var automaticChecks = false

    private var controller: SPUStandardUpdaterController!
    let isConfigured = UpdateConfig.isConfigured

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: isConfigured, updaterDelegate: self, userDriverDelegate: self)
        automaticChecks = isConfigured && controller.updater.automaticallyChecksForUpdates
    }

    func setAutomaticChecks(_ on: Bool) {
        guard isConfigured else { return }
        controller.updater.automaticallyChecksForUpdates = on
        automaticChecks = on
    }

    func checkForUpdates() {
        guard isConfigured else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Updates are not set up in this build"
            alert.informativeText = "This build has no update feed. Download the latest Clutch from the project's GitHub releases page."
            alert.runModal()
            return
        }
        controller.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? { UpdateConfig.feedURL }

    nonisolated func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    // MARK: SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        Task { @MainActor in self.availableVersion = version }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in self.availableVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.availableVersion = nil }
    }
}
