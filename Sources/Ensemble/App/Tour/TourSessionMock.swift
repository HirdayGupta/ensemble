import SwiftUI
import EnsembleCore

/// A small mock Claude session pane that reacts to whichever gesture is being explained: a capsule state and
/// a body that shows words appearing while dictating, the draft moving up when sent, or lines scrolling.
/// Not a real session: nothing here is ever pressed, dictated or sent.
struct TourSessionMock: View {
    let tab: TourGestureTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0

    private static let words = ["Add", "a", "dark", "mode", "toggle"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(Color.white.opacity(0.25)).frame(width: 7, height: 7)
                Text("session").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.55))
                Spacer()
                capsule
            }
            draftArea
        }
        .padding(14)
        .frame(width: 210, height: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.4)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tab == .look ? Color.ensembleBlue : .white.opacity(0.08), lineWidth: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear { startLoop() }
    }

    private var capsule: some View {
        Text(capsuleText)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(capsuleColor))
            .foregroundStyle(.white)
            .animation(.smooth(duration: 0.3), value: capsuleText)
    }

    private var capsuleText: String {
        switch tab {
        case .look: return "Ready"
        case .dictate: return phase == 0 ? "Ready" : "Listening"
        case .send: return phase < 2 ? "Ready" : "Sent"
        case .scroll: return "Ready"
        }
    }

    private var capsuleColor: Color {
        switch capsuleText {
        case "Listening": return Color.ensembleBlue.opacity(0.9)
        case "Sent": return .green.opacity(0.85)
        default: return .white.opacity(0.25)
        }
    }

    @ViewBuilder private var draftArea: some View {
        switch tab {
        case .look:
            Text("Looking at this session highlights it.")
                .font(.caption).foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .dictate:
            Text(Self.words.prefix(phase).joined(separator: " "))
                .font(.caption).foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .animation(.smooth(duration: 0.2), value: phase)
        case .send:
            Text(Self.words.joined(separator: " "))
                .font(.caption).foregroundStyle(.white.opacity(0.85))
                .offset(y: phase >= 2 ? -50 : 0)
                .opacity(phase >= 2 ? 0 : 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .animation(.smooth(duration: 0.4), value: phase)
        case .scroll:
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<6, id: \.self) { i in
                    Text("Line \(i + 1 + phase)").font(.caption2).foregroundStyle(.white.opacity(0.45))
                }
            }
            .offset(y: -CGFloat(phase % 6) * 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .animation(.smooth(duration: 0.3), value: phase)
        }
    }

    private func startLoop() {
        guard !reduceMotion else { phase = tab == .send ? 2 : 1; return }
        let (total, interval): (Int, Double) = {
            switch tab {
            case .look: return (1, 1.0)
            case .dictate: return (Self.words.count + 2, 0.5)
            case .send: return (4, 0.8)
            case .scroll: return (18, 0.2)
            }
        }()
        guard total > 1 else { return }
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in phase = (phase + 1) % total }
        }
    }
}
