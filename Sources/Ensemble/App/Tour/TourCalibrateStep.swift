import SwiftUI

/// Step 2: shows what calibration does in 3D (a dot visiting five spots per screen while the head turns to follow
/// it), then asks for the Camera permission the first time it is needed and runs the real calibration when
/// Calibrate is pressed. Esc cancels the real calibration; Later continues the tour without calibrating.
struct TourCalibrateStep: View {
    @ObservedObject var model: TourModel
    @ObservedObject var state: AppState
    @ObservedObject var settings: SettingsStore
    @StateObject private var scene = TourSceneController(scene: .calibrate)

    private static let blurb = "A dot visits five spots on each screen while you follow it with your head."

    var body: some View {
        VStack(spacing: 22) {
            Text("Calibrate every screen").font(.largeTitle.weight(.semibold))
            TourSceneStage(controller: scene, symbol: "scope", caption: Self.blurb)
                .frame(width: 600, height: 280)
            Text(Self.blurb)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
            statusLine
            HStack(spacing: 12) {
                Button("Later") { model.jump(to: .gestures) }
                    .ensembleButtonStyle()
                Button("Calibrate…") { model.calibrateNow() }
                    .disabled(state.calibrating)
                    .ensembleButtonStyle(prominent: true)
            }
            Text("Esc cancels. Calibrate asks for Camera access the first time; frames are never saved or sent.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    @ViewBuilder private var statusLine: some View {
        if state.calibrating {
            Label("Calibrating on your screen…", systemImage: "scope").foregroundStyle(Color.ensembleBlue)
        } else if let date = settings.calibratedAt {
            Label("Last calibrated \(date.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }
}
