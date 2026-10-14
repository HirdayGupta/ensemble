import SwiftUI

struct PanelActions {
    var calibrate: () -> Void
    var openSettings: () -> Void
    var clearAndDisarm: () -> Void
    var checkForUpdates: () -> Void
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
            Image(systemName: state.status.symbolName)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(state.status.tint)
                .frame(width: 40, height: 40)
                .glassSurface(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Clutch").font(.headline)
                Text(settings.enabled ? state.status.title : "Off")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Toggle("Clutch on or off", isOn: $settings.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.large)
        }
        .padding(12)
        .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(symbol: "web.camera", text: cameraLine)
            if settings.enabled, case .needsPermission(let what) = state.status {
                row(symbol: "lock", text: Permissions.guidance(for: what), tint: .orange)
                Button { Permissions.openSettings(for: what) } label: {
                    Label("Open \(what) settings", systemImage: "gearshape").frame(maxWidth: .infinity)
                }
                .clutchButtonStyle()
            }
            if state.muted {
                row(symbol: "speaker.slash", text: "Sounds muted", tint: .secondary)
            }
            if let refusal = state.lastRefusal {
                row(symbol: "hand.raised.slash", text: refusal, tint: .orange)
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
            Button(role: .destructive) { actions.clearAndDisarm() } label: {
                Label("Clear and disarm", systemImage: "xmark.circle").frame(maxWidth: .infinity)
            }
            HStack {
                Button(updates.availableVersion.map { "Update to \($0)…" } ?? "Check for Updates…") { actions.checkForUpdates() }
                    .buttonStyle(.plain).font(.callout).foregroundStyle(updates.availableVersion == nil ? .secondary : .primary)
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
            HStack {
                Text("⌥⌘K shows this panel").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit Clutch") { actions.quit() }.buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
        }
        .clutchButtonStyle()
        .controlSize(.large)
    }
}
