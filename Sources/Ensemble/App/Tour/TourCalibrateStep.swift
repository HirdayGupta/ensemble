import AppKit
import SwiftUI

/// Step 2: shows what calibration does (a dot visiting five spots per screen while the head turns to follow
/// it), then asks for the Camera permission the first time it is needed and runs the real calibration when
/// Calibrate is pressed. Esc cancels the real calibration; Later continues the tour without calibrating.
struct TourCalibrateStep: View {
    @ObservedObject var model: TourModel
    @ObservedObject var state: AppState
    @ObservedObject var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spotIndex = 0

    private let screenCount = max(NSScreen.screens.count, 1)
    /// Centre, left, right, top, bottom: the same order real calibration visits (`CalibrationController.targets`).
    private static let spots: [(dx: Double, dy: Double, yaw: Double)] = [
        (0, 0, 0), (-1, 0, -28), (1, 0, 28), (0, -1, 0), (0, 1, 0),
    ]

    private var screenIndex: Int { (spotIndex / Self.spots.count) % screenCount }
    private var spot: (dx: Double, dy: Double, yaw: Double) { Self.spots[spotIndex % Self.spots.count] }
    private var yawDegrees: Double { reduceMotion ? 0 : spot.yaw }

    var body: some View {
        VStack(spacing: 22) {
            Text("Calibrate every screen").font(.largeTitle.weight(.semibold))
            ZStack {
                screenBox
                OverheadHeadGroup(yawDegrees: yawDegrees)
                    .scaleEffect(0.72)
                    .offset(y: 86)
            }
            .frame(height: 230)
            VStack(spacing: 4) {
                if screenCount > 1 {
                    Text("Screen \(screenIndex + 1) of \(screenCount)").font(.headline)
                }
                Text(screenIndex > 0 ? "Turn to face this screen." : "A dot visits five spots on each screen.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
            }
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
        .onAppear { startLoop() }
    }

    @ViewBuilder private var statusLine: some View {
        if state.calibrating {
            Label("Calibrating on your screen…", systemImage: "scope").foregroundStyle(Color.ensembleBlue)
        } else if let date = settings.calibratedAt {
            Label("Last calibrated \(date.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }

    private var screenBox: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(.white.opacity(0.25), lineWidth: 1.5)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.35)))
            .frame(width: 180, height: 120)
            .overlay(
                Circle()
                    .fill(Color.ensembleBlue)
                    .frame(width: 16, height: 16)
                    .shadow(color: .ensembleBlue.opacity(0.7), radius: 8)
                    .offset(x: spot.dx * 70, y: spot.dy * 40)
                    .animation(.smooth(duration: 0.6), value: spotIndex)
            )
            .offset(y: -40)
    }

    private func startLoop() {
        guard !reduceMotion else { return }
        Timer.scheduledTimer(withTimeInterval: 1.1, repeats: true) { timer in
            Task { @MainActor in
                guard model.step == .calibrate else { timer.invalidate(); return }
                withAnimation(.smooth(duration: 0.6)) { spotIndex += 1 }
            }
        }
    }
}
