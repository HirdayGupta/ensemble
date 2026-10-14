import AppKit

/// The nose dot as its own tiny borderless window holding AppKit's Liquid Glass view. The system glass needs
/// a window of its own to sample what is behind it; drawn inside the full-screen transparent overlay it
/// renders as a dark disc. Click-through, never activates, joins every Space.
@available(macOS 26.0, *)
@MainActor
final class GlassDot {
    private let size: CGFloat = 18
    private lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        glass.style = .regular
        glass.cornerRadius = size / 2
        glass.autoresizingMask = [.width, .height]
        p.contentView = glass
        return p
    }()

    /// Shows the dot centred on a global top-left point, or hides it when `point` is nil.
    func show(at point: CGPoint?) {
        guard let point else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        let origin = NSPoint(x: point.x - size / 2, y: ScreenGeometry.primaryHeight - point.y - size / 2)
        panel.setFrameOrigin(origin)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}
