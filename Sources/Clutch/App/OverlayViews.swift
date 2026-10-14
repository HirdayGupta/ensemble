import SwiftUI
import ClutchCore

/// Draws one screen's share of the overlay. Coordinates are global top-left; `screenFrame` is this screen's
/// frame in that same space, so local = global - screenFrame.origin.
struct OverlayScreenView: View {
    @ObservedObject var model: OverlayModel
    let screenFrame: CGRect
    let isPrimary: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.showHighlight, !model.listening, let target = model.target, let local = local(target) {
                HighlightView(frame: local)
                    .transition(.opacity)
            }
            if model.listening, let target = model.target, let local = local(target) {
                ListeningView(frame: local)
                    .transition(.opacity)
            } else if model.listening, isPrimary {
                ListeningPill()
                    .position(x: screenFrame.width / 2, y: 64)
            }
            if let countdown = model.countdown, let local = local(countdown.sessionFrame) {
                CountdownPill(countdown: countdown, hint: model.cancelHint, sessionFrame: local)
            }
            // The dot shows when the setting is on, and always while a gesture is being made.
            if model.showNoseDot || model.gesture != nil, let nose = model.nose, screenFrame.contains(nose) {
                NoseDot(gesture: model.gesture)
                    .position(x: nose.x - screenFrame.minX, y: nose.y - screenFrame.minY)
                    .animation(.smooth(duration: 0.18), value: nose)
            }
            if isPrimary, let banner = model.banner {
                BannerView(banner: banner)
                    .position(x: screenFrame.width / 2, y: 96)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .animation(.smooth(duration: 0.25), value: model.target)
        .animation(.smooth(duration: 0.2), value: model.listening)
        .animation(.smooth(duration: 0.25), value: model.banner)
        .allowsHitTesting(false)
    }

    private func local(_ global: CGRect) -> CGRect? {
        guard global.intersects(screenFrame) else { return nil }
        return global.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }
}

private struct HighlightView: View {
    let frame: CGRect

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        shape
            .fill(Color.accentColor.opacity(0.05))
            .overlay(shape.strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 2.5))
            .shadow(color: Color.accentColor.opacity(0.55), radius: 18)
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
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
            SoundWaves(color: .red).frame(width: 22, height: 16)
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
        return g.action == .talk && g.active ? .red : .accentColor
    }

    private var symbol: String {
        switch gesture?.action {
        case .talk: return "mic.fill"
        case .send: return "paperplane.fill"
        case .cancel: return "xmark"
        case .scroll: return "arrow.up.arrow.down"
        case nil: return ""
        }
    }

    var body: some View {
        let size: CGFloat = gesture == nil ? 12 : 40
        ZStack {
            Circle()
                .fill(gesture == nil ? AnyShapeStyle(Color.white) : AnyShapeStyle(.regularMaterial))
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
            } else {
                Circle().strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .frame(width: size, height: size)
        .opacity(gesture.map { $0.willAct ? 1 : 0.6 } ?? 1)
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        .shadow(color: tint.opacity(0.6), radius: gesture == nil ? 8 : 12)
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
