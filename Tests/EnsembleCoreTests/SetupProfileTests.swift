import CoreGraphics
import Foundation
import Testing
@testable import EnsembleCore

@Suite struct SetupProfileTests {
    private func sample(_ x: Double = 0) -> CalibrationSample { CalibrationSample(yaw: 0.1, pitch: 0.1, target: CGPoint(x: x, y: 0)) }
    private func frame(_ x: Double = 0, _ w: Double = 1920) -> CGRect { CGRect(x: x, y: 0, width: w, height: 1080) }
    private func screen(_ id: String, _ x: Double = 0, _ w: Double = 1920, name: String = "Screen") -> ScreenSnapshot {
        ScreenSnapshot(id: id, name: name, frame: frame(x, w))
    }

    @Test func unknownCameraIsNewCamera() {
        let decision = SetupEvaluator.evaluate(profiles: SetupProfiles(), cameraID: "cam1", cameraName: "FaceTime HD Camera",
                                                previousCameraName: nil, screens: [screen("a"), screen("b", 1920)])
        #expect(decision == .newCamera(cameraName: "FaceTime HD Camera", previousCameraName: nil, screenCount: 2))
    }

    @Test func cameraWithEmptyProfileCountsAsNewCamera() {
        var profiles = SetupProfiles()
        profiles.setProfile(CameraProfile(cameraID: "cam1", cameraName: "FaceTime HD Camera"))
        let decision = SetupEvaluator.evaluate(profiles: profiles, cameraID: "cam1", cameraName: "FaceTime HD Camera",
                                                previousCameraName: nil, screens: [screen("a")])
        #expect(decision == .newCamera(cameraName: "FaceTime HD Camera", previousCameraName: nil, screenCount: 1))
    }

    @Test func matchingScreenIsValidAndReady() {
        let now = Date()
        var profile = CameraProfile(cameraID: "cam1", cameraName: "FaceTime HD Camera")
        profile.merge([ScreenCalibration(screenID: "a", frame: frame(), samples: [sample()], calibratedAt: now)])
        var profiles = SetupProfiles()
        profiles.setProfile(profile)

        let decision = SetupEvaluator.evaluate(profiles: profiles, cameraID: "cam1", cameraName: "FaceTime HD Camera",
                                                previousCameraName: nil, screens: [screen("a")])
        #expect(decision == .ready(cameraName: "FaceTime HD Camera", validScreenIDs: ["a"], newScreens: [], mostRecentCalibration: now))
    }

    @Test func unplugOneScreenLeavesTheOtherValidWithNoNewScreens() {
        let now = Date()
        var profile = CameraProfile(cameraID: "cam1", cameraName: "FaceTime HD Camera")
        profile.merge([
            ScreenCalibration(screenID: "a", frame: frame(), samples: [sample()], calibratedAt: now),
            ScreenCalibration(screenID: "b", frame: frame(1920), samples: [sample()], calibratedAt: now),
        ])
        var profiles = SetupProfiles()
        profiles.setProfile(profile)

        // Only screen "a" is still connected.
        let decision = SetupEvaluator.evaluate(profiles: profiles, cameraID: "cam1", cameraName: "FaceTime HD Camera",
                                                previousCameraName: nil, screens: [screen("a")])
        #expect(decision == .ready(cameraName: "FaceTime HD Camera", validScreenIDs: ["a"], newScreens: [], mostRecentCalibration: now))
    }

    @Test func unknownScreenIsNewButOthersStayValid() {
        let now = Date()
        var profile = CameraProfile(cameraID: "cam1", cameraName: "FaceTime HD Camera")
        profile.merge([ScreenCalibration(screenID: "a", frame: frame(), samples: [sample()], calibratedAt: now)])
        var profiles = SetupProfiles()
        profiles.setProfile(profile)

        let newScreen = screen("b", 1920, name: "Studio Display")
        let decision = SetupEvaluator.evaluate(profiles: profiles, cameraID: "cam1", cameraName: "FaceTime HD Camera",
                                                previousCameraName: nil, screens: [screen("a"), newScreen])
        #expect(decision == .ready(cameraName: "FaceTime HD Camera", validScreenIDs: ["a"], newScreens: [newScreen], mostRecentCalibration: now))
    }

    @Test func movedScreenIsTreatedAsNew() {
        let now = Date()
        var profile = CameraProfile(cameraID: "cam1", cameraName: "FaceTime HD Camera")
        profile.merge([ScreenCalibration(screenID: "a", frame: frame(0), samples: [sample()], calibratedAt: now)])
        var profiles = SetupProfiles()
        profiles.setProfile(profile)

        let moved = screen("a", 200)   // same screen id, different x origin: the arrangement moved
        let decision = SetupEvaluator.evaluate(profiles: profiles, cameraID: "cam1", cameraName: "FaceTime HD Camera",
                                                previousCameraName: nil, screens: [moved])
        #expect(decision == .ready(cameraName: "FaceTime HD Camera", validScreenIDs: [], newScreens: [moved], mostRecentCalibration: nil))
    }

    @Test func tinyFrameJitterStillCountsAsTheSameScreen() {
        let now = Date()
        var profile = CameraProfile(cameraID: "cam1", cameraName: "FaceTime HD Camera")
        profile.merge([ScreenCalibration(screenID: "a", frame: frame(0), samples: [sample()], calibratedAt: now)])
        var profiles = SetupProfiles()
        profiles.setProfile(profile)

        let jittered = screen("a", 1)   // 1pt off, within tolerance
        let decision = SetupEvaluator.evaluate(profiles: profiles, cameraID: "cam1", cameraName: "FaceTime HD Camera",
                                                previousCameraName: nil, screens: [jittered])
        #expect(decision == .ready(cameraName: "FaceTime HD Camera", validScreenIDs: ["a"], newScreens: [], mostRecentCalibration: now))
    }

    @Test func differentCameraStaysNewCameraEvenWithOtherProfiles() {
        var profiles = SetupProfiles()
        profiles.setProfile(CameraProfile(cameraID: "cam1", cameraName: "FaceTime HD Camera",
                                           screens: [ScreenCalibration(screenID: "a", frame: frame(), samples: [sample()], calibratedAt: Date())]))
        let decision = SetupEvaluator.evaluate(profiles: profiles, cameraID: "cam2", cameraName: "Studio Display Camera",
                                                previousCameraName: "FaceTime HD Camera", screens: [screen("a")])
        #expect(decision == .newCamera(cameraName: "Studio Display Camera", previousCameraName: "FaceTime HD Camera", screenCount: 1))
    }

    @Test func mostRecentCalibrationIsTheLatestAmongValidScreensOnly() {
        let older = Date(timeIntervalSinceNow: -86400)
        let newer = Date()
        var profile = CameraProfile(cameraID: "cam1", cameraName: "FaceTime HD Camera")
        profile.merge([
            ScreenCalibration(screenID: "a", frame: frame(0), samples: [sample()], calibratedAt: older),
            ScreenCalibration(screenID: "b", frame: frame(1920), samples: [sample()], calibratedAt: newer),
        ])
        var profiles = SetupProfiles()
        profiles.setProfile(profile)

        let decision = SetupEvaluator.evaluate(profiles: profiles, cameraID: "cam1", cameraName: "FaceTime HD Camera",
                                                previousCameraName: nil, screens: [screen("a"), screen("b", 1920)])
        guard case .ready(_, _, _, let recent) = decision else { Issue.record("expected .ready"); return }
        #expect(recent == newer)
    }

    @Test func profileMergeReplacesOnlyTheGivenScreens() {
        let t0 = Date(timeIntervalSinceNow: -100)
        var profile = CameraProfile(cameraID: "cam1", cameraName: "FaceTime HD Camera")
        profile.merge([
            ScreenCalibration(screenID: "a", frame: frame(0), samples: [sample(1)], calibratedAt: t0),
            ScreenCalibration(screenID: "b", frame: frame(1920), samples: [sample(2)], calibratedAt: t0),
        ])
        let t1 = Date()
        profile.merge([ScreenCalibration(screenID: "b", frame: frame(1920), samples: [sample(3)], calibratedAt: t1)])

        #expect(profile.calibration(forScreenID: "a")?.calibratedAt == t0)
        #expect(profile.calibration(forScreenID: "b")?.calibratedAt == t1)
        #expect(profile.calibration(forScreenID: "b")?.samples == [sample(3)])
        #expect(profile.screens.count == 2)
    }

    @Test func samplesForCombinesOnlyRequestedScreens() {
        var profile = CameraProfile(cameraID: "cam1", cameraName: "FaceTime HD Camera")
        profile.merge([
            ScreenCalibration(screenID: "a", frame: frame(0), samples: [sample(1), sample(2)], calibratedAt: Date()),
            ScreenCalibration(screenID: "b", frame: frame(1920), samples: [sample(3)], calibratedAt: Date()),
        ])
        #expect(profile.samples(for: ["a"]).count == 2)
        #expect(profile.samples(for: ["a", "b"]).count == 3)
        #expect(profile.samples(for: []).isEmpty)
    }

    @Test func setProfileReplacesByCameraID() {
        var profiles = SetupProfiles()
        profiles.setProfile(CameraProfile(cameraID: "cam1", cameraName: "Old Name"))
        profiles.setProfile(CameraProfile(cameraID: "cam1", cameraName: "New Name"))
        #expect(profiles.cameras.count == 1)
        #expect(profiles.profile(forCameraID: "cam1")?.cameraName == "New Name")
    }

    @Test func codableRoundTrips() throws {
        var profiles = SetupProfiles()
        profiles.setProfile(CameraProfile(cameraID: "cam1", cameraName: "FaceTime HD Camera",
                                           screens: [ScreenCalibration(screenID: "a", frame: frame(), samples: [sample()], calibratedAt: Date())]))
        let data = try JSONEncoder().encode(profiles)
        let decoded = try JSONDecoder().decode(SetupProfiles.self, from: data)
        #expect(decoded == profiles)
    }
}

@Suite struct SetupProfileLegacyTests {
    @Test func migratedScreenWithoutSamplesIsModelOnly() {
        var profile = CameraProfile(cameraID: "cam1", cameraName: "Cam", legacyModel: Data([1]))
        profile.merge([ScreenCalibration(screenID: "a", frame: .zero, samples: [], calibratedAt: Date())])
        #expect(profile.hasModelOnly(["a"]))
        #expect(!profile.hasModelOnly(["b"]))
    }

    @Test func profilesRoundTripThroughJSON() throws {
        var profiles = SetupProfiles()
        var p = CameraProfile(cameraID: "c", cameraName: "Cam", legacyModel: Data([1, 2]))
        p.merge([ScreenCalibration(screenID: "a", frame: CGRect(x: 0, y: 0, width: 10, height: 10),
                                   samples: [CalibrationSample(yaw: 0.1, pitch: 0.2, target: .zero)], calibratedAt: Date(timeIntervalSince1970: 0))])
        profiles.setProfile(p)
        let back = try JSONDecoder().decode(SetupProfiles.self, from: JSONEncoder().encode(profiles))
        #expect(back == profiles)
    }
}
