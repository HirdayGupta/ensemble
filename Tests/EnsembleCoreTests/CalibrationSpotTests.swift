import CoreGraphics
import Foundation
import Testing
@testable import EnsembleCore

/// Several calibrations of the same desk taken from different places (sitting, standing), and recalibrating one
/// screen of several. Readings come from the synthetic desk in `HeadPositionTests`.
@Suite struct CalibrationSpotTests {
    static let sitting: Desk.V = (0, 0, 70)
    static let standing: Desk.V = (0, 35, 70)

    static func samples(_ f: CGRect, from head: Desk.V, _ to: (CGPoint) -> Desk.V) -> [CalibrationSample] {
        Desk.targets(in: f).map {
            let r = Desk.reading(head: head, target: to($0))
            return CalibrationSample(yaw: r.yaw, pitch: r.pitch, target: $0, position: r.position)
        }
    }

    static func screens(from head: Desk.V, spot: String?, only: Set<String> = ["main", "portrait"]) -> [PointerScreen] {
        var out: [PointerScreen] = []
        if only.contains("main") {
            out.append(PointerScreen(id: "main", frame: Desk.mainFrame, samples: samples(Desk.mainFrame, from: head, Desk.desk(main:)),
                                     physicalSize: Desk.mainSize, spotID: spot))
        }
        if only.contains("portrait") {
            out.append(PointerScreen(id: "portrait", frame: Desk.portraitFrame, samples: samples(Desk.portraitFrame, from: head, Desk.desk(portrait:)),
                                     physicalSize: Desk.portraitSize, spotID: spot))
        }
        return out
    }

    static func pointer(_ screens: [PointerScreen]) -> NosePointer {
        let p = NosePointer()
        precondition(p.fit(screens: screens))
        return p
    }

    static func same(_ a: CGPoint?, _ b: CGPoint?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return hypot(a.x - b.x, a.y - b.y) < 1e-6
    }

    @Test func eachPlaceUsesItsOwnCalibration() {
        let both = Self.pointer(Self.screens(from: Self.sitting, spot: "sit") + Self.screens(from: Self.standing, spot: "stand"))
        let sitOnly = Self.pointer(Self.screens(from: Self.sitting, spot: "sit"))
        let standOnly = Self.pointer(Self.screens(from: Self.standing, spot: "stand"))
        for correct in [true, false] {
            both.correctsForPosition = correct; sitOnly.correctsForPosition = correct; standOnly.correctsForPosition = correct
            for aim in Desk.aims() {
                let target = Desk.deskPoint(aim.screen, aim.point)
                let fromSeat = Desk.reading(head: Self.sitting, target: target)
                let fromStanding = Desk.reading(head: Self.standing, target: target)
                #expect(Self.same(both.raw(for: fromSeat), sitOnly.raw(for: fromSeat)), "sitting \(aim.point), correct \(correct)")
                #expect(Self.same(both.raw(for: fromStanding), standOnly.raw(for: fromStanding)), "standing \(aim.point), correct \(correct)")
            }
        }
    }

    @Test func standingWithOnlyASeatedCalibrationMissesWhatTheStandingSpotFixes() {
        // Why a second spot is worth having: standing 35 cm higher with only the seated map, angle-only, misses.
        let sitOnly = Self.pointer(Self.screens(from: Self.sitting, spot: "sit"))
        sitOnly.correctsForPosition = false
        let both = Self.pointer(Self.screens(from: Self.sitting, spot: "sit") + Self.screens(from: Self.standing, spot: "stand"))
        both.correctsForPosition = false
        let aim = CGPoint(x: 1280, y: 720)
        let r = Desk.reading(head: Self.standing, target: Desk.desk(main: aim))
        let seated = sitOnly.raw(for: r).map { Double(hypot($0.x - aim.x, $0.y - aim.y)) } ?? .infinity
        let withSpot = both.raw(for: r).map { Double(hypot($0.x - aim.x, $0.y - aim.y)) } ?? .infinity
        #expect(seated > 200)
        #expect(withSpot < 60)
    }

    @Test func movingBetweenSpotsSwitchesOnceAndReportsTheSpot() {
        let p = Self.pointer(Self.screens(from: Self.sitting, spot: "sit") + Self.screens(from: Self.standing, spot: "stand"))
        let target = Desk.desk(main: CGPoint(x: 1280, y: 720))
        var t = 0.0, switches = 0, last: String?
        func step(_ y: Double) {
            _ = p.point(for: Desk.reading(head: (0, y, 70), target: target, t: t))
            t += 1.0 / 30
            if let s = p.activeSpotID, s != last { if last != nil { switches += 1 }; last = s }
        }
        for _ in 0..<30 { step(0) }
        #expect(p.activeSpotID == "sit")
        // Rise slowly to just past halfway: still the seated calibration, the standing one is not clearly nearer.
        var y = 0.0
        while y < 18 { step(y); y += 0.5 }
        for _ in 0..<30 { step(18) }
        #expect(p.activeSpotID == "sit")
        while y < 35 { step(y); y += 0.5 }
        for _ in 0..<60 { step(35) }
        #expect(p.activeSpotID == "stand")
        #expect(switches == 1)
    }

    @Test func oneScreenFromTwoSpotsIsStillOneScreen() {
        // A one-screen desk points past its edges as a single map does; a second spot must not add the clamp and
        // gap rule that only several screens need.
        let both = Self.pointer(Self.screens(from: Self.sitting, spot: "sit", only: ["main"])
                                + Self.screens(from: Self.standing, spot: "stand", only: ["main"]))
        let sitOnly = Self.pointer(Self.screens(from: Self.sitting, spot: "sit", only: ["main"]))
        let far = Desk.reading(head: Self.sitting, target: Desk.desk(main: CGPoint(x: 3600, y: 720)))
        let got = both.raw(for: far)
        #expect(got != nil)
        #expect(Self.same(got, sitOnly.raw(for: far)))
    }

    @Test func noPositionKeepsTheSpotInUse() {
        let both = Self.pointer(Self.screens(from: Self.sitting, spot: "sit") + Self.screens(from: Self.standing, spot: "stand"))
        let sitOnly = Self.pointer(Self.screens(from: Self.sitting, spot: "sit"))
        // Before any position has been seen: the first spot.
        var r = Desk.reading(head: Self.standing, target: Desk.desk(main: CGPoint(x: 900, y: 500)))
        r.position = nil
        #expect(Self.same(both.raw(for: r), sitOnly.raw(for: r)))
        // Standing, then the position stops arriving for two seconds: the standing calibration stays.
        let target = Desk.desk(main: CGPoint(x: 1280, y: 720))
        var t = 0.0
        for _ in 0..<30 { _ = both.point(for: Desk.reading(head: Self.standing, target: target, t: t)); t += 1.0 / 30 }
        #expect(both.activeSpotID == "stand")
        for _ in 0..<60 {
            var blind = Desk.reading(head: Self.standing, target: target, t: t)
            blind.position = nil
            _ = both.point(for: blind)
            t += 1.0 / 30
        }
        #expect(both.activeSpotID == "stand")
    }

    @Test func savedCalibrationKeepsItsSpots() throws {
        let p = Self.pointer(Self.screens(from: Self.sitting, spot: "sit") + Self.screens(from: Self.standing, spot: "stand"))
        let back = NosePointer()
        back.calibration = try #require(p.calibration)
        let r = Desk.reading(head: Self.standing, target: Desk.desk(main: CGPoint(x: 1600, y: 300)))
        #expect(Self.same(back.raw(for: r), p.raw(for: r)))
        _ = back.point(for: r)
        #expect(back.activeSpotID == "stand")
    }

    @Test func recalibratingOneScreenLeavesTheOthersMapsUntouched() {
        var profile = CameraProfile(cameraID: "c", cameraName: "Cam")
        profile.merge(Self.screens(from: Self.sitting, spot: nil).map {
            ScreenCalibration(screenID: $0.id, frame: $0.frame, samples: $0.samples, calibratedAt: Date())
        })
        let sizes = ["main": Desk.mainSize, "portrait": Desk.portraitSize]
        func fitted(_ profile: CameraProfile) -> NosePointer {
            let p = NosePointer()
            p.screenSizeProvider = { sizes[$0] }
            #expect(p.fit(screens: profile.pointerScreens(for: ["main", "portrait"])))
            return p
        }
        let before = fitted(profile)
        // Only the portrait screen is redone, from a little to the right: the main screen's samples stay.
        let redo = Self.screens(from: (5, 0, 72), spot: nil, only: ["portrait"])[0]
        profile.store([ScreenCalibration(screenID: "portrait", frame: redo.frame, samples: redo.samples, calibratedAt: Date())], inSpot: "spot-1")
        let after = fitted(profile)
        #expect(before.geometry(forScreen: "main") == after.geometry(forScreen: "main"))
        #expect(before.geometry(forScreen: "portrait") != after.geometry(forScreen: "portrait"))
        for aim in Desk.aims() where aim.screen == "main" {
            let r = Desk.reading(head: Self.sitting, target: Desk.deskPoint(aim.screen, aim.point))
            #expect(Self.same(before.raw(for: r), after.raw(for: r)), "main \(aim.point)")
        }
        // The redone screen still lands where it is aimed.
        for aim in Desk.aims() where aim.screen == "portrait" {
            let r = Desk.reading(head: (5, 0, 72), target: Desk.deskPoint(aim.screen, aim.point))
            let got = after.raw(for: r)
            #expect(got.map { hypot($0.x - aim.point.x, $0.y - aim.point.y) < 120 } == true, "portrait \(aim.point)")
        }
    }
}

@Suite struct CalibrationSpotProfileTests {
    private func cal(_ id: String, x: Double = 0, sampleX: Double = 0, at date: Date = Date()) -> ScreenCalibration {
        ScreenCalibration(screenID: id, frame: CGRect(x: x, y: 0, width: 1920, height: 1080),
                          samples: [CalibrationSample(yaw: 0.1, pitch: 0.1, target: CGPoint(x: sampleX, y: 0))], calibratedAt: date)
    }

    /// The shape a profile was saved in before spots existed.
    private struct OldProfile: Codable { var cameraID: String; var cameraName: String; var screens: [ScreenCalibration]; var legacyModel: Data? }
    private struct OldProfiles: Codable { var cameras: [OldProfile] }

    @Test func aProfileSavedBeforeSpotsBecomesTheFirstSpot() throws {
        let screens = [cal("a"), cal("b", x: 1920)]
        let old = OldProfiles(cameras: [OldProfile(cameraID: "cam1", cameraName: "FaceTime HD Camera", screens: screens, legacyModel: Data([7]))])
        let migrated = try JSONDecoder().decode(SetupProfiles.self, from: JSONEncoder().encode(old))
        let profile = try #require(migrated.profile(forCameraID: "cam1"))
        #expect(profile.spots.count == 1)
        #expect(profile.spots[0].id == "spot-1" && profile.spots[0].name == "Position 1")
        #expect(profile.spots[0].screens == screens)
        #expect(profile.legacyModel == Data([7]))
        let decision = SetupEvaluator.evaluate(profiles: migrated, cameraID: "cam1", cameraName: "FaceTime HD Camera", previousCameraName: nil,
                                                screens: [ScreenSnapshot(id: "a", name: "A", frame: screens[0].frame),
                                                          ScreenSnapshot(id: "b", name: "B", frame: screens[1].frame)])
        guard case .ready(_, let valid, let new, _) = decision else { Issue.record("expected .ready"); return }
        #expect(Set(valid) == ["a", "b"] && new.isEmpty)
    }

    @Test func anOlderVersionStillReadsTheFirstSpot() throws {
        let first = cal("a")
        var profile = CameraProfile(cameraID: "cam1", cameraName: "Cam", screens: [first])
        profile.addSpot([cal("a", sampleX: 5)])
        let old = try JSONDecoder().decode(OldProfiles.self, from: JSONEncoder().encode(SetupProfiles(cameras: [profile])))
        #expect(old.cameras[0].screens == [first])
    }

    @Test func spotsRoundTrip() throws {
        var profile = CameraProfile(cameraID: "cam1", cameraName: "Cam", screens: [cal("a")])
        profile.addSpot([cal("a", sampleX: 5), cal("b", x: 1920)])
        let profiles = SetupProfiles(cameras: [profile])
        #expect(try JSONDecoder().decode(SetupProfiles.self, from: JSONEncoder().encode(profiles)) == profiles)
    }

    @Test func storingIntoOneSpotLeavesItsOtherScreensAndOtherSpots() {
        let t0 = Date(timeIntervalSinceNow: -100)
        var profile = CameraProfile(cameraID: "c", cameraName: "Cam", screens: [cal("a", at: t0), cal("b", x: 1920, at: t0)])
        let second = profile.addSpot([cal("a", sampleX: 1, at: t0), cal("b", x: 1920, sampleX: 1, at: t0)])
        #expect(second == "spot-2")
        let redo = cal("a", sampleX: 9)
        profile.store([redo], inSpot: second)
        #expect(profile.spots[1].screens.first { $0.screenID == "a" } == redo)
        #expect(profile.spots[1].screens.first { $0.screenID == "b" }?.calibratedAt == t0)
        #expect(profile.spots[0].screens == [cal("a", at: t0), cal("b", x: 1920, at: t0)])
    }

    @Test func aScreenStoredAtANewFrameDropsOtherSpotsOldCopy() {
        var profile = CameraProfile(cameraID: "c", cameraName: "Cam", screens: [cal("a"), cal("b", x: 1920)])
        let second = profile.addSpot([cal("a"), cal("b", x: 1920)])
        // Screen b moved and was recalibrated from the second spot only.
        profile.store([cal("b", x: 2200)], inSpot: second)
        #expect(profile.spots[0].screens.map(\.screenID) == ["a"])
        #expect(profile.spots[1].screens.map(\.screenID) == ["a", "b"])
        // A frame within the jitter tolerance is the same screen, not a move.
        profile.store([cal("a", x: 1)], inSpot: second)
        #expect(profile.spots[0].screens.map(\.screenID) == ["a"])
    }

    @Test func aScreenOnlyTheSecondSpotCoversIsValid() {
        let older = Date(timeIntervalSinceNow: -86400), newer = Date()
        var profile = CameraProfile(cameraID: "c", cameraName: "Cam", screens: [cal("a", at: older)])
        profile.addSpot([cal("b", x: 1920, at: newer)])
        let decision = SetupEvaluator.evaluate(profiles: SetupProfiles(cameras: [profile]), cameraID: "c", cameraName: "Cam", previousCameraName: nil,
                                                screens: [ScreenSnapshot(id: "a", name: "A", frame: cal("a").frame),
                                                          ScreenSnapshot(id: "b", name: "B", frame: cal("b", x: 1920).frame)])
        #expect(decision == .ready(cameraName: "Cam", validScreenIDs: ["a", "b"], newScreens: [], mostRecentCalibration: newer))
    }

    @Test func pointerScreensComeOncePerSpot() {
        var profile = CameraProfile(cameraID: "c", cameraName: "Cam", screens: [cal("a"), cal("b", x: 1920)])
        profile.addSpot([cal("a", sampleX: 3)])
        let screens = profile.pointerScreens(for: ["a", "b"])
        #expect(screens.map(\.id) == ["a", "b", "a"])
        #expect(screens.map(\.spotID) == ["spot-1", "spot-1", "spot-2"])
        #expect(profile.pointerScreens(for: ["b"]).map(\.spotID) == ["spot-1"])
    }

    @Test func replacingASpotForgetsScreensItDidNotCoverThisTime() {
        var profile = CameraProfile(cameraID: "c", cameraName: "Cam", screens: [cal("a"), cal("b", x: 1920)])
        let second = profile.addSpot([cal("a"), cal("b", x: 1920)])
        profile.replaceSpot(second, with: [cal("a", sampleX: 4)])
        #expect(profile.spots[1].screens.map(\.screenID) == ["a"])
        #expect(profile.spots[0].screens.map(\.screenID) == ["a", "b"])
    }

    @Test func addingAndRemovingSpotsNumbersThemOnward() {
        var profile = CameraProfile(cameraID: "c", cameraName: "Cam", screens: [cal("a")])
        #expect(profile.nextSpot.id == "spot-2" && profile.nextSpot.name == "Position 2")
        let second = profile.addSpot([cal("a")])
        profile.removeSpot("spot-1")
        #expect(profile.spots.map(\.id) == [second])
        profile.removeSpot(second)   // the last spot stays
        #expect(profile.spots.map(\.id) == [second])
        #expect(profile.addSpot([cal("a")]) == "spot-3")
        #expect(profile.screens == profile.spots[0].screens)
    }

    @Test func aFullCalibrationDropsTheMigratedModel() {
        var profile = CameraProfile(cameraID: "c", cameraName: "Cam", legacyModel: Data([1]))
        profile.merge([ScreenCalibration(screenID: "a", frame: .zero, samples: [], calibratedAt: Date())])
        #expect(profile.hasModelOnly(["a"]))
        profile.dropLegacy()
        #expect(profile.legacyModel == nil && profile.spots.isEmpty && !profile.hasModelOnly(["a"]))
    }
}
