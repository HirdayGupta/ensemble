import CoreGraphics
import Foundation
import Testing
@testable import EnsembleCore

/// The 2026-10-15 report on 0.2.15: two 2560x1440 screens side by side, the left one rotated back from portrait and
/// recalibrated on its own twice. The first run followed the dots on the left screen; the second, started from the
/// main screen, repeated the main screen's own angles point for point, was saved, and the nose never reached the
/// left screen again. The samples below are the ones logged and saved that day.
@Suite struct RecalibrateOneScreenTests {
    static let main = "0924B0F5"
    static let left = "CC9B5F0D"
    static let mainFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    static let leftFrame = CGRect(x: -2560, y: 0, width: 2560, height: 1440)

    static func s(_ yaw: Double, _ pitch: Double, _ x: Double, _ y: Double) -> CalibrationSample {
        CalibrationSample(yaw: yaw, pitch: pitch, target: CGPoint(x: x, y: y))
    }

    /// The main screen's saved calibration (centre, left, right, top, bottom).
    static let mainSamples = [s(-0.036, -0.079, 1280, 720), s(0.375, -0.022, 204.8, 720), s(-0.390, -0.088, 2355.2, 720),
                              s(-0.046, 0.031, 1280, 115.2), s(-0.059, -0.370, 1280, 1324.8)]
    /// The first one-screen run on the left screen (16:45), turned toward its dots.
    static let leftFollowed = [s(0.407, 0.043, -1280, 720), s(0.659, -0.031, -2355.2, 720), s(-0.014, -0.112, -204.8, 720),
                               s(0.436, 0.083, -1280, 115.2), s(0.379, -0.190, -1280, 1324.8)]
    /// The second one-screen run on the left screen (16:46), the one saved: the main screen's angles again.
    static let leftRepeatingMain = [s(-0.012, -0.147, -1280, 720), s(0.276, -0.112, -2355.2, 720), s(-0.374, -0.151, -204.8, 720),
                                    s(0.002, -0.046, -1280, 115.2), s(-0.016, -0.302, -1280, 1324.8)]

    static func profile(left samples: [CalibrationSample]) -> CameraProfile {
        let now = Date()
        var profile = CameraProfile(cameraID: "c920", cameraName: "HD Pro Webcam C920")
        profile.merge([ScreenCalibration(screenID: main, frame: mainFrame, samples: mainSamples, calibratedAt: now),
                       ScreenCalibration(screenID: left, frame: leftFrame, samples: samples, calibratedAt: now)])
        return profile
    }

    /// Every point the pointer gives over a sweep of head angles wide enough to cover both screens.
    static func reachable(left samples: [CalibrationSample]) -> [CGPoint] {
        let pointer = NosePointer()
        let ok = pointer.fit(screens: profile(left: samples).pointerScreens(for: [main, left]))
        #expect(ok)
        var points: [CGPoint] = []
        for yawStep in -80...100 {
            for pitch in [-0.3, -0.1, 0.05] {
                if let p = pointer.raw(for: HeadObservation(t: 0, yaw: Double(yawStep) / 100, pitch: pitch, faceCount: 1)) { points.append(p) }
            }
        }
        return points
    }

    @Test func theSavedRepeatLeavesTheLeftScreenUnreachable() {
        // The bug as it shipped: with both screens over one angle range, no head angle lands on the left screen.
        let points = Self.reachable(left: Self.leftRepeatingMain)
        #expect(!points.isEmpty)
        #expect(points.allSatisfy { $0.x >= 0 })
    }

    @Test func aRunThatFollowedTheDotsReachesTheLeftScreen() {
        let points = Self.reachable(left: Self.leftFollowed)
        #expect(points.contains { Self.leftFrame.contains($0) })
        #expect(points.contains { Self.mainFrame.contains($0) })
    }

    @Test func samplesRepeatingAnotherScreenAreNamed() {
        let profile = Self.profile(left: Self.leftRepeatingMain)
        let repeated = profile.screenRepeated(by: Self.leftRepeatingMain, forScreen: Self.left, inSpot: profile.spots[0].id,
                                              validScreenIDs: [Self.main, Self.left])
        #expect(repeated == Self.main)
    }

    @Test func samplesThatFollowedTheDotsAreNotARepeat() {
        let profile = Self.profile(left: Self.leftFollowed)
        let spot = profile.spots[0].id
        #expect(profile.screenRepeated(by: Self.leftFollowed, forScreen: Self.left, inSpot: spot, validScreenIDs: [Self.main, Self.left]) == nil)
        // Nor is the main screen's own calibration a repeat of the left screen's.
        #expect(profile.screenRepeated(by: Self.mainSamples, forScreen: Self.main, inSpot: spot, validScreenIDs: [Self.main, Self.left]) == nil)
    }

    @Test func onlyValidScreensOfTheSameSpotCount() {
        var profile = Self.profile(left: Self.leftRepeatingMain)
        let first = profile.spots[0].id
        // A screen that is not valid now (moved or unplugged) is not compared.
        #expect(profile.screenRepeated(by: Self.leftRepeatingMain, forScreen: Self.left, inSpot: first, validScreenIDs: [Self.left]) == nil)
        // Another spot (standing, say) may see a different screen over the same angles.
        let standing = profile.addSpot([ScreenCalibration(screenID: Self.left, frame: Self.leftFrame, samples: Self.leftRepeatingMain, calibratedAt: Date())])
        #expect(profile.screenRepeated(by: Self.leftRepeatingMain, forScreen: Self.left, inSpot: standing,
                                       validScreenIDs: [Self.main, Self.left]) == nil)
    }

    @Test func aOneScreenRunStartsFromTheNearestCalibratedScreen() {
        let profile = Self.profile(left: Self.leftFollowed)
        let reference = profile.neighbour(of: Self.leftFrame, inSpot: profile.spots[0].id, validScreenIDs: [Self.main, Self.left],
                                          excluding: [Self.left])
        #expect(reference?.frame == Self.mainFrame)
        #expect(reference?.centre == Self.mainSamples[0])
        #expect(profile.neighbour(of: Self.leftFrame, inSpot: profile.spots[0].id, validScreenIDs: [Self.left], excluding: [Self.left]) == nil)
    }

    @Test func theNearestOfSeveralCalibratedScreensIsChosen() {
        let profile = Self.profile(left: Self.leftFollowed)
        let nearest = profile.neighbour(of: Self.leftFrame, inSpot: profile.spots[0].id, validScreenIDs: [Self.main, Self.left],
                                        excluding: [])
        #expect(nearest?.frame == Self.leftFrame)
    }

    @Test func theFirstDotOfAOneScreenRunNeedsATurnAwayFromTheMainScreen() {
        let profile = Self.profile(left: Self.leftFollowed)
        let rule = AimRule()
        let reference = profile.neighbour(of: Self.leftFrame, inSpot: profile.spots[0].id, validScreenIDs: [Self.main, Self.left],
                                          excluding: [Self.left])
        let requirement = rule.requirement(forFirstDotOn: Self.leftFrame, previousScreen: reference)
        // Before: stillness alone, so a head still resting on the main screen's centre was captured.
        #expect(rule.requirement(forFirstDotOn: Self.leftFrame, previousScreen: nil) == .stillness)
        #expect(rule.evaluate(CalibrationAimTests.hold(yaw: -0.012, pitch: -0.147), requirement: requirement) == .notFarEnough)
        guard case .ready = rule.evaluate(CalibrationAimTests.hold(yaw: 0.407, pitch: 0.043), requirement: requirement) else {
            Issue.record("a head turned to the left screen's centre must be accepted"); return
        }
    }
}
