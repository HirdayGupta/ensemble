import SwiftUI
import EnsembleCore

/// A small mock Claude session pane that follows the 3D scene beside it: a capsule state and a body that shows
/// words appearing while dictating, the draft moving up when sent, or lines scrolling. The scene reports its own
/// progress (`TourSceneFrame`), so the mock and the hand never drift apart. Not a real session: nothing here is
/// ever pressed, dictated or sent.
struct TourSessionMock: View {
    let tab: TourGestureTab
    let frame: TourSceneFrame

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
        .frame(width: 200, height: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.4)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tab == .look ? Color.ensembleBlue : .white.opacity(0.08), lineWidth: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
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
        case .look, .scroll: return "Ready"
        case .dictate: return frame.listening ? "Listening" : "Ready"
        case .send: return frame.sent ? "Sent" : "Ready"
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
            let shown = Int((frame.draft * Double(Self.words.count)).rounded(.down))
            Text(Self.words.prefix(min(shown, Self.words.count)).joined(separator: " "))
                .font(.caption).foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .send:
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.words.joined(separator: " "))
                    .font(.caption).foregroundStyle(.white.opacity(0.85))
                    .offset(y: frame.sent ? -50 : 0)
                    .opacity(frame.sent ? 0 : 1)
                    .animation(.smooth(duration: 0.4), value: frame.sent)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                Spacer(minLength: 0)
                // The hold fills before the draft goes: the same 0.75 s the real gesture waits.
                GeometryReader { g in
                    Capsule().fill(Color.white.opacity(0.12))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Color.ensembleBlue).frame(width: g.size.width * frame.hold)
                        }
                }
                .frame(height: 4)
            }
        case .scroll:
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<9, id: \.self) { i in
                    Text("Line \(i + 1)").font(.caption2).foregroundStyle(.white.opacity(0.45))
                }
            }
            .offset(y: -CGFloat(frame.scroll) * 48)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
    }
}
