import SwiftUI
import ClutchCore

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
            // While listening there is no dot: a red marker on the session's edge points at where the nose went.
            if model.listening, let nose = model.nose, let target = model.target, let local = local(target) {
                EdgeIndicator(frame: local, toward: CGPoint(x: nose.x - screenFrame.minX, y: nose.y - screenFrame.minY))
                    .animation(.linear(duration: 0.1), value: nose)
            } else if !Self.systemGlassDot, model.showNoseDot || model.gesture != nil, let nose = model.nose, screenFrame.contains(nose) {
                GlassSphere()
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
                    .position(x: nose.x - screenFrame.minX, y: nose.y - screenFrame.minY)
                    .animation(.linear(duration: 0.08), value: nose)
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
        .animation(.smooth(duration: 0.25), value: model.banner)
        .allowsHitTesting(false)
    }

    /// On macOS 26 the dot is a separate Liquid Glass window (GlassDot), not drawn here.
    static var systemGlassDot: Bool { if #available(macOS 26.0, *) { return true } else { return false } }

    /// The island sits on the screen holding the session in play, else on the primary screen.
    private var showsIsland: Bool {
        if let t = model.target, t.intersects(screenFrame) { return true }
        if let c = model.countdown, c.sessionFrame.intersects(screenFrame) { return true }
        return model.target == nil && model.countdown == nil && isPrimary
    }

    /// One identity per session frame: a new frame is a new outline that fades in, never a moving one.
    private func highlightKey(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))" }

    private func local(_ global: CGRect) -> CGRect? {
        guard global.intersects(screenFrame) else { return nil }
        return global.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }
}

/// A soft blue glow that swells from slightly inside the session's frame out to it and fades: makes a session
/// coming forward feel like a deliberate, smooth hand-off rather than a jump.
private struct ArrivalGlow: View {
    let frame: CGRect
    @State private var shown = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        shape
            .fill(Color.clutchBlue.opacity(shown ? 0 : 0.10))
            .overlay(shape.strokeBorder(Color.clutchBlue.opacity(shown ? 0 : 0.9), lineWidth: shown ? 2 : 6))
            .shadow(color: Color.clutchBlue.opacity(shown ? 0 : 0.6), radius: 24)
            .frame(width: frame.width, height: frame.height)
            .scaleEffect(shown ? 1 : 0.96)
            .position(x: frame.midX, y: frame.midY)
            .onAppear { withAnimation(.easeOut(duration: 0.55)) { shown = true } }
    }
}

private struct HighlightView: View {
    let frame: CGRect
    let listening: Bool
    @State private var breathe = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let color: Color = listening ? .clutchBlue : .accentColor
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

/// A Dynamic Island style capsule hanging from the top centre of the screen. It grows and morphs with a
/// spring between dictation, gesture feedback and short messages, and folds away when idle. Timed waits
/// (switching sessions, holding to send) fill the island's own edge, starting the moment the clock starts.
private struct IslandView: View {
    @ObservedObject var model: OverlayModel
    let notch: CGSize

    private enum Mode: Equatable { case idle, dictating, switching, firstPinch, sendHold, otherGesture, countdown, banner }
    /// What is drawn. It follows `liveMode` only once that has held steady for a moment, so a state that lasts
    /// a frame or two (a dropped hand frame, the gap between a gesture firing and Claude confirming) never flashes.
    @State private var shown: Mode = .idle
    private var mode: Mode { shown }
    private var liveMode: Mode {
        if model.countdown != nil { return .countdown }
        if model.listening, model.sessionSwitch != nil { return .switching }
        if let g = model.gesture {
            if (g.action == .talk || g.action == .stop) && !g.active { return .firstPinch }
            if g.action == .send, g.willAct { return .sendHold }
            if g.action == .scrollUp || g.action == .scrollDown || g.action == .cancel { return .otherGesture }
        }
        if model.listening { return .dictating }
        if model.banner != nil { return .banner }
        return .idle
    }
    /// Screens without a camera notch (external displays, a closed MacBook) get a floating capsule below the
    /// menu bar instead of one growing out of the notch.
    private var floating: Bool { notch.height == 0 }

    private var size: CGSize {
        switch mode {
        case .idle: return CGSize(width: 120, height: 0)
        case .otherGesture: return CGSize(width: 200, height: 36)
        case .countdown: return CGSize(width: 420, height: 112)
        case .dictating, .switching, .firstPinch, .sendHold, .banner: return CGSize(width: 360, height: floating ? 46 : 48)
        }
    }

    /// The edge fill for timed waits; nil when this state has no clock.
    private var edgeProgress: Double? {
        switch mode {
        case .switching: return model.sessionSwitch?.progress
        case .sendHold: return model.gesture?.progress
        default: return nil
        }
    }

    private var name: String { model.sessionName ?? "this session" }

    var body: some View {
        let r: CGFloat = 22
        let shape = UnevenRoundedRectangle(topLeadingRadius: floating ? r : 0, bottomLeadingRadius: r,
                                          bottomTrailingRadius: r, topTrailingRadius: floating ? r : 0, style: .continuous)
        ZStack {
            shape.fill(Color.black)
            content
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.85)).animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.08)),
                                        removal: .opacity.animation(.easeOut(duration: 0.12))))
                .id(mode)
        }
        .padding(.top, mode == .idle ? 0 : notch.height)
        .frame(width: max(size.width, notch.width + (mode == .idle ? 0 : 40)), height: size.height + (mode == .idle ? 0 : notch.height))
        .overlay {
            if let p = edgeProgress {
                IslandEdge(floating: floating, radius: r)
                    .trim(from: 0, to: min(max(p, 0), 1))
                    .stroke(Color.clutchBlue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .animation(.linear(duration: 0.1), value: p)
            }
        }
        .background(shape.fill(Color.black))
        .clipShape(shape)
        .shadow(color: .black.opacity(mode == .idle ? 0 : 0.35), radius: 14, y: 6)
        .opacity(mode == .idle ? 0 : 1)
        .scaleEffect(floating && mode == .idle ? 0.85 : 1, anchor: .top)
        .padding(.top, floating ? NSStatusBar.system.thickness + 8 : 0)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: mode)
        .environment(\.colorScheme, .dark)
        .onAppear { shown = liveMode }
        .onChange(of: liveMode) { _, next in settle(next) }
    }

    /// 0.15 s for a new state, 0.35 s before folding away.
    private func settle(_ next: Mode) {
        let wait: UInt64 = next == .idle ? 350_000_000 : 150_000_000
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: wait)
            if liveMode == next, shown != next { shown = next }
        }
    }

    private func lines(_ title: Text, _ sub: Text?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            title.font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            if let sub { sub.font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.middle) }
        }
    }

    private func session(_ n: String) -> Text { Text(n).foregroundColor(Color.clutchSoftBlue) }

    private func hint(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).fixedSize()
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .idle:
            EmptyView()
        case .dictating:
            HStack(spacing: 11) {
                if model.liveSoundBars {
                    SoundWaves(color: .clutchBlue, level: model.audioLevel).frame(width: 26, height: 16)
                } else {
                    BlinkingMic()
                }
                lines(Text("Claude dictation on"), Text("in ") + session(name))
                Spacer(minLength: 8)
                hint("double pinch to stop")
            }
        case .switching:
            HStack(spacing: 11) {
                SwitchGlyph().frame(width: 26, height: 16)
                lines(Text("Activating ") + session(model.sessionSwitch?.name ?? "the other session"), Text("Original message unsent"))
                Spacer(minLength: 8)
                hint("look back to stay")
            }
        case .firstPinch:
            let stopping = model.gesture?.action == .stop
            HStack(spacing: 11) {
                DoublePinchGlyph().frame(width: 26, height: 18)
                lines(Text(stopping ? "Pinch again to stop dictation" : "Pinch again to dictate"), Text("in ") + session(name))
                Spacer(minLength: 0)
            }
        case .sendHold:
            HStack(spacing: 11) {
                Image(systemName: "paperplane.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.clutchBlue)
                    .frame(width: 26)
                lines(Text("Sending in ") + session(name), nil)
                Spacer(minLength: 8)
                hint("lower to cancel")
            }
        case .otherGesture:
            if let g = model.gesture {
                HStack(spacing: 10) {
                    Image(systemName: Self.symbol(g.action)).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.clutchBlue)
                    Text(Self.label(g)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
            }
        case .countdown:
            if let c = model.countdown {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.2), lineWidth: 3.5)
                        Circle().trim(from: 0, to: min(max(c.progress, 0), 1))
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "paperplane.fill").font(.system(size: 12)).foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sending").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        Text(c.text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).lineLimit(3)
                        Text(model.cancelHint).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer(minLength: 0)
                }
            }
        case .banner:
            if let b = model.banner {
                HStack(spacing: 11) {
                    Image(systemName: Self.bannerSymbol(b.style)).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Self.bannerTint(b.style)).frame(width: 26)
                    switch b.style {
                    case .sent: lines(Text("Sent in ") + session(b.body), nil)
                    case .stopped: lines(Text(b.title), Text("Text kept in ") + session(b.body) + Text(", thumbs-up to send"))
                    case .refused, .info: lines(Text(b.title), Text(b.body))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

extension IslandView {
    static func symbol(_ a: GestureAction) -> String {
        switch a {
        case .talk: return "mic.fill"
        case .stop: return "stop.fill"
        case .send: return "paperplane.fill"
        case .cancel: return "xmark"
        case .scrollUp: return "arrow.up"
        case .scrollDown: return "arrow.down"
        }
    }

    static func label(_ g: GestureProgress) -> String {
        switch g.action {
        case .talk, .stop: return "Pinch again"
        case .send: return "Sending"
        case .cancel: return "Cancel"
        case .scrollUp, .scrollDown: return "Scrolling"
        }
    }

    static func bannerSymbol(_ s: OverlayBanner.Style) -> String {
        switch s {
        case .sent: return "checkmark"
        case .stopped: return "mic.slash.fill"
        case .refused, .info: return "exclamationmark.circle.fill"
        }
    }

    static func bannerTint(_ s: OverlayBanner.Style) -> Color {
        switch s {
        case .sent: return .clutchBlue
        case .stopped: return .white.opacity(0.55)
        case .refused, .info: return Color(red: 1.0, green: 0.70, blue: 0.25)
        }
    }
}

/// The island's outline as one stroke for progress: on a notch it runs down the left side, along the bottom
/// and up the right (the top edge is the screen edge); floating, it runs clockwise from the top centre.
private struct IslandEdge: Shape {
    let floating: Bool
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2), i: CGFloat = 1.25
        let b = rect.insetBy(dx: i, dy: i)
        var p = Path()
        if floating {
            p.move(to: CGPoint(x: b.midX, y: b.minY))
            p.addLine(to: CGPoint(x: b.maxX - r, y: b.minY))
            p.addArc(center: CGPoint(x: b.maxX - r, y: b.minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: b.maxX, y: b.maxY - r))
            p.addArc(center: CGPoint(x: b.maxX - r, y: b.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: b.minX + r, y: b.maxY))
            p.addArc(center: CGPoint(x: b.minX + r, y: b.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: CGPoint(x: b.minX, y: b.minY + r))
            p.addArc(center: CGPoint(x: b.minX + r, y: b.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            p.closeSubpath()
        } else {
            p.move(to: CGPoint(x: b.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: b.minX, y: b.maxY - r))
            p.addArc(center: CGPoint(x: b.minX + r, y: b.maxY - r), radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
            p.addLine(to: CGPoint(x: b.maxX - r, y: b.maxY))
            p.addArc(center: CGPoint(x: b.maxX - r, y: b.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
            p.addLine(to: CGPoint(x: b.maxX, y: rect.minY))
        }
        return p
    }
}

/// Two white fingertips that tap together twice, then rest: "pinch, pinch".
private struct DoublePinchGlyph: View {
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
private struct SwitchGlyph: View {
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
                    RoundedRectangle(cornerRadius: 3).fill(Color.clutchBlue).frame(width: w, height: g.size.height).offset(x: (w + 3) * eased)
                        .opacity(t > 0.92 ? Double((1 - t) / 0.08) : 1)
                }
            }
        }
    }
}

/// The FPS-style hit marker: a red wedge on the session border, on the side the nose went, fading toward the centre.
private struct EdgeIndicator: View {
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
private struct Wedge: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// The default listening sign: a softly blinking blue circle with a microphone in it. Needs no permissions.
private struct BlinkingMic: View {
    @State private var on = false

    var body: some View {
        ZStack {
            Circle().fill(Color.clutchBlue.opacity(on ? 0.95 : 0.35))
            Image(systemName: "mic.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: 22, height: 22)
        .shadow(color: Color.clutchBlue.opacity(on ? 0.8 : 0.2), radius: on ? 6 : 2)
        .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { on = true } }
    }
}

extension Color {
    /// The listening colour: the highlight while listening, the island's waves and progress rings.
    static let clutchBlue = Color(red: 0.32, green: 0.58, blue: 1.0)
    /// Session names on the island: a lighter blue that reads as a name on black.
    static let clutchSoftBlue = Color(red: 0.56, green: 0.72, blue: 1.0)
}

private struct ListeningView: View {
    let frame: CGRect
    @State private var pulse = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            shape
                .strokeBorder(Color.white.opacity(pulse ? 0.75 : 0.4), lineWidth: 2)
                .shadow(color: Color.black.opacity(0.25), radius: 8)
                .frame(width: frame.width, height: frame.height)
            ListeningPill()
                .position(x: frame.width / 2, y: 30)
                .frame(width: frame.width, height: frame.height)
        }
        .position(x: frame.midX, y: frame.midY)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

private struct ListeningPill: View {
    var body: some View {
        HStack(spacing: 8) {
            SoundWaves(color: .clutchBlue).frame(width: 22, height: 16)
            Text("Listening").fontWeight(.semibold)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassSurface(Capsule())
    }
}

/// The nose dot. While a gesture is held it grows into a bubble showing what the gesture will do, with a ring
/// that fills over the hold; dimmed when the hold cannot act, solid red while dictating.
private struct NoseDot: View {
    let gesture: GestureProgress?

    private var tint: Color {
        guard let g = gesture else { return .accentColor }
        if !g.willAct { return .gray }
        return g.action == .talk && g.active ? .clutchBlue : .accentColor
    }

    private var symbol: String {
        switch gesture?.action {
        case .talk: return "mic.fill"
        case .stop: return "stop.fill"
        case .send: return "paperplane.fill"
        case .cancel: return "xmark"
        case .scrollUp: return "arrow.up"
        case .scrollDown: return "arrow.down"
        case nil: return ""
        }
    }

    var body: some View {
        let size: CGFloat = gesture == nil ? 20 : 40
        ZStack {
            if gesture == nil {
                GlassSphere()
            } else {
                Circle().fill(.regularMaterial)
            }
            if let g = gesture {
                Circle().stroke(tint.opacity(0.25), lineWidth: 3).padding(1.5)
                Circle()
                    .trim(from: 0, to: g.progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(1.5)
                    .animation(.linear(duration: 0.08), value: g.progress)
                if g.action == .talk && g.active {
                    SoundWaves(color: tint).frame(width: 20, height: 16)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
        }
        .frame(width: size, height: size)
        .opacity(gesture.map { $0.willAct ? 1 : 0.6 } ?? 1)
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        .shadow(color: tint.opacity(gesture == nil ? 0 : 0.6), radius: 12)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: gesture == nil)
    }
}

private struct CountdownPill: View {
    let countdown: Countdown
    let hint: String
    let sessionFrame: CGRect

    var body: some View {
        let width = max(220, min(440, sessionFrame.width - 32))
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().stroke(.secondary.opacity(0.3), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: min(max(countdown.progress, 0), 1))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "paperplane.fill").font(.system(size: 13)).foregroundStyle(Color.accentColor)
            }
            .frame(width: 34, height: 34)
            .animation(.linear(duration: 0.1), value: countdown.progress)

            VStack(alignment: .leading, spacing: 4) {
                Text(countdown.text)
                    .font(.callout)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: width, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.bottom, 24)
        .frame(width: sessionFrame.width, height: sessionFrame.height, alignment: .bottom)
        .position(x: sessionFrame.midX, y: sessionFrame.midY)
    }
}

private struct BannerView: View {
    let banner: OverlayBanner

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(banner.title).font(.headline)
            Text(banner.body).font(.callout).foregroundStyle(.secondary).lineLimit(3)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: 420, alignment: .leading)
        .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
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

/// The nose dot: a flat, clear patch of Liquid Glass (macOS 26), with a thin rim; a light material before that.
private struct GlassSphere: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Circle()
                .fill(Color.white.opacity(0.001))     // gives the glass a shape to fill without adding colour
                .glassEffect(.regular, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 0.75))
        } else {
            Circle()
                .fill(Color.white.opacity(0.16))
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
        }
    }
}
