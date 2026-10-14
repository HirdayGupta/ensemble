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
                HighlightView(frame: local, listening: model.listening)
                    .transition(.opacity)
            }
            // The dot shows when the setting is on, and always while a gesture is being made.
            if model.showNoseDot || model.gesture != nil, let nose = model.nose, screenFrame.contains(nose) {
                NoseDot(gesture: model.gesture)
                    .position(x: nose.x - screenFrame.minX, y: nose.y - screenFrame.minY)
                    .animation(.linear(duration: 0.08), value: nose)
            }
            if showsIsland {
                IslandView(model: model, notch: notch)
                    .frame(width: screenFrame.width, alignment: .top)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .animation(.smooth(duration: 0.25), value: model.target)
        .animation(.smooth(duration: 0.2), value: model.listening)
        .animation(.smooth(duration: 0.25), value: model.banner)
        .allowsHitTesting(false)
    }

    /// The island sits on the screen holding the session in play, else on the primary screen.
    private var showsIsland: Bool {
        if let t = model.target, t.intersects(screenFrame) { return true }
        if let c = model.countdown, c.sessionFrame.intersects(screenFrame) { return true }
        return model.target == nil && model.countdown == nil && isPrimary
    }

    private func local(_ global: CGRect) -> CGRect? {
        guard global.intersects(screenFrame) else { return nil }
        return global.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }
}

private struct HighlightView: View {
    let frame: CGRect
    let listening: Bool
    @State private var breathe = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let color: Color = listening ? .teal : .accentColor
        shape
            .strokeBorder(color.opacity(listening ? (breathe ? 0.95 : 0.6) : 0.9), lineWidth: listening ? 3.5 : 3)
            .shadow(color: color.opacity(0.6), radius: listening ? (breathe ? 16 : 8) : 10)
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathe = true } }
    }
}

/// A Dynamic Island style capsule hanging from the top centre of the screen. It grows and morphs with a
/// spring between listening, the send countdown and short messages, and folds away when idle.
private struct IslandView: View {
    @ObservedObject var model: OverlayModel
    let notch: CGSize

    private enum Mode: Equatable { case idle, listening, countdown, banner }
    private var mode: Mode {
        if let _ = model.countdown { return .countdown }
        if model.listening { return .listening }
        if model.banner != nil { return .banner }
        return .idle
    }

    private var size: CGSize {
        switch mode {
        case .idle: return CGSize(width: 120, height: 0)
        case .listening: return CGSize(width: 300, height: 38)
        case .countdown: return CGSize(width: 420, height: 112)
        case .banner: return CGSize(width: 380, height: 64)
        }
    }

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: mode == .listening ? 19 : 26,
                                          bottomTrailingRadius: mode == .listening ? 19 : 26, topTrailingRadius: 0, style: .continuous)
        ZStack {
            shape.fill(Color.black)
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.85)).animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.08)),
                                        removal: .opacity.animation(.easeOut(duration: 0.12))))
                .id(mode)
        }
        .padding(.top, mode == .idle ? 0 : notch.height)
        .frame(width: max(size.width, notch.width + (mode == .idle ? 0 : 40)), height: size.height + (mode == .idle ? 0 : notch.height))
        .background(shape.fill(Color.black))
        .clipShape(shape)
        .shadow(color: .black.opacity(mode == .idle ? 0 : 0.35), radius: 14, y: 6)
        .opacity(mode == .idle ? 0 : 1)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: mode)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .idle:
            EmptyView()
        case .listening:
            HStack(spacing: 10) {
                SoundWaves(color: .teal).frame(width: 26, height: 16)
                Text("Listening").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Spacer(minLength: 0)
                Text("double-tap to stop").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    Text(b.body).font(.system(size: 13)).foregroundStyle(.white).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
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
            SoundWaves(color: .teal).frame(width: 22, height: 16)
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
        return g.action == .talk && g.active ? .teal : .accentColor
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

/// Five bars bouncing at different rates: a live "listening" sign.
struct SoundWaves: View {
    let color: Color

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    let phase = t * (5.0 + Double(i) * 1.7) + Double(i)
                    let h = 0.3 + 0.7 * abs(sin(phase))
                    Capsule().fill(color).frame(width: 2.5).frame(maxHeight: .infinity).scaleEffect(y: h)
                }
            }
        }
    }
}

/// A small clear sphere: Liquid Glass on macOS 26, a lensed material with a specular highlight before that.
private struct GlassSphere: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Circle()
                .fill(.clear)
                .glassEffect(.clear, in: Circle())
                .overlay(highlight)
        } else {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 0.75))
                .overlay(highlight)
        }
    }

    private var highlight: some View {
        Circle()
            .fill(RadialGradient(colors: [.white.opacity(0.75), .white.opacity(0)], center: UnitPoint(x: 0.32, y: 0.28), startRadius: 0, endRadius: 7))
            .blendMode(.screen)
    }
}
