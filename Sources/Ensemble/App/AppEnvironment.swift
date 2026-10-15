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
    let updates = UpdateController()

    private(set) lazy var coordinator: AppCoordinating = makeCoordinator(state: state, settings: settings, overlay: overlay)
    private(set) lazy var panelActions = PanelActions(
        calibrate: { [weak self] in self?.dismissMenuPanel(); self?.coordinator.calibrate() },
        openSettings: { [weak self] in self?.dismissMenuPanel(); self?.settingsWindow.show() },
        checkForUpdates: { [weak self] in self?.dismissMenuPanel(); self?.updates.checkForUpdates() },
        startTour: { [weak self] in self?.dismissMenuPanel(); self?.tourWindow.show() },
        dismissTourBanner: { [weak self] in self?.settings.tourSkipped = true },
        quit: { NSApp.terminate(nil) }
    )
    private(set) lazy var tourWindow: TourWindowController = {
        let controller = TourWindowController(state: state, settings: settings) { [unowned self] step, singleStep, close in
        TourModel(
            settings: settings, startAt: step, singleStep: singleStep,
            calibrate: { [weak self] in self?.coordinator.calibrate() },
            requestAccessibility: { Permissions.requestAccessibility() },
            enterPractice: { [weak self] sink in self?.coordinator.enterGesturePractice(sink) },
            exitPractice: { [weak self] in self?.coordinator.exitGesturePractice() },
            close: close)
        }
        controller.onOpen = { [weak self] in self?.coordinator.enterTour() }
        controller.onClose = { [weak self] in self?.coordinator.exitTour() }
        return controller
    }()
    private(set) lazy var floatingPanel = FloatingPanelController { [unowned self] in
        AnyView(
            MenuPanelView(state: state, settings: settings, updates: updates, actions: floatingActions)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(.white.opacity(0.12)))
        )
    }
    private(set) lazy var settingsWindow = SettingsWindowController { [unowned self] in
        AnyView(SettingsView(state: state, settings: settings, updates: updates,
                              calibrate: { [weak self] in self?.coordinator.calibrate() },
                              replayTour: { [weak self] step in
                                  if let step { self?.tourWindow.show(startAt: step, singleStep: true) } else { self?.tourWindow.show() }
                              }))
    }

    private var hotKey: GlobalHotKey?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private var floatingActions: PanelActions {
        PanelActions(
            calibrate: { [weak self] in self?.floatingPanel.hide(); self?.coordinator.calibrate() },
            openSettings: { [weak self] in self?.floatingPanel.hide(); self?.settingsWindow.show() },
            checkForUpdates: { [weak self] in self?.floatingPanel.hide(); self?.updates.checkForUpdates() },
            startTour: { [weak self] in self?.floatingPanel.hide(); self?.tourWindow.show() },
            dismissTourBanner: { [weak self] in self?.settings.tourSkipped = true },
            quit: { NSApp.terminate(nil) }
        )
    }

    func start() {
        updates.isBusy = { [weak self] in
            guard let self else { return true }
            return self.state.listening || self.state.calibrating || self.tourWindow.isShown
        }
        guard !started else { return }
        started = true

        notifier.overlay = overlay
        notifier.settings = settings

        Publishers.CombineLatest(settings.$showNoseDot, settings.$showHighlight)
            .sink { [weak self] dot, highlight in self?.overlay.setVisibility(showNoseDot: dot, showHighlight: highlight) }
            .store(in: &cancellables)

        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            MainActor.assumeIsolated { self?.floatingPanel.toggle() }
        }

        coordinator.start()

        if !settings.tourCompleted && !settings.tourSkipped { tourWindow.show() }
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
