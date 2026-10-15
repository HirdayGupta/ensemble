import AppKit
import SwiftUI

enum SettingsTab: Hashable {
    case general, gestures, display, calibration, about
}

/// Which Settings tab is showing, so the menu panel can open Settings straight at Calibration.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var tab: SettingsTab = .general
}

@MainActor
final class SettingsWindowController {
    let navigation: SettingsNavigation
    private var window: NSWindow?
    private let makeContent: () -> AnyView

    init(navigation: SettingsNavigation, content: @escaping () -> AnyView) {
        self.navigation = navigation
        makeContent = content
    }

    /// `tab`: nil keeps the tab the owner last looked at.
    func show(tab: SettingsTab? = nil) {
        if let tab { navigation.tab = tab }
        if window == nil {
            let host = NSHostingController(rootView: makeContent())
            let window = NSWindow(contentViewController: host)
            window.title = "Ensemble Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
