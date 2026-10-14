import AppKit
import Combine
import SwiftUI

@main
struct ClutchApp: App {
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
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated { AppEnvironment.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppEnvironment.shared.stop() }
    }

    /// Packaging check: prints where SwiftPM's resource bundle resolved and whether the web assets are in it.
    @MainActor private static func printResourcePath() {
        let bundle = ClutchResources.bundle
        let found = bundle.url(forResource: "face_landmarker", withExtension: "task", subdirectory: "Resources/web") != nil
            || bundle.url(forResource: "face_landmarker", withExtension: "task", subdirectory: "web") != nil
        print("resource bundle: \(bundle.bundlePath)")
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
        case .watching, .listening: return .on
        case .cameraCovered, .needsCalibration, .needsPermission, .error: return .attention
        }
    }

    /// The Ensemble dots: three sessions. Hollow when off, filled when on, the top one blue while dictating,
    /// hollow with an exclamation mark when something needs you. Drawn at draw time, so it follows light and
    /// dark menu bars.
    static func render(_ look: Look) -> NSImage {
        let attention = look == .attention
        let size = NSSize(width: attention ? 24 : 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            let r: CGFloat = 3.2
            let centres = [CGPoint(x: 9, y: 5), CGPoint(x: 4.6, y: 12.6), CGPoint(x: 13.4, y: 12.6)]
            for (i, c) in centres.enumerated() {
                let filled = look != .off && !attention
                let rr = filled ? r + 0.3 : r
                let path = NSBezierPath(ovalIn: NSRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
                if case .dictating(let bright) = look, i == 0 {
                    NSColor(Color.clutchBlue).withAlphaComponent(bright ? 1 : 0.4).setFill(); path.fill()
                } else if filled {
                    NSColor.labelColor.setFill(); path.fill()
                } else {
                    NSColor.labelColor.setStroke(); path.lineWidth = 1.3; path.stroke()
                }
            }
            if attention {
                NSColor.labelColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: 20.6, y: 3, width: 2, height: 8.5), xRadius: 1, yRadius: 1).fill()
                NSBezierPath(ovalIn: NSRect(x: 20.5, y: 13, width: 2.2, height: 2.2)).fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Ensemble"
        return image
    }
}
