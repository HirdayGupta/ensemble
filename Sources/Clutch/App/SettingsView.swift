import SwiftUI
import AVFoundation
import ClutchCore

struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: SettingsStore
    @ObservedObject var updates: UpdateController
    let calibrate: () -> Void

    var body: some View {
        TabView {
            GeneralSettings(state: state, settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            GestureSettings(settings: settings)
                .tabItem { Label("Gestures", systemImage: "hand.raised") }
            DisplaySettings(settings: settings)
                .tabItem { Label("Display", systemImage: "rectangle.on.rectangle") }
            CalibrationSettings(state: state, settings: settings, calibrate: calibrate)
                .tabItem { Label("Calibration", systemImage: "scope") }
            AboutSettings(updates: updates)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 540, height: 440)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: SettingsStore

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
            }
            Section {
                LabeledContent("Show the panel from anywhere", value: "⌥⌘K")
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
    let calibrate: () -> Void

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
                Button("Calibrate…", action: calibrate)
                    .disabled(state.calibrating)
                    .clutchButtonStyle(prominent: true)
            } footer: {
                Text("A dot visits five spots on each screen. Point your nose at it and keep your head still. Redo this if you move your screen or camera.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettings: View {
    @ObservedObject var updates: UpdateController

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            Text("Ensemble").font(.title.weight(.semibold))
            Text(version).font(.callout).foregroundStyle(.secondary)
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
            VStack(spacing: 8) {
                Button(updates.availableVersion.map { "Update to \($0)…" } ?? "Check for Updates…") { updates.checkForUpdates() }
                Toggle("Check for updates automatically (once a day)", isOn: Binding(
                    get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }))
                    .toggleStyle(.switch).controlSize(.small).disabled(!updates.isConfigured)
            }
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
