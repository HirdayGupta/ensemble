import SwiftUI
import AVFoundation
import EnsembleCore

struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: SettingsStore
    @ObservedObject var updates: UpdateController
    @ObservedObject var navigation: SettingsNavigation
    let calibrate: (CalibrationRequest) -> Void
    let removeSpot: (String) -> Void
    let replayTour: (TourStep?) -> Void

    var body: some View {
        TabView(selection: $navigation.tab) {
            GeneralSettings(state: state, settings: settings, updates: updates, replayTour: replayTour)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            GestureSettings(settings: settings)
                .tabItem { Label("Gestures", systemImage: "hand.raised") }
                .tag(SettingsTab.gestures)
            DisplaySettings(settings: settings)
                .tabItem { Label("Display", systemImage: "rectangle.on.rectangle") }
                .tag(SettingsTab.display)
            CalibrationSettings(state: state, settings: settings, calibrate: calibrate, removeSpot: removeSpot)
                .tabItem { Label("Calibration", systemImage: "scope") }
                .tag(SettingsTab.calibration)
            AboutSettings(updates: updates)
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 540, height: 440)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: SettingsStore
    @ObservedObject var updates: UpdateController
    let replayTour: (TourStep?) -> Void
    @State private var tourStep: TourStep = .welcome

    var body: some View {
        Form {
            Section {
                Toggle("Enable Ensemble", isOn: $settings.enabled)
                Picker("Camera", selection: $settings.cameraName) {
                    Text("Automatic").tag(String?.none)
                    ForEach(cameraChoices, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                Toggle("Open at login (restarts after a crash)", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                if let error = settings.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Play sounds", isOn: $settings.playSounds)
                Toggle("Fade out and pause other audio while dictating", isOn: $settings.pauseMediaWhileDictating)
                Text("Only when the sound comes from speakers the microphone can hear; headphones are left alone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Show the panel from anywhere", value: "⌥⌘K")
            }
            Section {
                Toggle("Update automatically", isOn: Binding(get: { updates.autoInstall }, set: { updates.setAutoInstall($0) }))
                    .disabled(!updates.isConfigured)
                LabeledContent(UpdateController.installedVersion) {
                    UpdateButton(updates: updates) { updates.checkForUpdates() }
                        .disabled(!updates.isConfigured)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Checks soon after launch and then every hour; the button shows a new version as soon as one is found. A new version installs only while you are not dictating, calibrating or in the tour, and Ensemble then restarts on its own. Off: nothing is checked until you press Check for Updates.")
            }
            Section("Tour") {
                Button("Replay tour") { replayTour(nil) }
                Picker("One step", selection: $tourStep) {
                    ForEach(TourStep.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Button("Replay this step") { replayTour(tourStep) }
            }
        }
        .formStyle(.grouped)
    }

    private var cameraChoices: [String] {
        var names = state.cameraNames
        if let chosen = settings.cameraName, !names.contains(chosen) { names.append(chosen) }
        return names
    }
}

private struct GestureSettings: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                ForEach([GestureSlot.talk, .send, .scrollUp, .scrollDown], id: \.self) { slot in
                    GestureRow(slot: slot, pose: settings.mapping[slot]) {
                        Picker(slot.title, selection: Binding(
                            get: { settings.mapping[slot] },
                            set: { settings.assign($0, to: slot) }
                        )) {
                            if slot.allowsOff { Text("Off").tag(Pose?.none) }
                            ForEach(Pose.allCases, id: \.self) { Text($0.title).tag(Pose?.some($0)) }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                }
            } footer: {
                Text("Each gesture can only do one thing. Picking one that is in use swaps it with the other action.")
            }
            Section {
                Toggle("Warn when my look leaves Claude", isOn: $settings.warnWhenLeavingClaude)
            } footer: {
                Text("While dictating, the edge you are looking toward glows amber if what lies beyond it is not a Claude session. Looking toward another Claude session is always shown.")
            }
            Section {
                Toggle("Headphone presses", isOn: $settings.headphonePresses)
            } footer: {
                Text("One press starts or stops dictation in the session you look at. Two presses send.")
            }
            Section {
                GestureRow(slot: .cancel, pose: settings.mapping.cancel) {
                    Text(settings.mapping.cancel.title).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Cancel takes whichever gesture is left over.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct GestureRow<Control: View>: View {
    let slot: GestureSlot
    let pose: Pose?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: pose?.symbolName ?? "hand.raised.slash")
                .font(.system(size: 18))
                .frame(width: 38, height: 38)
                .glassSurface(RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.title).font(.headline)
                Text(slot.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 2)
    }
}

private struct DisplaySettings: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Overlay") {
                Toggle("Show nose dot", isOn: $settings.showNoseDot)
                Toggle("Highlight the session you face", isOn: $settings.showHighlight)
                LabeledContent("Pointer smoothing") {
                    HStack {
                        Text("Quick").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $settings.pointerSmoothing, in: 0...1)
                            .frame(width: 160)
                        Text("Steady").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Correct for where I sit", isOn: $settings.correctForPosition)
                Text(settings.correctForPosition
                     ? "Pointing follows your nose even after you slide along the desk. Needs a calibration made with this version; older ones keep pointing by angle alone until you recalibrate."
                     : "Pointing uses only the angle of your head, so recalibrate after you move your seat.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Listening indicator") {
                Toggle("Live sound bars (asks for microphone access)", isOn: Binding(get: { settings.liveSoundBars }, set: { on in
                    settings.liveSoundBars = on
                    if on, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    }
                }))
                Text(settings.liveSoundBars
                     ? "The bars follow how loudly you speak. Audio is never recorded, stored or sent."
                     : "A blinking microphone shows Claude is listening. Ensemble never uses the microphone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Scrolling") {
                Toggle("Reverse pinch-and-drag direction", isOn: $settings.reverseScroll)
                Text(settings.reverseScroll
                     ? "Moving your pinch up scrolls toward earlier messages."
                     : "Moving your pinch up drags the page up, toward later messages (follows your Mac's scroll direction).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sending") {
                LabeledContent("Hold thumbs-up to send") {
                    HStack {
                        Slider(value: $settings.sendCountdownSeconds, in: SettingsStore.countdownRange, step: 0.25)
                            .frame(width: 180)
                        Text(String(format: "%.1f s", settings.sendCountdownSeconds))
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CalibrationSettings: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: SettingsStore
    let calibrate: (CalibrationRequest) -> Void
    let removeSpot: (String) -> Void
    @State private var removing: CalibrationSpotSummary?

    var body: some View {
        Form {
            Section {
                LabeledContent("Last calibrated") {
                    if let date = settings.calibratedAt {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text("Never").foregroundStyle(.secondary)
                    }
                }
                Button(state.screenChoices.count > 1 ? "Calibrate all screens…" : "Calibrate…") { calibrate(.recalibrate) }
                    .disabled(state.calibrating)
                    .ensembleButtonStyle(prominent: true)
            } footer: {
                Text("A dot visits five points on each screen. Point your nose at it and keep your head still. Redo this if you move your screen or camera.")
            }
            if !state.screenChoices.isEmpty {
                Section {
                    ForEach(state.screenChoices) { screen in
                        HStack {
                            Label(screen.name, systemImage: "display")
                            Spacer(minLength: 8)
                            if state.screenChoices.count > 1 {
                                Button("Recalibrate") { calibrate(.screen(screen.id)) }
                                    .disabled(state.calibrating)
                            }
                        }
                    }
                } header: {
                    Text("Screens")
                } footer: {
                    if state.screenChoices.count > 1 {
                        Text("Recalibrate one screen to redo only that one; the others keep theirs.")
                    }
                }
            }
            Section {
                ForEach(state.calibrationSpots) { spot in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spot.name)
                            Text(spot.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if state.calibrationSpots.count > 1, spot.id == state.spotInUse {
                            Text("In use").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Remove") { removing = spot }
                            .disabled(state.calibrationSpots.count < 2 || state.calibrating)
                    }
                }
                Button("Add position…") { calibrate(.newPosition) }
                    .disabled(state.calibrating || state.calibrationSpots.isEmpty)
            } header: {
                Text("Positions")
            } footer: {
                Text("Calibrate again from another place, such as standing or leaning back, and keep the ones you have. Ensemble uses the position closest to where your head is. Calibrate above redoes the one in use.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove \(removing?.name ?? "this position")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        )) {
            Button("Remove", role: .destructive) {
                if let id = removing?.id { removeSpot(id) }
                removing = nil
            }
        } message: {
            Text("Its calibration is deleted. The other positions keep working.")
        }
    }
}

private struct AboutSettings: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            Text("Ensemble").font(.title.weight(.semibold))
            Text(UpdateController.installedVersion).font(.callout).foregroundStyle(.secondary)
            Text("Hands-free control for Claude on your Mac. Video is analysed on this Mac and never stored or sent.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            VStack(alignment: .leading, spacing: 6) {
                credit("MediaPipe", "Face landmarks. Apache-2.0, Google.")
                credit("Sleight", "Hand-pose rules. MIT, Florian Riquelme.")
                credit("claude-dictation-hotkey", "Dictation approach. MIT.")
                credit("Sparkle", "Updates. MIT, Sparkle Project.")
            }
            .padding(14)
            .frame(maxWidth: 400, alignment: .leading)
            .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
            UpdateButton(updates: updates) { updates.checkForUpdates() }
            Spacer(minLength: 0)
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity)
    }

    private func credit(_ name: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).font(.callout.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
    }
}
