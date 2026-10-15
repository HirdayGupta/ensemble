import AppKit
import QuartzCore

/// The nose dot as its own tiny borderless window: a glass bead you can see through. AppKit's Liquid Glass view
/// only samples its own window, so over other apps it renders as an opaque dark disc (measured 2026-10-14);
/// instead a behind-window blur, faded to 60%, softens what is underneath, and a drawn rim and highlight give
/// it the bead's edge. Click-through, never activates, joins every Space. Fades out while the keyboard, mouse
/// or trackpad is in use, on the same curve as the highlight.
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
        p.alphaValue = 0
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let root = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        root.wantsLayer = true
        root.layer?.cornerRadius = size / 2
        root.layer?.masksToBounds = true
        let blur = NSVisualEffectView(frame: root.bounds)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.alphaValue = 0.6
        blur.autoresizingMask = [.width, .height]
        let bead = BeadView(frame: root.bounds)
        bead.autoresizingMask = [.width, .height]
        root.addSubview(blur)
        root.addSubview(bead)
        p.contentView = root
        return p
    }()
    /// The opacity the dot is heading to; an animation runs only when this changes.
    private var target: CGFloat = 0
    /// Head readings arrive about 15 times a second (FrameRatePlanner.faceInterval); jumping the window to each one
    /// reads as a 15 fps dot. The window instead glides toward the latest reading on every screen refresh.
    private var goal: CGPoint?
    private var drawn: CGPoint?
    private var lastTick: CFTimeInterval?
    private var link: CADisplayLink?
    private lazy var ticker = DisplayTicker { [weak self] in self?.tick($0) }
    /// Time constant of the glide: about one head reading, so the dot never trails more than a frame behind.
    private let glide: Double = 0.05

    /// Shows the dot centred on a global top-left point, or hides it when `point` is nil. `dimmed` (hands on the
    /// keyboard or trackpad) fades it away and back over 0.7 s.
    func show(at point: CGPoint?, dimmed: Bool) {
        guard let point else {
            target = 0
            goal = nil; drawn = nil
            stopLink()
            if panel.isVisible { panel.alphaValue = 0; panel.orderOut(nil) }
            return
        }
        goal = point
        if drawn == nil || !panel.isVisible {
            drawn = point
            place(point)
        } else {
            startLink()
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
        let next: CGFloat = dimmed ? 0 : 1
        guard next != target else { return }
        target = next
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.7
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = next
        }
    }

    private func place(_ p: CGPoint) {
        panel.setFrameOrigin(NSPoint(x: p.x - size / 2, y: ScreenGeometry.primaryHeight - p.y - size / 2))
    }

    private func tick(_ now: CFTimeInterval) {
        guard let goal, let from = drawn else { stopLink(); return }
        let dt = min(max(now - (lastTick ?? now - 1.0 / 60), 0), 0.1)
        lastTick = now
        let k = 1 - exp(-dt / glide)
        let next = CGPoint(x: from.x + (goal.x - from.x) * k, y: from.y + (goal.y - from.y) * k)
        if hypot(goal.x - next.x, goal.y - next.y) < 0.25 {
            drawn = goal
            place(goal)
            stopLink()
        } else {
            drawn = next
            place(next)
        }
    }

    private func startLink() {
        guard link == nil else { return }
        lastTick = nil
        let l = (panel.screen ?? NSScreen.main)?.displayLink(target: ticker, selector: #selector(DisplayTicker.fire(_:)))
        l?.add(to: .main, forMode: .common)
        link = l
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        lastTick = nil
    }
}

/// CADisplayLink needs an Objective-C target; this forwards each refresh to the dot.
private final class DisplayTicker: NSObject {
    private let onFire: (CFTimeInterval) -> Void
    init(_ onFire: @escaping (CFTimeInterval) -> Void) { self.onFire = onFire }
    @objc func fire(_ link: CADisplayLink) { onFire(link.targetTimestamp) }
}

/// The bead's edge: a faint fill, a light rim, and a small highlight in the upper left.
private final class BeadView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let b = bounds.insetBy(dx: 0.75, dy: 0.75)
        let circle = NSBezierPath(ovalIn: b)
        NSColor.white.withAlphaComponent(0.08).setFill()
        circle.fill()
        NSColor.white.withAlphaComponent(0.8).setStroke()
        circle.lineWidth = 1
        circle.stroke()
        NSColor.white.withAlphaComponent(0.6).setFill()
        NSBezierPath(ovalIn: NSRect(x: b.minX + b.width * 0.24, y: b.minY + b.height * 0.56,
                                    width: b.width * 0.3, height: b.height * 0.18)).fill()
    }
}
