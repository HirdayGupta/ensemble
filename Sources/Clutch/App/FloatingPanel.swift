import AppKit
import SwiftUI

/// The hotkey's version of the menu-bar panel: a small floating glass panel with the same controls.
/// Esc, a click elsewhere, or the hotkey again closes it.
@MainActor
final class FloatingPanelController {
    private var panel: FloatingPanel?
    private let makeContent: () -> AnyView

    init(content: @escaping () -> AnyView) { makeContent = content }

    var isShown: Bool { panel?.isVisible ?? false }

    func toggle() { isShown ? hide() : show() }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: makeContent())
        panel.contentView = host
        let size = host.fittingSize
        panel.setContentSize(size)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - 12))
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel { [weak self] in self?.hide() }
        return panel
    }
}

private final class FloatingPanel: NSPanel {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onClose()
    }

    override func cancelOperation(_ sender: Any?) { onClose() }
}
