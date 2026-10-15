import EnsembleCore
import QuartzCore
import SwiftUI

/// Feeds the gestures step's inset from the engine's hand readings: joint coordinates only (the engine passes
/// nothing else out), eased between readings, plus the words for what the system reads right now.
@MainActor
final class TourHandInsetModel: ObservableObject {
    @Published private(set) var readout = HandReading.noHand.title

    private var smoother = HandSkeletonSmoother()
    private var tracker = HandReadoutTracker()

    func ingest(_ hand: HandObservation) {
        smoother.observe(hand.skeleton, at: hand.t)
        let text = tracker.observe(hand, at: hand.t)
        if text != readout { readout = text }
    }

    func reset() {
        smoother.reset()
        tracker.reset()
        readout = HandReading.noHand.title
    }

    /// The joints to draw now, in the unit square, mirrored like a selfie.
    func points(at now: TimeInterval) -> [CGPoint?] {
        smoother.sample(at: now)
    }
}

/// A small overlay of the owner's hand as Vision sees it: 21 joints as dots and bones as lines, in the app's blue,
/// on a translucent dark backing. Under the skeleton, the gesture the system reads, and a check mark once the
/// open tab's gesture is done.
struct TourHandInset: View {
    @ObservedObject var model: TourHandInsetModel
    let done: Bool

    static let size = CGSize(width: 160, height: 120)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.animation) { _ in
                let points = model.points(at: CACurrentMediaTime())
                ZStack {
                    Canvas { context, size in draw(points, in: &context, size: size) }
                    if points.allSatisfy({ $0 == nil }) {
                        Text("Raise a hand to the camera")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .frame(width: Self.size.width, height: Self.size.height - 22)

            HStack(spacing: 6) {
                Text(model.readout)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 8)
            .frame(width: Self.size.width, height: 18)
            .animation(.smooth(duration: 0.3), value: done)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your hand as the camera sees it: \(model.readout)\(done ? ", done" : "")")
    }

    private func draw(_ points: [CGPoint?], in context: inout GraphicsContext, size: CGSize) {
        func place(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
        var bones = Path()
        for (a, b) in HandSkeleton.segments(of: points) {
            bones.move(to: place(a))
            bones.addLine(to: place(b))
        }
        context.stroke(bones, with: .color(Color.ensembleBlue.opacity(0.85)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        let tips: Set<Int> = [4, 8, 12, 16, 20]
        for (i, p) in points.enumerated() {
            guard let p else { continue }
            let r: CGFloat = tips.contains(i) ? 4 : 2.8
            let c = place(p)
            context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(Color.ensembleBlue))
        }
    }
}
