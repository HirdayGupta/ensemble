import SwiftUI
import ClutchCore

enum AppStatus: Equatable {
    case off
    case watching
    case listening
    case cameraCovered
    case needsCalibration
    case needsPermission(String)
    case claudeNotRunning
    case error(String)
}

/// A pending send. `progress` runs from 0 (just started) to 1 (sends now).
struct Countdown: Equatable {
    var progress: Double
    var text: String
    var sessionFrame: CGRect
}

/// Read by the UI, written by the coordinator. Screen-space values are global, top-left origin.
@MainActor
final class AppState: ObservableObject {
    @Published var status: AppStatus = .off
    @Published var lastRefusal: String?
    @Published var targetFrame: CGRect?
    @Published var nosePoint: CGPoint?
    @Published var listening = false
    @Published var countdown: Countdown?
    @Published var muted = false
    @Published var fps = 0
    @Published var cameraName: String?
    @Published var cameraNames: [String] = []
    @Published var calibrating = false

    /// `@Published` announces a change on every write, even of an equal value; the camera loop writes several
    /// of these on every frame, so those writes go through here and only real changes reach the views.
    func set<T: Equatable>(_ path: ReferenceWritableKeyPath<AppState, T>, _ value: T) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }
}

extension AppStatus {
    var title: String {
        switch self {
        case .off: return "Off"
        case .watching: return "Watching"
        case .listening: return "Listening"
        case .cameraCovered: return "Camera is covered"
        case .needsCalibration: return "Needs calibration"
        case .needsPermission(let what): return "Needs permission: \(what)"
        case .claudeNotRunning: return "Claude is not running"
        case .error(let message): return message
        }
    }

    var symbolName: String {
        switch self {
        case .off: return "hand.raised.slash"
        case .watching: return "hand.raised"
        case .listening: return "hand.raised.fill"
        case .cameraCovered: return "video.slash"
        case .needsCalibration: return "scope"
        case .needsPermission: return "lock"
        case .claudeNotRunning: return "pause.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .off: return .secondary
        case .watching: return .green
        case .listening: return .clutchBlue
        case .cameraCovered, .needsCalibration, .needsPermission, .claudeNotRunning: return .orange
        case .error: return .red
        }
    }
}
