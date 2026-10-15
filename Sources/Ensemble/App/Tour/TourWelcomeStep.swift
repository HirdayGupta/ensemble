import SwiftUI

/// Step 1: a 3D desk where the head turns toward whichever pane it faces, looping, so the idea reads before
/// anything is asked of the owner.
struct TourWelcomeStep: View {
    @StateObject private var scene = TourSceneController(scene: .welcome)

    private static let tagline = "Drive your Claude Code sessions from across the room: look at one, speak, thumbs-up."

    var body: some View {
        VStack(spacing: 26) {
            Text("Welcome to Ensemble").font(.largeTitle.weight(.semibold))
            TourSceneStage(controller: scene, symbol: "eye", caption: Self.tagline)
                .frame(width: 600, height: 310)
            Text(Self.tagline)
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.tourInk.opacity(0.8))
                .frame(maxWidth: 480)
        }
        .padding(.top, 10)
    }
}
