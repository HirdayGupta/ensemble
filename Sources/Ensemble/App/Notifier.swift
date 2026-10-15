import AppKit
@preconcurrency import UserNotifications

enum SoundCue: String {
    case listenStart = "Tink"
    case listenEnd = "Pop"
    case send = "Glass"
    case refused = "Basso"
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

    func playCue(_ cue: SoundCue) {
        guard settings?.playSounds ?? true else { return }
        NSSound(named: NSSound.Name(cue.rawValue))?.play()
    }

    private func post(title: String, body: String, style: OverlayBanner.Style) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if error != nil { Task { @MainActor in self?.overlay?.showBanner(title: title, body: body, style: style) } }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
