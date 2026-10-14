import CoreGraphics
import EnsembleCore

/// Where the nose dot sits. While dictating: hidden, except near the session's edges (where you may be looking
/// away). While a gesture is being held: frozen in place as the gesture bubble. Otherwise: the dot follows the
/// nose whenever it is over a Claude session and the dot setting is on.
@MainActor
final class DotPlacement {
    private let ctx: CoordinatorContext
    /// The drawn dot: follows the filtered nose on a leash so small head wobble never moves it.
    private var dot: CGPoint?
    /// The latest smoothed nose point, wherever it is (also off Claude): drives the edge marker while listening.
    private var lastNose: CGPoint?
    /// Where the gesture bubble sits while a gesture is held or dictation runs; it does not move meanwhile.
    private var frozen: CGPoint?

    init(ctx: CoordinatorContext) { self.ctx = ctx }

    var hasDot: Bool { dot != nil }

    func follow(nose p: CGPoint, onSession: Bool) {
        lastNose = p
        dot = onSession ? NoseDot.follow(dot, nose: p) : nil
    }

    func clear() { dot = nil }

    func place(target: ClaudeSession?) {
        if let session = ctx.listening {
            frozen = nil
            if let d = lastNose {
                let inner = session.frame.insetBy(dx: session.frame.width * 0.15, dy: session.frame.height * 0.15)
                ctx.state.set(\.nosePoint, inner.contains(d) ? nil : d)
            } else {
                ctx.state.set(\.nosePoint, nil)
            }
        } else if ctx.gestureShowing {
            if frozen == nil { frozen = dot }
            ctx.state.set(\.nosePoint, frozen)
        } else {
            frozen = nil
            ctx.state.set(\.nosePoint, ctx.settings.showNoseDot ? dot : nil)
        }
        ctx.state.set(\.targetFrame, ctx.listening?.frame ?? target?.frame)
    }
}
