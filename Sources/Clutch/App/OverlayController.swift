import AppKit
import SwiftUI
import ClutchCore

struct Arrival: Equatable, Identifiable {
    let id = UUID()
    var frame: CGRect
}

struct OverlayBanner: Equatable, Identifiable {
    enum Style: Equatable { case sent, stopped, refused, info }
    let id = UUID()
    var title: String
    var body: String
    var style: Style = .info
}

/// While dictating, the nose rests on another session: focus moves there when `progress` reaches 1.
struct SessionSwitch: Equatable {
    var name: String?
    var progress: Double
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var target: CGRect?
    /// What the SwiftUI views draw. Set only when a view needs it (see `OverlayController.update`), so a moving
    /// nose does not re-evaluate the views while the glass dot window does the drawing.
    @Published var nose: CGPoint?
    var hasNose = false
    @Published var listening = false
    @Published var countdown: Countdown?
    @Published var showNoseDot = true
    @Published var gesture: GestureProgress?
    @Published var showHighlight = true
    @Published var banner: OverlayBanner?
    /// A session just brought forward or switched to: drawn as a soft glow that grows in and fades.
    @Published var arrival: Arrival?
    /// The keyboard, mouse or trackpad is in use: the highlight fades away until they rest.
    @Published var handsOnInput = false
    /// Live voice level 0...1 while listening (0 when unavailable).
    @Published var audioLevel = 0.0
    /// Show live sound bars instead of the blinking microphone dot.
    @Published var liveSoundBars = false
    @Published var cancelHint = "Show an open palm to cancel"
    /// The name of the session a gesture would act on (the dictating one while dictating).
    @Published var sessionName: String?
    @Published var sessionSwitch: SessionSwitch?

    var hasContent: Bool {
        (showHighlight && target != nil) || (showNoseDot && hasNose) || listening || countdown != nil || banner != nil || arrival != nil
    }
}

/// Click-through, non-activating panels (one per screen) that draw the highlight, nose dot, listening
/// border, send countdown and banners. They never take focus or intercept clicks.
@MainActor
final class OverlayController {
    private let model = OverlayModel()
    private var panels: [CGDirectDisplayID: OverlayPanel] = [:]
    private var bannerTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildPanels() }
        }
    }

    func update(target: CGRect?, nose: CGPoint?, listening: Bool, countdown: Countdown?, showNoseDot: Bool, showHighlight: Bool) {
        setIfChanged(&model.target, target)
        latestNose = nose
        model.hasNose = nose != nil
        setIfChanged(&model.listening, listening)
        setIfChanged(&model.nose, listening || !OverlayScreenView.systemGlassDot ? nose : nil)
        setIfChanged(&model.countdown, countdown)
        setIfChanged(&model.showNoseDot, showNoseDot)
        setIfChanged(&model.showHighlight, showHighlight)
        syncPanels()
        syncGlassDot()
    }

    private var latestNose: CGPoint?
    private var glassDotStore: AnyObject?
    /// On macOS 26 the dot is a separate glass window; the SwiftUI overlay skips drawing it there.
    private func syncGlassDot() {
        guard #available(macOS 26.0, *) else { return }
        let dot = (glassDotStore as? GlassDot) ?? GlassDot()
        glassDotStore = dot
        let visible = !model.listening && (model.showNoseDot || model.gesture != nil)
        dot.show(at: visible ? latestNose : nil)
    }

    /// Re-applies visibility toggles between coordinator updates.
    func setGesture(_ g: GestureProgress?) {
        setIfChanged(&model.gesture, g)
        syncGlassDot()
    }

    func setVisibility(showNoseDot: Bool, showHighlight: Bool) {
        setIfChanged(&model.showNoseDot, showNoseDot)
        setIfChanged(&model.showHighlight, showHighlight)
        syncPanels()
        syncGlassDot()
    }

    func setSession(name: String?, switching: SessionSwitch?) {
        setIfChanged(&model.sessionName, name)
        setIfChanged(&model.sessionSwitch, switching)
    }

    func setCancelHint(_ text: String) {
        setIfChanged(&model.cancelHint, text)
    }

    func setLiveSoundBars(_ on: Bool) { setIfChanged(&model.liveSoundBars, on) }

    func setAudioLevel(_ v: Double) {
        model.audioLevel = v
    }

    func setHandsOnInput(_ on: Bool) {
        setIfChanged(&model.handsOnInput, on)
    }

    func flashArrival(_ frame: CGRect) {
        let a = Arrival(frame: frame)
        model.arrival = a
        syncPanels()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, self.model.arrival?.id == a.id else { return }
            self.model.arrival = nil
            self.syncPanels()
        }
    }

    func showBanner(title: String, body: String, style: OverlayBanner.Style = .info, seconds: Double = 5) {
        let banner = OverlayBanner(title: title, body: body, style: style)
        model.banner = banner
        syncPanels()
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.model.banner?.id == banner.id else { return }
            self.model.banner = nil
            self.syncPanels()
        }
    }

    /// A new action starts: an older message must not reappear once that action's own feedback ends.
    func clearBanner() {
        bannerTask?.cancel()
        guard model.banner != nil else { return }
        model.banner = nil
        syncPanels()
    }

    private func setIfChanged<T: Equatable>(_ slot: inout T, _ value: T) {
        if slot != value { slot = value }
    }

    private func syncPanels() {
        if model.hasContent {
            if panels.isEmpty { rebuildPanels() }
            for panel in panels.values where !panel.isVisible { panel.orderFrontRegardless() }
        } else {
            for panel in panels.values where panel.isVisible { panel.orderOut(nil) }
        }
    }

    private func rebuildPanels() {
        for panel in panels.values { panel.orderOut(nil); panel.close() }
        panels.removeAll()
        guard model.hasContent else { return }
        for (index, screen) in NSScreen.screens.enumerated() {
            guard let id = ScreenGeometry.displayID(of: screen) else { continue }
            let panel = OverlayPanel(screen: screen)
            let notchHeight = screen.safeAreaInsets.top
            let notchWidth = notchHeight > 0 ? max(0, screen.frame.width - (screen.auxiliaryTopLeftArea?.width ?? 0) - (screen.auxiliaryTopRightArea?.width ?? 0)) : 0
            let root = OverlayScreenView(model: model, screenFrame: ScreenGeometry.topLeftFrame(of: screen), isPrimary: index == 0,
                                         notch: CGSize(width: notchWidth, height: notchHeight))
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: screen.frame.size)
            panel.contentView = host
            panel.orderFrontRegardless()
            panels[id] = panel
        }
    }
}

private final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
