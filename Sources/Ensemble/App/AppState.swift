import SwiftUI
import EnsembleCore

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

/// Read by the UI, written by the coordinator. Screen-space values are global, top-left origin.
@MainActor
final class AppState: ObservableObject {
    @Published var status: AppStatus = .off
    @Published var lastRefusal: String?
    @Published var targetFrame: CGRect?
    @Published var nosePoint: CGPoint?
    @Published var listening = false
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
        case .listening: return "Claude dictation on"
        case .cameraCovered: return "Camera is covered"
        case .needsCalibration: return "Needs calibration"
        case .needsPermission(let what): return "Needs permission: \(what)"
        case .claudeNotRunning: return "Claude is not running"
        case .error(let message): return message
        }
    }
}
