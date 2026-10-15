import CoreGraphics
import Foundation

/// One connected screen, as seen by the matcher: its stable id, display name and current frame
/// (global, top-left origin).
public struct ScreenSnapshot: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var frame: CGRect
    public init(id: String, name: String, frame: CGRect) { self.id = id; self.name = name; self.frame = frame }
}

/// Calibration samples recorded for one screen under one camera, tagged with the screen's id and the
/// frame it had when they were taken: a later frame change is what marks the screen as moved.
public struct ScreenCalibration: Codable, Equatable, Sendable {
    public var screenID: String
    public var frame: CGRect
    public var samples: [CalibrationSample]
    public var calibratedAt: Date
    public init(screenID: String, frame: CGRect, samples: [CalibrationSample], calibratedAt: Date) {
        self.screenID = screenID; self.frame = frame; self.samples = samples; self.calibratedAt = calibratedAt
    }
}

/// Everything calibrated for one camera: its stable id, its display name, and a calibration per
/// screen it has been calibrated on.
public struct CameraProfile: Codable, Equatable, Sendable {
    public var cameraID: String
    public var cameraName: String
    public var screens: [ScreenCalibration]
    /// The fitted pointer model from before profiles existed. Raw samples were never stored then, so a
    /// migrated profile has this instead; it is used until the first new calibration replaces it.
    public var legacyModel: Data?
    public init(cameraID: String, cameraName: String, screens: [ScreenCalibration] = [], legacyModel: Data? = nil) {
        self.cameraID = cameraID; self.cameraName = cameraName; self.screens = screens; self.legacyModel = legacyModel
    }

    /// True when any of these screens has no samples of its own (it came from the migrated model).
    public func hasModelOnly(_ screenIDs: Set<String>) -> Bool {
        screens.contains { screenIDs.contains($0.screenID) && $0.samples.isEmpty }
    }

    public func calibration(forScreenID id: String) -> ScreenCalibration? { screens.first { $0.screenID == id } }

    /// Replaces (or adds) the calibration for each given screen; every other screen's calibration is untouched.
    public mutating func merge(_ updates: [ScreenCalibration]) {
        for u in updates {
            if let i = screens.firstIndex(where: { $0.screenID == u.screenID }) { screens[i] = u } else { screens.append(u) }
        }
    }

    /// Every sample tagged to one of `screenIDs`.
    public func samples(for screenIDs: Set<String>) -> [CalibrationSample] {
        screens.filter { screenIDs.contains($0.screenID) }.flatMap(\.samples)
    }

    /// The per-screen inputs for the pointer fit: each of `screenIDs` that has samples, with its frame.
    public func pointerScreens(for screenIDs: Set<String>) -> [PointerScreen] {
        screens.filter { screenIDs.contains($0.screenID) && !$0.samples.isEmpty }
            .map { PointerScreen(id: $0.screenID, frame: $0.frame, samples: $0.samples) }
    }
}

/// Every camera profile the app has ever calibrated, persisted as one blob.
public struct SetupProfiles: Codable, Equatable, Sendable {
    public var cameras: [CameraProfile]
    public init(cameras: [CameraProfile] = []) { self.cameras = cameras }

    public func profile(forCameraID id: String) -> CameraProfile? { cameras.first { $0.cameraID == id } }

    public mutating func setProfile(_ profile: CameraProfile) {
        if let i = cameras.firstIndex(where: { $0.cameraID == profile.cameraID }) { cameras[i] = profile } else { cameras.append(profile) }
    }
}

/// What a camera-or-screen change means for the current desk setup, decided from the stored profiles
/// and the facts of the moment alone (no camera, no AppKit).
public enum SetupDecision: Equatable, Sendable {
    /// This camera has never been calibrated. `previousCameraName` is the camera calibration was last
    /// made with (nil only when nothing has ever been calibrated at all).
    case newCamera(cameraName: String, previousCameraName: String?, screenCount: Int)
    /// This camera has a profile. `validScreenIDs` already have usable samples at their current frame and
    /// keep working; `newScreens` do not (never seen, or moved) and need calibrating. `newScreens` empty
    /// means every connected screen matches and the setup can restore silently.
    case ready(cameraName: String, validScreenIDs: [String], newScreens: [ScreenSnapshot], mostRecentCalibration: Date?)
}

public enum SetupEvaluator {
    /// `frameTolerance` absorbs the pixel jitter some displays report across a sleep/wake cycle without
    /// reading as "moved".
    public static func evaluate(
        profiles: SetupProfiles, cameraID: String, cameraName: String, previousCameraName: String?,
        screens: [ScreenSnapshot], frameTolerance: CGFloat = 2
    ) -> SetupDecision {
        guard let profile = profiles.profile(forCameraID: cameraID), !profile.screens.isEmpty else {
            return .newCamera(cameraName: cameraName, previousCameraName: previousCameraName, screenCount: screens.count)
        }
        var validIDs: [String] = []
        var newScreens: [ScreenSnapshot] = []
        for screen in screens {
            if let stored = profile.calibration(forScreenID: screen.id), framesMatch(stored.frame, screen.frame, tolerance: frameTolerance) {
                validIDs.append(screen.id)
            } else {
                newScreens.append(screen)
            }
        }
        let recent = profile.screens.filter { validIDs.contains($0.screenID) }.map(\.calibratedAt).max()
        return .ready(cameraName: profile.cameraName, validScreenIDs: validIDs, newScreens: newScreens, mostRecentCalibration: recent)
    }

    private static func framesMatch(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
