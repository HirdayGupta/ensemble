import SwiftUI
import EnsembleCore

/// Step 3: four tabs, one per gesture. While this step is open, real gesture intents and head readings go to
/// the tour instead of Claude (`TourModel.tourPractice`), so a tab can mark itself done the moment the owner
/// performs the real thing, without pressing, dictating or sending anything.
struct TourGesturesStep: View {
    @ObservedObject var model: TourModel

    var body: some View {
        VStack(spacing: 18) {
            Text("Four gestures").font(.largeTitle.weight(.semibold))

            Picker("Gesture", selection: Binding(get: { model.activeTab }, set: { model.selectTab($0) })) {
                ForEach(TourGestureTab.allCases, id: \.self) { tab in
                    Label(tab.title, systemImage: model.practiceDone.contains(tab) ? "checkmark.circle.fill" : tab.symbolName)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 460)

            TabIllustration(tab: model.activeTab).id(model.activeTab)

            Text(model.activeTab.explanation)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            HStack(spacing: 10) {
                if model.practiceDone.contains(model.activeTab) {
                    Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label(model.activeTab.practicePrompt, systemImage: "hand.wave")
                        .foregroundStyle(Color.ensembleBlue)
                }
                Spacer()
                if let next = TourGestureTab(rawValue: model.activeTab.rawValue + 1) {
                    Button("Skip this step") { model.selectTab(next) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: 480)
            .animation(.smooth(duration: 0.3), value: model.practiceDone)
        }
    }
}

private struct TabIllustration: View {
    let tab: TourGestureTab

    var body: some View {
        HStack(spacing: 36) {
            if tab == .look {
                LookIllustration()
            } else {
                TourHandView(tab: tab)
                    .frame(width: 220, height: 190)
            }
            TourSessionMock(tab: tab)
        }
        .frame(height: 210)
    }
}

/// The Look tab's illustration: the overhead head, looping the same as Welcome and Calibrate.
private struct LookIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turned = false

    private var yawDegrees: Double { reduceMotion ? 0 : (turned ? 26 : -26) }

    var body: some View {
        VStack(spacing: 10) {
            SessionMonitors(facedIndex: SessionMonitors.facedIndex(forYawDegrees: yawDegrees))
                .scaleEffect(0.8)
            OverheadHeadGroup(yawDegrees: yawDegrees).scaleEffect(0.8)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) { turned = true }
        }
    }
}

extension TourGestureTab {
    var title: String {
        switch self {
        case .look: return "Look"
        case .dictate: return "Dictate"
        case .send: return "Send"
        case .scroll: return "Scroll"
        }
    }

    var symbolName: String {
        switch self {
        case .look: return "eye"
        case .dictate: return "hand.pinch"
        case .send: return "hand.thumbsup"
        case .scroll: return "hand.draw"
        }
    }

    var explanation: String {
        switch self {
        case .look: return "Look at a session to highlight it: a blue outline, never filled."
        case .dictate: return "Double pinch (thumb tip to index tip, twice) to start dictating into the session you face. Double pinch again to stop."
        case .send: return "Hold thumbs-up for 0.75 s to send — only within 30 s of speaking, only to that session, and only if you have not typed since."
        case .scroll: return "Pinch and drag your hand up or down to scroll the session you're facing."
        }
    }

    var practicePrompt: String {
        switch self {
        case .look: return "Your turn: look away from this window, then back."
        case .dictate: return "Your turn: double pinch to start, double pinch again to stop."
        case .send: return "Your turn: hold thumbs-up for about three quarters of a second."
        case .scroll: return "Your turn: pinch, then drag your hand up or down."
        }
    }
}
