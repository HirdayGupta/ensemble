import CoreGraphics
import EnsembleCore

/// Where the nose dot sits. While dictating: hidden, and instead the edge warning for the side the nose is
/// leaving by (`edgeWarning`). While a gesture is being held: frozen in place as the gesture bubble. Otherwise: the dot follows the
/// nose whenever it is over a Claude session and the dot setting is on.
@MainActor
final class DotPlacement {
    private let ctx: CoordinatorContext
    /// The drawn dot: follows the filtered nose on a leash so small head wobble never moves it.
    private var dot: CGPoint?
    /// The latest smoothed nose point, wherever it is (also off Claude): drives the edge warning while listening.
    private var lastNose: CGPoint?
    /// While dictating: what the nose is approaching beyond the dictating session's edge.
    private(set) var edgeWarning: EdgeWarning?
    /// Where the gesture bubble sits while a gesture is held or dictation runs; it does not move meanwhile.
    private var frozen: CGPoint?

    init(ctx: CoordinatorContext) { self.ctx = ctx }

    var hasDot: Bool { dot != nil }

    func follow(nose p: CGPoint, onSession: Bool) {
        lastNose = p
        dot = onSession ? NoseDot.follow(dot, nose: p) : nil
    }

    var hasEdgeWarning: Bool { edgeWarning != nil }

    func clear() { dot = nil; lastNose = nil }

    func place(target: ClaudeSession?) {
        if let session = ctx.listening {
            frozen = nil
            ctx.state.set(\.nosePoint, nil)
            let warning = lastNose.flatMap { EdgeWarnings.warning(nose: $0, dictating: session, sessions: ctx.sessions) }
            // Leaving Claude is warned about only when the setting is on; a neighbouring session always is.
            edgeWarning = warning.flatMap { $0.neighbourId == nil && !ctx.settings.warnWhenLeavingClaude ? nil : $0 }
        } else if ctx.gestureShowing {
            edgeWarning = nil
            if frozen == nil { frozen = dot }
            ctx.state.set(\.nosePoint, frozen)
        } else {
            edgeWarning = nil
            frozen = nil
            ctx.state.set(\.nosePoint, ctx.settings.showNoseDot ? dot : nil)
        }
        ctx.state.set(\.targetFrame, ctx.listening?.frame ?? target?.frame)
    }
}

extension DotPlacement {
    /// The warning with everything the overlay draws it from; nil when there is none to show.
    func overlayEdge(focus: FocusController) -> OverlayEdge? {
        guard let w = edgeWarning, let session = ctx.listening, let nose = lastNose else { return nil }
        let neighbour = w.neighbourId.flatMap { id in ctx.sessions.first { $0.id == id } }
        return OverlayEdge(warning: w, nose: nose, dictating: session.frame,
                           neighbourName: neighbour.map { ctx.name(of: $0) }, neighbourFrame: neighbour?.frame,
                           approach: w.neighbourId.flatMap { focus.approach(to: $0) })
    }
}
