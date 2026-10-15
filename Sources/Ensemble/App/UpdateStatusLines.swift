import SwiftUI

/// The installed version (always, read from the bundle) and the result of the last update check, shown next to every
/// Check for Updates button. The result is plain secondary text, never red; it eases in on the app's smooth spring.
struct UpdateStatusLines: View {
    @ObservedObject var updates: UpdateController
    var showsInstalled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showsInstalled {
                Text(UpdateController.installedVersion)
            }
            if let result = updates.checkResult {
                Text(result)
                    .transition(.opacity.animation(.smooth(duration: 0.4)))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .animation(.smooth(duration: 0.4), value: updates.checkResult)
    }
}
