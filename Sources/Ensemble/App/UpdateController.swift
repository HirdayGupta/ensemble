import AppKit
import Sparkle
import EnsembleCore

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
/// - Automatic updates (opt-in) check 15 s after launch and then every hour (`UpdatePolicy`), download in the
///   background, and install only while Ensemble is idle: never while Claude is listening, calibrating or the tour is open.
/// - Whatever check finds a new version, the one update button turns into "Update to x.y.z"; no window opens by itself.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// The newer version the last check found, from a check the user started or the automatic checks they turned on.
    @Published private(set) var availableVersion: String?
    /// True for a few seconds after a check the user started found nothing.
    @Published private(set) var showingUpToDate = false
    @Published private(set) var autoInstall = false
    /// True while installing would interrupt the user (dictating, calibrating, tour open); set by the app.
    var isBusy: () -> Bool = { false }
    private var pendingInstall: (() -> Void)?
    private var installTimer: Timer?
    private var userCheckInFlight = false
    private var upToDateTask: Task<Void, Never>?

    /// What the one update button says.
    var buttonTitle: String { UpdatePolicy.buttonTitle(available: availableVersion, showingUpToDate: showingUpToDate) }

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
        if autoInstall { updater.updateCheckInterval = UpdatePolicy.checkInterval }
        if UpdatePolicy.checksAtLaunch(configured: isConfigured, automatic: autoInstall) {
            // Sparkle's own schedule counts a full interval from the last check; this shows a new version soon after launch.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(UpdatePolicy.launchDelay * 1_000_000_000))
                guard let self, self.autoInstall else { return }
                self.controller.updater.checkForUpdatesInBackground()
            }
        }
    }

    func setAutoInstall(_ on: Bool) {
        guard isConfigured else { return }
        let updater = controller.updater
        updater.updateCheckInterval = UpdatePolicy.checkInterval
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
                guard let self, self.pendingInstall != nil, !self.isBusy() else { return }
                EnsembleLog.write("installing a downloaded update while idle")
                self.installPending()
            }
        }
    }

    private func installPending() {
        installTimer?.invalidate()
        installTimer = nil
        let install = pendingInstall
        pendingInstall = nil
        install?()
    }

    /// The update button: installs a version already downloaded in the background, or checks (which offers a found
    /// version in Sparkle's window).
    func checkForUpdates() {
        guard isConfigured else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Updates are not set up in this build"
            alert.informativeText = "This build has no update feed. Download the latest Ensemble from the project's GitHub releases page."
            alert.runModal()
            return
        }
        if pendingInstall != nil, !isBusy() {
            EnsembleLog.write("installing a downloaded update on the user's press")
            installPending()
            return
        }
        userCheckInFlight = true
        // Ensemble is a menu bar app with no Dock icon, so Sparkle's window opens behind other apps unless Ensemble
        // is made active first; the press then looks like it did nothing.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    private func found(_ version: String) {
        upToDateTask?.cancel()
        showingUpToDate = false
        availableVersion = version
    }

    private func foundNothing() {
        availableVersion = nil
        guard userCheckInFlight else { return }
        userCheckInFlight = false
        showingUpToDate = true
        upToDateTask?.cancel()
        upToDateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(UpdatePolicy.upToDateSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.showingUpToDate = false
        }
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? { UpdateConfig.feedURL }

    nonisolated func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    /// Every check reports here, background ones included, so the button changes without the user pressing it.
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in self.found(version) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.foundNothing() }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        Task { @MainActor in self.userCheckInFlight = false }
    }

    /// Skipping the version takes it off the button; "Later" keeps it there.
    nonisolated func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        guard choice == .skip else { return }
        Task { @MainActor in self.availableVersion = nil }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        Task { @MainActor in
            self.found(version)
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
        Task { @MainActor in
            self.found(version)
            // Sparkle's documented pattern for menu bar apps: while its window is up, Ensemble takes a Dock icon and
            // comes to the front, so the window can't be lost behind other apps and Command-Tab finds it.
            if handleShowingUpdate {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in NSApp.setActivationPolicy(.accessory) }
    }
}
