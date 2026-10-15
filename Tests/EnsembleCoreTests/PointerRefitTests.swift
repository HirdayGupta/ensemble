import CoreGraphics
import Foundation
import Testing
@testable import EnsembleCore

/// The camera engine repeats the camera in use about once a second, and each repeat used to refit the pointer,
/// which restarted its smoothing: the next reading went through unsmoothed and the nose dot hitched every second.
@Suite struct PointerRefitTests {
    private static let screens = PerScreenPointerTests.screens()

    /// A head path that moves enough for the filter's state to matter.
    private static func path(_ i: Int) -> HeadObservation {
        let m = CGPoint(x: 900 + 40 * Double(i % 7), y: 600 + 25 * Double(i % 5))
        let a = PerScreenPointerTests.angles(forMain: m)
        return HeadObservation(t: Double(i) / 30, yaw: a.0, pitch: a.1, faceCount: 1)
    }

    /// The points of `steps` readings, with `between` run before reading `at`.
    private static func points(_ p: NosePointer, steps: Int, at: Int = -1, between: (NosePointer) -> Void = { _ in }) -> [CGPoint?] {
        (0..<steps).map { i in
            if i == at { between(p) }
            return p.point(for: path(i))
        }
    }

    @Test func refittingTheSameScreensKeepsTheFilter() {
        let steady = NosePointer(), refit = NosePointer()
        #expect(steady.fit(screens: Self.screens))
        #expect(refit.fit(screens: Self.screens))
        let want = Self.points(steady, steps: 20)
        let got = Self.points(refit, steps: 20, at: 10) { #expect($0.fit(screens: Self.screens)) }
        #expect(got == want)
        #expect(refit.activeScreenID == "main")
    }

    @Test func refittingDifferentScreensStillRestartsTheFilter() {
        let steady = NosePointer(), refit = NosePointer()
        #expect(steady.fit(screens: Self.screens))
        #expect(refit.fit(screens: Self.screens))
        var moved = Self.screens
        moved[0].samples[0].target.x += 30
        let want = Self.points(steady, steps: 20)
        let got = Self.points(refit, steps: 20, at: 10) { #expect($0.fit(screens: moved)) }
        #expect(got[10] != want[10])
    }

    @Test func refittingTheSameSingleMapKeepsTheFilter() {
        let samples = Self.screens[0].samples
        let steady = NosePointer(), refit = NosePointer()
        #expect(steady.fit(samples))
        #expect(refit.fit(samples))
        let want = Self.points(steady, steps: 20)
        let got = Self.points(refit, steps: 20, at: 10) { #expect($0.fit(samples)) }
        #expect(got == want)
    }

    // MARK: - Which reports are news

    private static func profile(_ x: Double = 0) -> CameraProfile {
        CameraProfile(cameraID: "cam", cameraName: "Camera",
                      screens: [ScreenCalibration(screenID: "a", frame: CGRect(x: x, y: 0, width: 1920, height: 1080),
                                                  samples: Self.screens[0].samples, calibratedAt: Date(timeIntervalSince1970: 0))])
    }

    @Test func aRepeatedCameraReportIsNotNews() {
        var f = SetupChangeFilter()
        let first = f.cameraReported(id: "cam", name: "Camera")
        #expect(first)
        for _ in 0..<5 {
            let repeated = f.cameraReported(id: "cam", name: "Camera")
            #expect(!repeated)
        }
        let other = f.cameraReported(id: "other", name: "Other")
        #expect(other)
        let back = f.cameraReported(id: "cam", name: "Camera")
        #expect(back)
    }

    @Test func aRepeatedEvaluationDoesNotRefit() {
        var f = SetupChangeFilter()
        let key = SetupChangeFilter.FitKey(cameraID: "cam", validScreenIDs: ["a"], profile: Self.profile())
        #expect(f.needsFit(key, pointerCalibrated: true))
        f.fittedFrom(key)
        for _ in 0..<5 { #expect(!f.needsFit(key, pointerCalibrated: true)) }
    }

    @Test func aRealChangeOrALostCalibrationRefits() {
        var f = SetupChangeFilter()
        let key = SetupChangeFilter.FitKey(cameraID: "cam", validScreenIDs: ["a"], profile: Self.profile())
        f.fittedFrom(key)
        #expect(f.needsFit(.init(cameraID: "cam", validScreenIDs: ["a", "b"], profile: Self.profile()), pointerCalibrated: true))
        #expect(f.needsFit(.init(cameraID: "cam", validScreenIDs: ["a"], profile: Self.profile(1920)), pointerCalibrated: true))
        #expect(f.needsFit(.init(cameraID: "cam2", validScreenIDs: ["a"], profile: Self.profile()), pointerCalibrated: true))
        #expect(f.needsFit(key, pointerCalibrated: false))
        f.forgetFit()
        #expect(f.needsFit(key, pointerCalibrated: true))
    }
}
