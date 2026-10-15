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
