import SwiftUI

/// Draws one screen's share of the overlay. Coordinates are global top-left; `screenFrame` is this screen's
/// frame in that same space, so local = global - screenFrame.origin.
struct OverlayScreenView: View {
    @ObservedObject var model: OverlayModel
    let screenFrame: CGRect
    let isPrimary: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.showHighlight, let target = model.target, let local = local(target) {
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
            if model.showNoseDot, let nose = model.nose, screenFrame.contains(nose) {
                NoseDot()
                    .position(x: nose.x - screenFrame.minX, y: nose.y - screenFrame.minY)
                    .animation(.linear(duration: 0.06), value: nose)
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
                .strokeBorder(Color.red.opacity(pulse ? 0.95 : 0.45), lineWidth: pulse ? 4 : 2.5)
                .shadow(color: Color.red.opacity(pulse ? 0.7 : 0.25), radius: pulse ? 22 : 10)
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
            Image(systemName: "mic.fill").foregroundStyle(.red)
            Text("Listening").fontWeight(.semibold)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassSurface(Capsule())
    }
}

private struct NoseDot: View {
    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 3))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .shadow(color: Color.accentColor.opacity(0.6), radius: 8)
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
