import Foundation

/// Tells the setup logic which reports are news. The camera engine repeats the camera in use about once a second
/// (with its frame rate), and every pass that re-decided the setup used to refit the pointer, which restarted its
/// filter and made the nose dot hitch every second. Only a different camera, or a different set of valid screens or
/// calibration data to fit, is worth acting on.
public struct SetupChangeFilter: Sendable {
    /// What the pointer was last fitted from.
    public struct FitKey: Equatable, Sendable {
        public var cameraID: String
        public var validScreenIDs: Set<String>
        public var profile: CameraProfile
        public init(cameraID: String, validScreenIDs: Set<String>, profile: CameraProfile) {
            self.cameraID = cameraID; self.validScreenIDs = validScreenIDs; self.profile = profile
        }
    }

    private var camera: (id: String, name: String)?
    private var fitted: FitKey?

    public init() {}

    /// The engine reported the camera it uses. True when it differs from the last report (or is the first).
    public mutating func cameraReported(id: String, name: String) -> Bool {
        if let c = camera, c.id == id, c.name == name { return false }
        camera = (id, name)
        return true
    }

    /// True when the pointer must be fitted from `key`: nothing was fitted yet, the key differs from the last
    /// fit, or the pointer lost its calibration since (`pointerCalibrated` false). Call `fittedFrom` after a fit.
    public func needsFit(_ key: FitKey, pointerCalibrated: Bool) -> Bool {
        !pointerCalibrated || fitted != key
    }

    public mutating func fittedFrom(_ key: FitKey?) { fitted = key }

    /// Forget the last fit, so the next one runs whatever its key (the pointer's calibration was cleared).
    public mutating func forgetFit() { fitted = nil }
}
