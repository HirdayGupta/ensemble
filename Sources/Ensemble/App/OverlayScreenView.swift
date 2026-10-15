import SwiftUI
import EnsembleCore

/// Draws one screen's share of the overlay. Coordinates are global top-left; `screenFrame` is this screen's
/// frame in that same space, so local = global - screenFrame.origin.
struct OverlayScreenView: View {
    @ObservedObject var model: OverlayModel
    let screenFrame: CGRect
    let isPrimary: Bool
    /// The camera housing on notched displays (zero elsewhere): the island grows out of it, never under it.
    var notch: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.showHighlight || model.listening, let target = model.target, let local = local(target) {
                // Switching sessions cross-fades in place (the old outline dissolves, the new one condenses on
                // its window) instead of sliding a rectangle across; the same slow fade as when hands go to the
                // keyboard or trackpad, in both directions.
                // One critically damped spring family (SwiftUI's .smooth, the curve macOS uses for its own
                // fades): it eases in from rest and settles without a visible end, no overshoot.
                HighlightView(frame: local, listening: model.listening)
                    .opacity(model.handsOnInput && !model.listening ? 0 : 1)
                    .animation(.smooth(duration: 0.7), value: model.handsOnInput)
                    .id(highlightKey(target))
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 1.008)).animation(.smooth(duration: 0.5).delay(0.06)),
                        removal: .opacity.combined(with: .scale(scale: 0.996)).animation(.smooth(duration: 0.4))))
            }
            // While listening there is no dot: the edge warning shows where the look is heading.
            if model.listening, let edge = model.edge {
                EdgeWarningOverlay(edge: edge, screenFrame: screenFrame, switchProgress: model.sessionSwitch?.progress ?? 0)
                    .id(edgeKey(edge.warning))
                    .transition(.opacity)
            }
            if showsIsland {
                IslandView(model: model, notch: notch)
                    .frame(width: screenFrame.width, alignment: .top)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        // Insertions and removals only animate inside an animated change: these drive the highlight's fades.
        .animation(.smooth(duration: 0.5), value: model.target.map(highlightKey))
        .animation(.smooth(duration: 0.5), value: model.showHighlight)
        .animation(.smooth(duration: 0.2), value: model.listening)
        .animation(.smooth(duration: 0.3), value: model.edge.map { edgeKey($0.warning) })
        .animation(.smooth(duration: 0.25), value: model.banner)
        .allowsHitTesting(false)
    }

    /// The island sits on the screen holding the session in play, else on the primary screen.
    private var showsIsland: Bool {
        if let t = model.target, t.intersects(screenFrame) { return true }
        return model.target == nil && isPrimary
    }

    /// One identity per session frame: a new frame is a new outline that fades in, never a moving one.
    private func highlightKey(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))" }

    /// A warning for another side or another neighbour is a new warning that fades in, not a moving one.
    private func edgeKey(_ w: EdgeWarning) -> String { "\(w.side)-\(w.neighbourId ?? "none")" }

    private func local(_ global: CGRect) -> CGRect? {
        guard global.intersects(screenFrame) else { return nil }
        return global.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }
}
