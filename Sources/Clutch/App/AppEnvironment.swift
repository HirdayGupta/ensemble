import AppKit
import Combine
import SwiftUI
import Carbon.HIToolbox

/// Owns the long-lived objects and wires them together.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let state = AppState()
    let settings = SettingsStore()
    let overlay = OverlayController()
    let notifier = Notifier.shared

    private(set) lazy var coordinator: AppCoordinating = makeCoordinator(state: state, settings: settings, overlay: overlay)
    private(set) lazy var panelActions = PanelActions(
        calibrate: { [weak self] in self?.dismissMenuPanel(); self?.coordinator.calibrate() },
        openSettings: { [weak self] in self?.dismissMenuPanel(); self?.settingsWindow.show() },
        clearAndDisarm: { [weak self] in self?.coordinator.clearAndDisarm() },
        quit: { NSApp.terminate(nil) }
    )
    private(set) lazy var floatingPanel = FloatingPanelController { [unowned self] in
        AnyView(
            MenuPanelView(state: state, settings: settings, actions: floatingActions)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(.white.opacity(0.12)))
        )
    }
    private(set) lazy var settingsWindow = SettingsWindowController { [unowned self] in
        AnyView(SettingsView(state: state, settings: settings, calibrate: { [weak self] in self?.coordinator.calibrate() }))
    }

    private var hotKey: GlobalHotKey?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private var floatingActions: PanelActions {
        PanelActions(
            calibrate: { [weak self] in self?.floatingPanel.hide(); self?.coordinator.calibrate() },
            openSettings: { [weak self] in self?.floatingPanel.hide(); self?.settingsWindow.show() },
            clearAndDisarm: { [weak self] in self?.coordinator.clearAndDisarm() },
            quit: { NSApp.terminate(nil) }
        )
    }

    func start() {
        guard !started else { return }
        started = true

        notifier.overlay = overlay
        notifier.settings = settings
        state.enabled = settings.enabled

        settings.$enabled.removeDuplicates().sink { [weak self] on in self?.state.enabled = on }.store(in: &cancellables)
        state.$enabled.removeDuplicates().sink { [weak self] on in self?.settings.enabled = on }.store(in: &cancellables)
        Publishers.CombineLatest(settings.$showNoseDot, settings.$showHighlight)
            .sink { [weak self] dot, highlight in self?.overlay.setVisibility(showNoseDot: dot, showHighlight: highlight) }
            .store(in: &cancellables)
        settings.$mapping
            .map { "Show \($0.cancel.title.lowercased()) to cancel" }
            .removeDuplicates()
            .sink { [weak self] text in self?.overlay.setCancelHint(text) }
            .store(in: &cancellables)

        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            MainActor.assumeIsolated { self?.floatingPanel.toggle() }
        }

        coordinator.start()
    }

    func stop() {
        coordinator.shutdown()
        CalibrationController.shared.cancel()
    }

    /// Closes the menu-bar panel (a window-style MenuBarExtra stays open after a button press).
    private func dismissMenuPanel() {
        guard let key = NSApp.keyWindow, key is NSPanel else { return }
        key.close()
    }
}
