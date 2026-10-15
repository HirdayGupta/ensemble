import SwiftUI

/// The overhead view used on Welcome, Calibrate and the Look tab: a head turning left and right, with a soft
/// gaze cone from the nose. Shoulders stay put; only the head (ears, nose, gaze cone) turns, pivoting about
/// its own centre.
struct OverheadHeadGroup: View {
    var yawDegrees: Double

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(0.12))
                .frame(width: 150, height: 46)
                .offset(y: 92)
            ZStack {
                GazeCone()
                    .fill(LinearGradient(colors: [Color.ensembleBlue.opacity(0.32), Color.ensembleBlue.opacity(0)],
                                         startPoint: .bottom, endPoint: .top))
                    .frame(width: 150, height: 130)
                    .offset(y: -115)
                Ellipse()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 92, height: 112)
                ear.offset(x: -47, y: 8)
                ear.offset(x: 47, y: 8)
                nose.offset(y: -58)
            }
            .rotationEffect(.degrees(yawDegrees))
        }
        .frame(width: 220, height: 220)
        .animation(.smooth(duration: 0.6), value: yawDegrees)
    }

    private var ear: some View {
        Ellipse().fill(Color.white.opacity(0.75)).frame(width: 16, height: 26)
    }

    private var nose: some View {
        Triangle().fill(Color.white.opacity(0.95)).frame(width: 20, height: 22)
    }
}

/// A narrow isosceles triangle pointing up, standing in for the nose seen from above.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// A soft fan widening away from the nose, standing in for the field of gaze.
private struct GazeCone: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Two monitors, two panes each; the pane the head faces gets the blue outline. Matches the real highlight:
/// an outline only, never filled (`docs/gotchas.md`, 9).
struct SessionMonitors: View {
    var facedIndex: Int?

    var body: some View {
        HStack(spacing: 18) {
            monitor(panes: 0..<2)
            monitor(panes: 2..<4)
        }
    }

    private func monitor(panes: Range<Int>) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                ForEach(Array(panes), id: \.self) { pane($0) }
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
            Capsule().fill(Color.white.opacity(0.18)).frame(width: 36, height: 6)
        }
    }

    private func pane(_ index: Int) -> some View {
        let faced = index == facedIndex
        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .frame(width: 50, height: 36)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(faced ? Color.ensembleBlue : .clear, lineWidth: 2.5)
            )
            .animation(.smooth(duration: 0.3), value: faced)
    }

    /// Four even buckets across a head's left-right turn: two panes per monitor, left monitor first.
    static func facedIndex(forYawDegrees yaw: Double) -> Int {
        switch yaw {
        case ..<(-15): return 0
        case ..<0: return 1
        case ..<15: return 2
        default: return 3
        }
    }
}
