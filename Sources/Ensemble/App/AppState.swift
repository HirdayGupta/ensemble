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

/// What a Calibrate press asks for.
enum CalibrationRequest: Equatable {
    /// Every screen, replacing the position in use now.
    case recalibrate
    /// Only this screen (stable id), in the position in use now; every other screen keeps its calibration.
    case screen(String)
    /// Every screen, from where the owner is now, kept beside the positions already saved.
    case newPosition
}

/// One saved position, as Settings lists it: "Position 2", "2 screens, Oct 14".
struct CalibrationSpotSummary: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
}

/// A connected screen, as the screen picker lists it: "DELL U2723QE, left".
struct ScreenChoice: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Read by the UI, written by the coordinator. Screen-space values are global, top-left origin.
@MainActor
final class AppState: ObservableObject {
    @Published var status: AppStatus = .off
    @Published var lastRefusal: String?
    @Published var listening = false
    @Published var muted = false
    @Published var fps = 0
    @Published var cameraName: String?
    @Published var cameraNames: [String] = []
    @Published var calibrating = false
    /// "Calibrated for 2 screens", or nil when none of the connected screens is calibrated.
    @Published var calibratedLine: String?
    /// The positions calibrated for the camera in use, for Settings, and the one the pointer uses now.
    @Published var calibrationSpots: [CalibrationSpotSummary] = []
    @Published var spotInUse: String?
    /// The connected screens, for recalibrating just one of them.
    @Published var screenChoices: [ScreenChoice] = []

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
