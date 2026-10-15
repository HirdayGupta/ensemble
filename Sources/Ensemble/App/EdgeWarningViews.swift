import SwiftUI
import EnsembleCore

/// Everything the overlay needs to draw the warning for the edge the nose is leaving the dictating session by.
struct OverlayEdge: Equatable {
    var warning: EdgeWarning
    /// Global, top-left coordinates, like every frame the overlay is given.
    var nose: CGPoint
    var dictating: CGRect
    var neighbourName: String?
    var neighbourFrame: CGRect?
    /// The island's session columns toward the neighbour (progress 0); nil when nothing is to be shown there.
    var approach: SessionSwitch?
}

extension Color {
    /// Warnings: the cost of the look is real (a switch, or leaving Claude). The same amber as the island's notices.
    static let ensembleAmber = Color(red: 1.0, green: 0.70, blue: 0.25)
}

/// Drawn while dictating when the nose nears the edge of the dictating session. Beside another Claude session:
/// the shared seam counts down in blue and, once the nose is across, fills amber with the switch dwell; the
/// neighbour wakes up with a dashed outline and its name; a tether runs from the dictating session to the nose.
/// Where Claude ends: the whole edge glows amber. Never takes clicks or focus (the panel ignores the mouse).
struct EdgeWarningOverlay: View {
    let edge: OverlayEdge
    let screenFrame: CGRect
    /// The existing switch dwell progress (0...1) once the nose rests on the neighbour.
    let switchProgress: Double

    private var w: EdgeWarning { edge.warning }
    private var prox: Double { w.proximity }
    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - screenFrame.minX, y: p.y - screenFrame.minY) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if w.neighbourId != nil { session } else { leavingClaude }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .animation(.smooth(duration: 0.25), value: prox)
        .animation(.smooth(duration: 0.3), value: w.crossed)
    }

    private var seam: Path {
        let (a, b) = w.seam(in: edge.dictating)
        var p = Path()
        p.move(to: local(a)); p.addLine(to: local(b))
        return p
    }

    // MARK: Another Claude session beyond the edge

    @ViewBuilder private var session: some View {
        // The neighbour wakes up.
        if let nf = edge.neighbourFrame {
            let r = nf.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.ensembleBlue, style: StrokeStyle(lineWidth: 2.5, dash: [9, 7]))
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .opacity(prox * 0.9)
            if let name = edge.neighbourName {
                NameChip(name: name).position(x: r.midX, y: r.midY).opacity(prox)
            }
        }
        // The tether from the dictating session to the nose.
        let c = local(CGPoint(x: edge.dictating.midX, y: edge.dictating.midY)), n = local(edge.nose)
        Path { p in p.move(to: c); p.addLine(to: n) }
            .stroke(w.crossed ? Color.ensembleAmber : Color.ensembleBlue,
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 5]))
            .opacity(0.15 + 0.6 * prox)
        Circle().fill(w.crossed ? Color.ensembleAmber : Color.ensembleBlue).frame(width: 6, height: 6)
            .position(n).opacity(0.2 + 0.7 * prox)
        // The seam: blue brightening with proximity, amber filling with the dwell once crossed.
        seam.stroke(Color.ensembleBlue.opacity(w.crossed ? 0.35 : 0.2 + 0.8 * prox), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .shadow(color: Color.ensembleBlue.opacity(prox * 0.8), radius: 6)
        if w.crossed {
            seam.trim(from: 0, to: min(max(switchProgress, 0), 1))
                .stroke(Color.ensembleAmber, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .shadow(color: Color.ensembleAmber.opacity(0.7), radius: 6)
                .animation(.smooth(duration: 0.25), value: switchProgress)
        }
        if let name = edge.neighbourName {
            NameChip(name: name, small: true).position(labelPosition(for: name)).opacity(0.3 + 0.7 * prox)
        }
    }

    /// Just inside the dictating session, level with the middle of the seam.
    private func labelPosition(for name: String) -> CGPoint {
        let (a, b) = w.seam(in: edge.dictating)
        let mid = local(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
        let halfW = NameChip.width(of: name, small: true) / 2 + 12, halfH: CGFloat = 12 + 8
        switch w.side {
        case .left: return CGPoint(x: mid.x + halfW, y: mid.y)
        case .right: return CGPoint(x: mid.x - halfW, y: mid.y)
        case .top: return CGPoint(x: mid.x, y: mid.y + halfH)
        case .bottom: return CGPoint(x: mid.x, y: mid.y - halfH)
        }
    }

    // MARK: Nothing of Claude's beyond the edge

    /// A soft amber line along the whole edge, inset from the rounded corners.
    private var leavingClaude: some View {
        let (a, b) = w.seam(in: edge.dictating)
        let inset: CGFloat = 14
        let horizontal = w.side == .top || w.side == .bottom
        let start = local(horizontal ? CGPoint(x: a.x + inset, y: a.y) : CGPoint(x: a.x, y: a.y + inset))
        let end = local(horizontal ? CGPoint(x: b.x - inset, y: b.y) : CGPoint(x: b.x, y: b.y - inset))
        let line = Path { p in p.move(to: start); p.addLine(to: end) }
        return ZStack {
            line.stroke(Color.ensembleAmber, style: StrokeStyle(lineWidth: 8, lineCap: .round)).blur(radius: 5)
            line.stroke(Color.ensembleAmber, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        .shadow(color: Color.ensembleAmber.opacity(0.6), radius: 12)
        .opacity(0.9 * prox)
    }
}

/// A small glass label carrying a session's name.
struct NameChip: View {
    let name: String
    var small = false

    static func width(of name: String, small: Bool) -> CGFloat {
        min(CGFloat(name.count) * (small ? 6.5 : 7.5) + 24, small ? 160 : 220)
    }

    var body: some View {
        Text(name)
            .font(.system(size: small ? 11 : 13, weight: .semibold))
            .foregroundStyle(Color.ensembleSoftBlue)
            .lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 10).padding(.vertical, small ? 4 : 6)
            .frame(maxWidth: Self.width(of: name, small: small))
            .fixedSize()
            .glassSurface(Capsule())
    }
}
