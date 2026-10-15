import AppKit
@preconcurrency import UserNotifications

enum SoundCue: String {
    case listenStart = "Tink"
    case listenEnd = "Pop"
    case send = "Glass"
    case refused = "Basso"
}

/// The sounds Claude plays when its dictation starts and stops, by their file names in Claude's bundle. Claude
/// plays them only after a real user gesture, so after Ensemble's press Ensemble plays them (docs/gotchas.md, 6).
enum ClaudeDictationSound: String {
    case start = "enter_voice_mode"
    case stop = "exit_voice_mode"

    var fallback: SoundCue { self == .start ? .listenStart : .listenEnd }
}

/// System notification with an in-overlay banner as the fallback (permission denied, or not running as an app bundle).
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    weak var overlay: OverlayController?
    weak var settings: SettingsStore?

    private var delegateInstalled = false
    private var isAppBundle: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    /// Every caller so far reports a problem, so the fallback banner defaults to the warning style.
    func notify(title: String, body: String, style: OverlayBanner.Style = .refused) {
        guard isAppBundle else {
            overlay?.showBanner(title: title, body: body, style: style)
            return
        }
        let center = UNUserNotificationCenter.current()
        if !delegateInstalled {
            center.delegate = self
            delegateInstalled = true
        }
        center.getNotificationSettings { [weak self] current in
            switch current.authorizationStatus {
            case .authorized, .provisional:
                Task { @MainActor in self?.post(title: title, body: body, style: style) }
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    Task { @MainActor [weak self] in
                        if granted { self?.post(title: title, body: body, style: style) } else { self?.overlay?.showBanner(title: title, body: body, style: style) }
                    }
                }
            default:
                Task { @MainActor in self?.overlay?.showBanner(title: title, body: body, style: style) }
            }
        }
    }

    /// The microphone alarm: the on-screen banner is shown at once and stays until `resolveAlarm`, because the
    /// system notification depends on a permission the owner may have refused and on Focus, which hides it.
    func alarm(title: String, body: String) {
        overlay?.showAlarm(title: title, body: body)
        guard isAppBundle else { return }
        let center = UNUserNotificationCenter.current()
        if !delegateInstalled {
            center.delegate = self
            delegateInstalled = true
        }
        center.getNotificationSettings { [weak self] current in
            guard current.authorizationStatus == .authorized || current.authorizationStatus == .provisional else { return }
            Task { @MainActor in self?.addRequest(title: title, body: body) { _ in } }
        }
    }

    func resolveAlarm() { overlay?.resolveAlarm() }

    func playCue(_ cue: SoundCue) {
        guard settings?.playSounds ?? true else { return }
        NSSound(named: NSSound.Name(cue.rawValue))?.play()
    }

    /// Claude's own dictation sound, read from the installed Claude at run time (Anthropic's file is never copied
    /// into Ensemble), or Ensemble's cue when that file is missing.
    func playDictationSound(_ sound: ClaudeDictationSound) {
        guard settings?.playSounds ?? true else { return }
        if let s = claudeSound(sound) { s.stop(); s.play(); return }
        NSSound(named: NSSound.Name(sound.fallback.rawValue))?.play()
    }

    private var claudeSounds: [ClaudeDictationSound: NSSound] = [:]

    private func claudeSound(_ sound: ClaudeDictationSound) -> NSSound? {
        if let s = claudeSounds[sound] { return s }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeLabels.bundleID).first?.bundleURL
        guard let app = running ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: ClaudeLabels.bundleID) else { return nil }
        let url = app.appendingPathComponent("Contents/Resources/ion-dist/audio/voice/sfx/\(sound.rawValue).mp3")
        guard FileManager.default.fileExists(atPath: url.path), let s = NSSound(contentsOf: url, byReference: true) else { return nil }
        claudeSounds[sound] = s
        return s
    }

    private func post(title: String, body: String, style: OverlayBanner.Style) {
        addRequest(title: title, body: body) { [weak self] error in
            if error != nil { Task { @MainActor in self?.overlay?.showBanner(title: title, body: body, style: style) } }
        }
    }

    private func addRequest(title: String, body: String, completion: @escaping @Sendable (Error?) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: completion)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
