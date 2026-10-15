import SwiftUI

struct PanelActions {
    var calibrate: () -> Void
    var openSettings: () -> Void
    var checkForUpdates: () -> Void
    var startTour: () -> Void
    var dismissTourBanner: () -> Void
    var quit: () -> Void
}

/// The menu-bar panel; also shown in the floating panel the global hotkey opens.
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
            if settings.enabled, case .needsPermission(let what) = state.status {
                row(symbol: "exclamationmark.circle", text: Permissions.guidance(for: what), tint: .orange)
                Button { Permissions.openSettings(for: what) } label: {
                    Label("Open \(what) settings", systemImage: "gearshape").frame(maxWidth: .infinity)
                }
                .ensembleButtonStyle()
            }
            if state.muted {
                row(symbol: "speaker.slash", text: "Sounds muted", tint: .secondary)
            }
            if let refusal = state.lastRefusal {
                row(symbol: "info.circle", text: refusal, tint: .orange)
            }
        }
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

    private var buttons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { actions.calibrate() } label: { Label("Calibrate…", systemImage: "scope").frame(maxWidth: .infinity) }
                    .disabled(state.calibrating)
                Button { actions.openSettings() } label: { Label("Settings…", systemImage: "gearshape").frame(maxWidth: .infinity) }
            }
            HStack(spacing: 8) {
                Button { actions.startTour() } label: { Label("Replay tour", systemImage: "play.circle").frame(maxWidth: .infinity) }
                Button { actions.checkForUpdates() } label: {
                    Label(updates.availableVersion.map { "Update to \($0)…" } ?? "Check for Updates…",
                          systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                }
            }
            HStack {
                Text("⌥⌘K shows this panel").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit Ensemble") { actions.quit() }.buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
        }
        .ensembleButtonStyle()
        .controlSize(.large)
    }
}
