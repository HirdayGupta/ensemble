import SwiftUI

/// The one update button, used everywhere updates appear: "Check for Updates", "Update to x.y.z" once a check (the
/// user's or an automatic one) finds a version (one press installs it end to end), "Installing x.y.z..." or "Installs
/// x.y.z when you finish" while an install runs or waits, and "Up to date" for a few seconds after a check finds nothing. Its
/// title changes on the app's smooth spring, never instantly.
struct UpdateButton: View {
    @ObservedObject var updates: UpdateController
    var fillsWidth = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(updates.buttonTitle, systemImage: symbol)
                .contentTransition(.opacity)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .animation(.smooth(duration: 0.4), value: updates.buttonTitle)
    }

    private var symbol: String {
        if updates.installingVersion != nil || updates.checking { return "hourglass" }
        if updates.availableVersion != nil { return "arrow.down.circle.fill" }
        return updates.showingUpToDate ? "checkmark.circle" : "arrow.down.circle"
    }
}
