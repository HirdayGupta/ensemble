import SwiftUI
import EnsembleCore

/// Two white fingertips that tap together twice, then rest: "pinch, pinch".
struct DoublePinchGlyph: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4)
            let gap = Self.gap(t)
            ZStack {
                Circle().fill(.white).frame(width: 6, height: 6).offset(y: -gap)
                Circle().fill(.white).frame(width: 6, height: 6).offset(y: gap)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Half the distance between the tips over one 1.4 s cycle: open, tap, open, tap, rest open.
    static func gap(_ t: Double) -> CGFloat {
        let open: CGFloat = 5.5, shut: CGFloat = 3.2
        func tap(_ t: Double, at c: Double) -> CGFloat {
            let d = abs(t - c)
            guard d < 0.11 else { return 0 }
            return CGFloat(0.5 + 0.5 * cos(d / 0.11 * .pi))
        }
        let k = max(tap(t, at: 0.25), tap(t, at: 0.52))
        return open - (open - shut) * k
    }
}

/// Two session tiles side by side; the lit one slides from the first to the second: focus is moving.
struct SwitchGlyph: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            let x = CGFloat(min(max((t - 0.2) / 0.5, 0), 1))
            let eased = x * x * (3 - 2 * x)
            GeometryReader { g in
                let w = (g.size.width - 3) / 2
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.45), lineWidth: 1.2).frame(width: w, height: g.size.height)
                    RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.45), lineWidth: 1.2).frame(width: w, height: g.size.height).offset(x: w + 3)
                    RoundedRectangle(cornerRadius: 3).fill(Color.ensembleBlue).frame(width: w, height: g.size.height).offset(x: (w + 3) * eased)
                        .opacity(t > 0.92 ? Double((1 - t) / 0.08) : 1)
                }
            }
        }
    }
}

/// One outlined column per open session; the lit column slides from the one losing focus to the one gaining
/// it, following the switch's own progress. `SwitchLayout` (EnsembleCore) does the column math.
struct SessionColumnsGlyph: View {
    let count: Int
    let groupBreaks: Set<Int>
    let from: Int
    let to: Int
    let progress: Double

    var body: some View {
        GeometryReader { g in
            let columns = SwitchLayout.columns(count: count, groupBreaks: groupBreaks, width: g.size.width)
            ZStack(alignment: .topLeading) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, c in
                    RoundedRectangle(cornerRadius: 1.5)
                        .stroke(.white.opacity(0.45), lineWidth: 1.2)
                        .frame(width: c.width, height: g.size.height)
                        .offset(x: c.x)
                }
                if let lit = SwitchLayout.litColumn(from: from, to: to, progress: progress, in: columns) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.ensembleBlue)
                        .frame(width: lit.width, height: g.size.height)
                        .offset(x: lit.x)
                }
            }
            .animation(.smooth(duration: 0.4), value: progress)
        }
    }
}

/// The default listening sign: a softly blinking blue circle with a microphone in it. Needs no permissions.
struct BlinkingMic: View {
    @State private var on = false

    var body: some View {
        ZStack {
            Circle().fill(Color.ensembleBlue.opacity(on ? 0.95 : 0.35))
            Image(systemName: "mic.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: 22, height: 22)
        .shadow(color: Color.ensembleBlue.opacity(on ? 0.8 : 0.2), radius: on ? 6 : 2)
        .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { on = true } }
    }
}

extension Color {
    /// The listening colour: the highlight while listening, the island's waves and progress rings.
    static let ensembleBlue = Color(red: 0.32, green: 0.58, blue: 1.0)
    /// The same blue darkened so text and thin strokes read on white (the website's --e-blue-ink).
    static let ensembleBlueInk = Color(red: 0.176, green: 0.416, blue: 0.878)
    /// Session names on the island: a lighter blue that reads as a name on black.
    static let ensembleSoftBlue = Color(red: 0.56, green: 0.72, blue: 1.0)
}

/// Five bars that follow the live voice level (each with its own wobble so they never move in lockstep).
/// With no level available (no microphone permission) they idle gently.
struct SoundWaves: View {
    let color: Color
    var level: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    let wobble = 0.5 + 0.5 * abs(sin(t * (6.0 + Double(i) * 1.9) + Double(i)))
                    let shape = [0.55, 0.85, 1.0, 0.8, 0.6][i]
                    let h = level > 0.02 ? 0.15 + 0.85 * min(1, level * shape * (0.7 + 0.3 * wobble)) : 0.2 + 0.15 * wobble
                    Capsule().fill(color).frame(width: 2.5).frame(maxHeight: .infinity).scaleEffect(y: h)
                }
            }
        }
    }
}
