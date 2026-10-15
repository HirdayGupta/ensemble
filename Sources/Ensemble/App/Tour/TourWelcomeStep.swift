import SwiftUI

/// Step 1: the head turns toward whichever pane it faces, looping, so the idea reads before anything is asked
/// of the owner.
struct TourWelcomeStep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turned = false

    private var yawDegrees: Double { reduceMotion ? 0 : (turned ? 26 : -26) }

    var body: some View {
        VStack(spacing: 30) {
            Text("Welcome to Ensemble").font(.largeTitle.weight(.semibold))
            SessionMonitors(facedIndex: SessionMonitors.facedIndex(forYawDegrees: yawDegrees))
            OverheadHeadGroup(yawDegrees: yawDegrees)
            Text("Drive your Claude Code sessions from across the room: look at one, speak, thumbs-up.")
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: 440)
        }
        .padding(.top, 10)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) { turned = true }
        }
    }
}
