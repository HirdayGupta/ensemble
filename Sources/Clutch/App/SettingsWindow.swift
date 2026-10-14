import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let makeContent: () -> AnyView

    init(content: @escaping () -> AnyView) { makeContent = content }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: makeContent())
            let window = NSWindow(contentViewController: host)
            window.title = "Clutch Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
