import SwiftUI

/// Step 4: three cards. Camera already shows granted (calibration asked for it); Accessibility can be granted
/// here; Microphone is shown struck out, because Ensemble never asks for it.
struct TourPermissionsStep: View {
    @ObservedObject var model: TourModel

    var body: some View {
        VStack(spacing: 26) {
            Text("Permissions").font(.largeTitle.weight(.semibold))
            VStack(spacing: 14) {
                card(symbol: "camera.fill", title: "Camera", granted: model.cameraGranted,
                     detail: model.cameraGranted
                        ? "Granted during calibration."
                        : "Granted automatically the first time you calibrate.")
                card(symbol: "accessibility", title: "Accessibility", granted: model.accessibilityGranted,
                     detail: "Presses Claude's own dictation, Send and scroll controls.",
                     action: model.accessibilityGranted ? nil : (title: "Grant…", perform: model.requestAccessibility))
                microphoneCard
            }
            .frame(maxWidth: 480)
            Spacer(minLength: 0)
        }
    }

    private func card(symbol: String, title: String, granted: Bool, detail: String,
                       action: (title: String, perform: () -> Void)? = nil) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 20)).frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 12)
            if let action {
                Button(action.title, action: action.perform).ensembleButtonStyle(prominent: true)
            } else {
                Label(granted ? "Granted" : "Not yet", systemImage: granted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(granted ? .green : .secondary)
                    .animation(.smooth(duration: 0.3), value: granted)
            }
        }
        .padding(14)
        .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var microphoneCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "mic.slash.fill").font(.system(size: 20)).frame(width: 34).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Microphone").font(.headline).strikethrough().foregroundStyle(.secondary)
                Text("Not needed: Claude does the listening.").font(.caption).foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 12)
        }
        .padding(14)
        .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(0.55)
    }
}
