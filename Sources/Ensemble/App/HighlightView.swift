import SwiftUI
import EnsembleCore

struct HighlightView: View {
    let frame: CGRect
    let listening: Bool
    @State private var breathe = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let color: Color = listening ? .ensembleBlue : .accentColor
        shape
            .strokeBorder(color.opacity(listening ? (breathe ? 0.95 : 0.6) : 0.9), lineWidth: listening ? 3.5 : 3)
            .shadow(color: color.opacity(0.6), radius: listening ? (breathe ? 16 : 8) : 10)
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .onAppear { if listening { startBreathing() } }
            .onChange(of: listening) { _, on in
                if on { startBreathing() } else { withAnimation(.easeOut(duration: 0.2)) { breathe = false } }
            }
    }

    /// The breathing pulse is only visible while listening; running it otherwise redraws the border for nothing.
    private func startBreathing() {
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathe = true }
    }
}

/// The FPS-style hit marker: a red wedge on the session border, on the side the nose went, fading toward the centre.
struct EdgeIndicator: View {
    let frame: CGRect
    let toward: CGPoint

    var body: some View {
        let c = CGPoint(x: frame.midX, y: frame.midY)
        let dx = toward.x - c.x, dy = toward.y - c.y
        // Where the line from the centre toward the nose meets the border.
        let sx = dx == 0 ? CGFloat.infinity : (frame.width / 2) / abs(dx)
        let sy = dy == 0 ? CGFloat.infinity : (frame.height / 2) / abs(dy)
        let k = min(sx, sy)
        let edge = CGPoint(x: c.x + dx * k, y: c.y + dy * k)
        let angle = Angle(radians: atan2(dy, dx))
        return Wedge()
            .fill(LinearGradient(colors: [.red.opacity(0.85), .red.opacity(0)], startPoint: .trailing, endPoint: .leading))
            .frame(width: 90, height: 70)
            .rotationEffect(angle)
            .position(x: edge.x - cos(angle.radians) * 45, y: edge.y - sin(angle.radians) * 45)
            .opacity(hypot(dx, dy) < 1 ? 0 : 1)
    }
}

/// A triangle pointing right: its tip touches the border, its base fades inward.
struct Wedge: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
