import AppKit
import Combine
import SwiftUI

@main
struct ClutchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let env = AppEnvironment.shared
    @StateObject private var icon = StatusIconModel(state: AppEnvironment.shared.state)

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView(state: env.state, settings: env.settings, actions: env.panelActions)
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
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.clutch.app")
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
@MainActor
final class StatusIconModel: ObservableObject {
    @Published private(set) var image = StatusIconModel.render(status: .off, listening: false)
    private var cancellable: AnyCancellable?

    init(state: AppState) {
        cancellable = Publishers.CombineLatest3(state.$status, state.$listening, state.$enabled)
            .map { status, listening, enabled in (enabled ? status : .off, listening && enabled) }
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] status, listening in
                self?.image = Self.render(status: status, listening: listening)
            }
    }

    /// A drawing-handler image resolves colours at draw time, so it follows light/dark menu bars even though
    /// it is not a template (a template could not carry the red dot).
    private static func render(status: AppStatus, listening: Bool) -> NSImage {
        let symbol = NSImage(systemSymbolName: status.symbolName, accessibilityDescription: "Clutch")
            ?? NSImage(systemSymbolName: "hand.raised", accessibilityDescription: "Clutch")
        let configured = symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let configured else { return false }
            let tinted = configured.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
            let glyph = tinted ?? configured
            let glyphSize = glyph.size
            glyph.draw(in: NSRect(x: (rect.width - glyphSize.width) / 2, y: (rect.height - glyphSize.height) / 2,
                                  width: glyphSize.width, height: glyphSize.height))
            if listening {
                let dot = NSRect(x: rect.width - 8, y: rect.height - 8, width: 7, height: 7)
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Clutch: \(status.title)"
        return image
    }
}
