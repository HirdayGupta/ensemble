import AppKit
import SwiftUI
import EnsembleCore

/// The tour's own window: a fixed-size glass panel centred on the main screen, independent of the menu-bar
/// panel and the Settings window. Closing it any way other than Skip or Done (the red button, Esc, Cmd-W)
/// counts as Skip.
@MainActor
final class TourWindowController {
    private var window: NSWindow?
    private var model: TourModel?
    private var closeObserver: NSObjectProtocol?
    private let state: AppState
    private let settings: SettingsStore
    private let makeModel: (TourStep, Bool, @escaping () -> Void) -> TourModel
    /// Called as the window opens and after it closes, so Ensemble pauses its actions on Claude meanwhile.
    var onOpen: () -> Void = {}
    var onClose: () -> Void = {}

    /// `makeModel` builds a fresh `TourModel` each time the tour opens, given the requested start step, whether
    /// this is a single-step replay, and the `close` callback to hand it.
    init(state: AppState, settings: SettingsStore, makeModel: @escaping (TourStep, Bool, @escaping () -> Void) -> TourModel) {
        self.state = state
        self.settings = settings
        self.makeModel = makeModel
    }

    var isShown: Bool { window?.isVisible ?? false }

    /// Opens the tour. A tour already open is replaced (torn down without counting as Skip, then reopened at
    /// the requested step) rather than left running with stale practice state.
    func show(startAt step: TourStep = .welcome, singleStep: Bool = false) {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        window?.close()
        window = nil
        model = nil

        let model = makeModel(step, singleStep) { [weak self] in self?.close() }
        self.model = model

        let size = NSSize(width: 760, height: 620)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2)
        let window = NSWindow(contentRect: NSRect(origin: origin, size: size),
                               styleMask: [.titled, .closable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        window.title = "Ensemble Tour"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false

        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.frame = NSRect(origin: .zero, size: size)
        let host = NSHostingView(rootView: TourView(model: model, state: state, settings: settings))
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)
        window.contentView = glass
        self.window = window

        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWindowWillClose() }
        }

        onOpen()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    private func handleWindowWillClose() {
        model?.windowWillClose()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        window = nil
        model = nil
        onClose()
    }
}
