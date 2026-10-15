import AppKit
import Sparkle

/// Release-channel settings. The owner edits this file and Info.plist (SUPublicEDKey) once; see docs/RELEASING.md.
enum UpdateConfig {
    static let feedURL = "https://oficiallyakshay.github.io/ensemble/appcast.xml"

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
/// - No network until the user turns on automatic updates (Settings > General) or presses Check for Updates.
/// - Sparkle's own "check automatically?" prompt is suppressed, so no window appears at login or mid-dictation.
/// - Automatic updates (opt-in) check every 6 hours (SUScheduledCheckInterval), download in the background, and
///   install only while Ensemble is idle: never while Claude is listening, calibrating or the tour is open.
/// - Without them, a check that finds an update never opens a window; it changes the menu entry to "Update to x.y.z...".
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @Published private(set) var availableVersion: String?
    /// What the last check found: "Ensemble 0.5.0 is available" or "Up to date". Nil until a check has finished;
    /// the latest version is only ever known from a check the user started or automatic checks they turned on.
    @Published private(set) var checkResult: String?
    @Published private(set) var autoInstall = false
    /// True while installing would interrupt the user (dictating, calibrating, tour open); set by the app.
    var isBusy: () -> Bool = { false }
    static let checkInterval: TimeInterval = 6 * 3600
    private var pendingInstall: (() -> Void)?
    private var installTimer: Timer?

    /// The installed version, read from the bundle (no network): "Version 0.4.2 (42)".
    static var installedVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Version \(short) (\(build))"
    }

    private var controller: SPUStandardUpdaterController!
    let isConfigured = UpdateConfig.isConfigured

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: isConfigured, updaterDelegate: self, userDriverDelegate: self)
        let updater = controller.updater
        autoInstall = isConfigured && updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
        if autoInstall { updater.updateCheckInterval = Self.checkInterval }
    }

    func setAutoInstall(_ on: Bool) {
        guard isConfigured else { return }
        let updater = controller.updater
        updater.updateCheckInterval = Self.checkInterval
        updater.automaticallyChecksForUpdates = on
        updater.automaticallyDownloadsUpdates = on
        autoInstall = on
        if on { updater.checkForUpdatesInBackground() }
    }

    /// A downloaded update installs at the first idle moment, checked every 30 s; Sparkle then relaunches Ensemble.
    private func installWhenIdle() {
        installTimer?.invalidate()
        installTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let install = self.pendingInstall, !self.isBusy() else { return }
                self.installTimer?.invalidate()
                self.installTimer = nil
                self.pendingInstall = nil
                EnsembleLog.write("installing a downloaded update while idle")
                install()
            }
        }
    }

    func checkForUpdates() {
        guard isConfigured else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Updates are not set up in this build"
            alert.informativeText = "This build has no update feed. Download the latest Ensemble from the project's GitHub releases page."
            alert.runModal()
            return
        }
        controller.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? { UpdateConfig.feedURL }

    nonisolated func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in self.checkResult = "Ensemble \(version) is available" }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.checkResult = "Up to date" }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        Task { @MainActor in
            self.pendingInstall = immediateInstallationBlock
            self.installWhenIdle()
        }
        return true
    }

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
