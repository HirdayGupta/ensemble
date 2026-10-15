import SwiftUI

struct PanelActions {
    var calibrate: () -> Void
    var openSettings: () -> Void
    /// Settings, opened at Calibration: the screens, with a Recalibrate button for each.
    var openCalibration: () -> Void
    var checkForUpdates: () -> Void
    var startTour: () -> Void
    var dismissTourBanner: () -> Void
    var quit: () -> Void
}

/// The menu-bar panel; also shown in the floating panel the global hotkey opens. Top to bottom: on/off, camera and
/// calibration, the overlay toggles, the buttons, and a footer with the installed version and Quit.
struct MenuPanelView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: SettingsStore
    @ObservedObject var updates: UpdateController
    let actions: PanelActions

    var body: some View {
        GlassGroup(spacing: 10) {
            VStack(spacing: 10) {
                header
                if !settings.tourCompleted && !settings.tourSkipped { tourBanner }
                statusCard
                togglesCard
                buttons
                footer
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: StatusIconModel.render(!settings.enabled ? .off : state.listening ? .dictating(bright: true) : StatusIconModel.look(state.status)))
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .frame(width: 40, height: 40)
                .glassSurface(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Ensemble").font(.headline)
                Text(settings.enabled ? state.status.title : "Off")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Toggle("Ensemble on or off", isOn: $settings.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.large)
        }
        .padding(12)
        .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var tourBanner: some View {
        HStack(spacing: 8) {
            Button { actions.startTour() } label: {
                Label("Take the 5-step tour", systemImage: "sparkles")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Button { actions.dismissTourBanner() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(symbol: "web.camera", text: cameraLine)
            if let line = state.calibratedLine {
                Button { actions.openCalibration() } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        row(symbol: "display.2", text: line)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("See your screens and recalibrate one of them")
            }
            if settings.enabled, case .needsPermission(let what) = state.status {
                row(symbol: "exclamationmark.circle", text: Permissions.guidance(for: what), tint: .orange)
                Button { Permissions.openSettings(for: what) } label: {
                    Label("Open \(what) settings", systemImage: "gearshape").frame(maxWidth: .infinity)
                }
                .ensembleButtonStyle()
                HStack(spacing: 8) {
                    Button { Permissions.relaunch() } label: {
                        Label("Restart Ensemble", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }
                    Button { Permissions.resetAndAsk(for: what) } label: {
                        Label("Reset", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                    }
                }
                .ensembleButtonStyle()
            }
            if state.muted {
                row(symbol: "speaker.slash", text: "Sounds muted", tint: .secondary)
            }
            // A refusal is a short-lived note about one attempt (`RefusalNotice`); it fades in and out.
            if let refusal = state.lastRefusal {
                row(symbol: "info.circle", text: refusal, tint: .orange)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.4), value: state.lastRefusal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var cameraLine: String {
        let name = state.cameraName ?? "No camera"
        return settings.enabled && state.fps > 0 ? "\(name) · \(state.fps) fps" : name
    }

    private func row(symbol: String, text: String, tint: Color = .secondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
            Text(text).font(.callout).foregroundStyle(tint == .secondary ? Color.primary : tint).lineLimit(3)
        }
    }

    private var togglesCard: some View {
        VStack(spacing: 8) {
            Toggle("Show nose dot", isOn: $settings.showNoseDot)
            Toggle("Show highlight", isOn: $settings.showHighlight)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Read left to right, top to bottom: Replay tour, the update button, Calibrate, Settings.
    private var buttons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { actions.startTour() } label: { Label("Replay tour", systemImage: "play.circle").frame(maxWidth: .infinity) }
                UpdateButton(updates: updates, fillsWidth: true) { actions.checkForUpdates() }
            }
            HStack(spacing: 8) {
                Button { actions.calibrate() } label: { Label("Calibrate…", systemImage: "scope").frame(maxWidth: .infinity) }
                    .disabled(state.calibrating)
                Button { actions.openSettings() } label: { Label("Settings…", systemImage: "gearshape").frame(maxWidth: .infinity) }
            }
        }
        .ensembleButtonStyle()
        .controlSize(.large)
    }

    private var footer: some View {
        HStack {
            Text(UpdateController.installedVersion).font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Button { actions.quit() } label: {
                Image(systemName: "power").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit Ensemble")
            .accessibilityLabel("Quit Ensemble")
        }
        .padding(.horizontal, 4)
    }
}
