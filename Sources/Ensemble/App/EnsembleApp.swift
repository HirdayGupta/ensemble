import AppKit
import Combine
import SwiftUI

@main
struct EnsembleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let env = AppEnvironment.shared
    @StateObject private var icon = StatusIconModel(state: AppEnvironment.shared.state, settings: AppEnvironment.shared.settings)

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView(state: env.state, settings: env.settings, updates: env.updates, actions: env.panelActions)
        } label: {
            Image(nsImage: icon.image)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--print-resource-path") {
            MainActor.assumeIsolated { Self.printResourcePath() }
            exit(0)
        }
        // One copy only: a second launch (e.g. login agent plus a manual open) exits cleanly.
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.ensemble.app")
            .contains(where: { $0.processIdentifier != me.processIdentifier }) {
            exit(0)
        }
        // The copy Sparkle opened after an update, with open at login on: quit before the camera starts and let
        // launchd start its own job, so crash restarts keep working.
        if MainActor.assumeIsolated({ UpdateController.afterLaunch() }) {
            Permissions.reopenAfterExit()
            EnsembleLog.flush()
            exit(0)
        }
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated { AppEnvironment.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppEnvironment.shared.stop() }
    }

    /// Packaging check: prints where the web folder resolved and whether the face model is in it (packed or not).
    @MainActor private static func printResourcePath() {
        let web = EnsembleResources.web
        let found = ["face_landmarker.task", "face_landmarker.task.lzma"].contains { name in
            web.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) } ?? false
        }
        print("web folder: \(web?.path ?? "none")")
        print("face_landmarker.task found: \(found)")
    }
}

/// Re-renders the menu-bar icon only when the status or listening flag changes, not on every coordinator tick.
/// While dictating, the lit dot pulses once a second.
@MainActor
final class StatusIconModel: ObservableObject {
    @Published private(set) var image = StatusIconModel.render(.off)
    private var cancellable: AnyCancellable?
    private var pulse: Timer?

    init(state: AppState, settings: SettingsStore) {
        cancellable = Publishers.CombineLatest3(state.$status, state.$listening, settings.$enabled)
            .map { status, listening, enabled in (enabled ? status : .off, listening && enabled) }
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] status, listening in self?.show(status: status, listening: listening) }
    }

    private func show(status: AppStatus, listening: Bool) {
        pulse?.invalidate(); pulse = nil
        guard listening else { image = Self.render(Self.look(status)); return }
        let bright = Self.render(.dictating(bright: true)), dim = Self.render(.dictating(bright: false))
        image = bright
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.image = self.image === bright ? dim : bright }
        }
        RunLoop.main.add(t, forMode: .common)
        pulse = t
    }

    enum Look: Equatable { case off, on, attention, dictating(bright: Bool) }

    static func look(_ status: AppStatus) -> Look {
        switch status {
        case .off, .claudeNotRunning: return .off
        case .watching, .pausedForInput, .listening, .claudeNotOnScreen: return .on
        case .cameraCovered, .needsCalibration, .needsPermission, .error: return .attention
        }
    }

    /// The Ensemble dots: three sessions. Hollow when off, filled when on, the top one blue while dictating,
    /// hollow with an exclamation mark when something needs you. Drawn at draw time, so it follows light and
    /// dark menu bars.
    static func render(_ look: Look) -> NSImage {
        let attention = look == .attention
        let size = NSSize(width: attention ? 20 : 16, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            // A small, airy formation: 70% of a full glyph, dots a further 10% smaller.
            let r: CGFloat = 2.0
            let centres = [CGPoint(x: 8, y: 6.2), CGPoint(x: 4.9, y: 11.5), CGPoint(x: 11.1, y: 11.5)]
            for (i, c) in centres.enumerated() {
                let filled = look != .off && !attention
                let rr = filled ? r + 0.2 : r
                let path = NSBezierPath(ovalIn: NSRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
                if case .dictating(let bright) = look, i == 0 {
                    NSColor(Color.ensembleBlue).withAlphaComponent(bright ? 1 : 0.4).setFill(); path.fill()
                } else if filled {
                    NSColor.labelColor.setFill(); path.fill()
                } else {
                    NSColor.labelColor.setStroke(); path.lineWidth = 1.0; path.stroke()
                }
            }
            if attention {
                NSColor.labelColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: 16.4, y: 4.8, width: 1.6, height: 6), xRadius: 0.8, yRadius: 0.8).fill()
                NSBezierPath(ovalIn: NSRect(x: 16.3, y: 12.2, width: 1.8, height: 1.8)).fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Ensemble"
        return image
    }
}
