import CoreGraphics
import Foundation
import Testing
@testable import EnsembleCore

/// A desk like the owner's: a flat landscape screen facing the head, and a portrait screen to its left
/// touching its left edge, turned 30 degrees toward the head and reaching above and below it. Head angles
/// come from real 3-D geometry, so the portrait screen's tangent relation to yaw is part of the test.
@Suite struct PerScreenPointerTests {
    static let ppm = 3.66            // points per millimetre on both screens
    static let distance = 600.0      // head to the main screen, mm
    static let mainFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    static let portraitFrame = CGRect(x: -1080, y: -300, width: 1080, height: 1920)

    /// Head angles (yaw negative to the left, pitch positive downward) for a point on a screen.
    static func angles(forMain p: CGPoint) -> (Double, Double) {
        let x = (Double(p.x) - 1280) / ppm, y = (Double(p.y) - 720) / ppm
        return (atan2(x, distance), atan2(y, hypot(x, distance)))
    }

    static func angles(forPortrait p: CGPoint) -> (Double, Double) {
        let along = Double(-p.x) / ppm                      // mm from the hinge, away from the main screen
        let y = (Double(p.y) - 720) / ppm
        let x = -(2560 / 2 / ppm) - along * cos(Double.pi / 6)
        let z = distance - along * sin(Double.pi / 6)
        return (atan2(x, z), atan2(y, hypot(x, z)))
    }

    static func targets(in f: CGRect) -> [CGPoint] {
        let dx = f.width * 0.08, dy = f.height * 0.08
        return [CGPoint(x: f.midX, y: f.midY), CGPoint(x: f.minX + dx, y: f.midY), CGPoint(x: f.maxX - dx, y: f.midY),
                CGPoint(x: f.midX, y: f.minY + dy), CGPoint(x: f.midX, y: f.maxY - dy)]
    }

    static func screens() -> [PointerScreen] {
        [PointerScreen(id: "main", frame: mainFrame, samples: targets(in: mainFrame).map {
            let a = angles(forMain: $0); return CalibrationSample(yaw: a.0, pitch: a.1, target: $0) }),
         PointerScreen(id: "portrait", frame: portraitFrame, samples: targets(in: portraitFrame).map {
            let a = angles(forPortrait: $0); return CalibrationSample(yaw: a.0, pitch: a.1, target: $0) })]
    }

    private func head(_ a: (Double, Double), t: Double = 0) -> HeadObservation {
        HeadObservation(t: t, yaw: a.0, pitch: a.1, faceCount: 1)
    }

    private func near(_ p: CGPoint?, _ want: CGPoint, within tol: Double) -> Bool {
        guard let p else { return false }
        return hypot(p.x - want.x, p.y - want.y) <= tol
    }

    @Test func landsOnTheRightScreenNearTheTargetOnBoth() {
        let p = NosePointer()
        #expect(p.fit(screens: Self.screens()))
        for f in [0.2, 0.4, 0.5, 0.6, 0.8] {
            for g in [0.2, 0.5, 0.8] {
                let m = CGPoint(x: Self.mainFrame.minX + f * 2560, y: Self.mainFrame.minY + g * 1440)
                let r = p.raw(for: head(Self.angles(forMain: m)))
                #expect(near(r, m, within: 60), "main \(m) got \(String(describing: r))")
                let q = CGPoint(x: Self.portraitFrame.minX + f * 1080, y: Self.portraitFrame.minY + g * 1920)
                let s = p.raw(for: head(Self.angles(forPortrait: q)))
                #expect(near(s, q, within: 90), "portrait \(q) got \(String(describing: s))")
                #expect(s.map { Self.portraitFrame.contains($0) } == true)
            }
        }
    }

    @Test func singleMapWouldMissOnThePortraitScreen() {
        // The reason for per-screen models: one affine map over both screens is far off on the portrait one.
        let one = NosePointer()
        #expect(one.fit(Self.screens().flatMap(\.samples)))
        let q = CGPoint(x: Self.portraitFrame.minX + 0.25 * 1080, y: Self.portraitFrame.minY + 0.15 * 1920)
        let miss = one.raw(for: head(Self.angles(forPortrait: q)))!
        let per = NosePointer()
        #expect(per.fit(screens: Self.screens()))
        let hit = per.raw(for: head(Self.angles(forPortrait: q)))!
        #expect(hypot(hit.x - q.x, hit.y - q.y) < hypot(miss.x - q.x, miss.y - q.y))
    }

    @Test func gapAboveTheMainScreenIsNoTarget() {
        let p = NosePointer()
        #expect(p.fit(screens: Self.screens()))
        // 300 points above the main screen's top edge, straight ahead: no screen exists there.
        let above = CGPoint(x: 1280, y: -300)
        #expect(p.raw(for: head(Self.angles(forMain: above))) == nil)
        #expect(p.point(for: head(Self.angles(forMain: above), t: 0)) == nil)
        // Far below likewise.
        #expect(p.raw(for: head(Self.angles(forMain: CGPoint(x: 1280, y: 1900)))) == nil)
        // The same height on the portrait screen is a real target.
        let onPortrait = CGPoint(x: -540, y: -200)
        #expect(near(p.raw(for: head(Self.angles(forPortrait: onPortrait))), onPortrait, within: 90))
    }

    @Test func justOutsideAnEdgeClampsOntoTheScreen() {
        let p = NosePointer()
        #expect(p.fit(screens: Self.screens()))
        let r = p.raw(for: head(Self.angles(forMain: CGPoint(x: 1280, y: -30))))
        #expect(r != nil && Self.mainFrame.contains(r!) && r!.y < 20)
    }

    @Test func switchingScreenDoesNotDragTheSmoothedPointAcrossTheBezel() {
        let p = NosePointer()
        #expect(p.fit(screens: Self.screens()))
        let a = CGPoint(x: 600, y: 700), b = CGPoint(x: -540, y: 700)
        for i in 0..<30 { _ = p.point(for: head(Self.angles(forMain: a), t: Double(i) / 30)) }
        #expect(p.activeScreenID == "main")
        let first = p.point(for: head(Self.angles(forPortrait: b), t: 1.0))
        #expect(p.activeScreenID == "portrait")
        #expect(near(first, b, within: 90))
    }

    @Test func noFlickerWhileHoveringOnTheSharedEdge() {
        let p = NosePointer()
        #expect(p.fit(screens: Self.screens()))
        let seam = Self.angles(forMain: CGPoint(x: 0, y: 700))
        var changes = 0
        var last: String?
        for i in 0..<200 {
            // Jitter of +-0.004 rad around the seam, deterministic.
            let j = 0.004 * sin(Double(i) * 1.7)
            _ = p.point(for: head((seam.0 + j, seam.1), t: Double(i) / 30))
            if let id = p.activeScreenID, id != last { changes += 1; last = id }
        }
        #expect(changes <= 2)
    }

    @Test func oneScreenBehavesLikeTheSingleMap() {
        let main = Self.screens()[0]
        let one = NosePointer(), multi = NosePointer()
        #expect(one.fit(main.samples))
        #expect(multi.fit(screens: [main]))
        for (yaw, pitch) in [(0.0, 0.0), (0.3, -0.2), (-0.9, 0.7), (0.05, 1.2)] {
            let h = HeadObservation(t: 0, yaw: yaw, pitch: pitch, faceCount: 1)
            let a = one.raw(for: h)!, b = multi.raw(for: h)!
            #expect(abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6)
        }
    }

    @Test func legacyModelKeepsWorkingAndPerScreenModelRoundTrips() throws {
        let legacy = NosePointer()
        #expect(legacy.fit(Self.screens()[0].samples))
        let blob = try #require(legacy.calibration)
        let restored = NosePointer()
        restored.calibration = blob
        #expect(restored.isCalibrated && restored.activeScreenID == nil)
        let h = head(Self.angles(forMain: CGPoint(x: 900, y: 500)))
        #expect(restored.raw(for: h) == legacy.raw(for: h))

        let per = NosePointer()
        #expect(per.fit(screens: Self.screens()))
        let data = try #require(per.calibration)
        let back = NosePointer()
        back.calibration = data
        let hp = head(Self.angles(forPortrait: CGPoint(x: -500, y: 400)))
        #expect(back.raw(for: hp) == per.raw(for: hp))
        back.calibration = nil
        #expect(!back.isCalibrated)
    }

    @Test func aScreenThatCannotBeFittedRejectsTheWholeCalibrationAndKeepsTheOld() {
        let p = NosePointer()
        #expect(p.fit(screens: Self.screens()))
        var bad = Self.screens()
        bad[1].samples = Array(bad[1].samples.prefix(3))
        #expect(!p.fit(screens: bad))
        #expect(!p.fit(screens: []))
        #expect(p.raw(for: head(Self.angles(forPortrait: CGPoint(x: -500, y: 400)))) != nil)
    }

    @Test func profilesHandOverEachScreensOwnSamples() {
        var profile = CameraProfile(cameraID: "c", cameraName: "Cam")
        let s = Self.screens()
        profile.merge(s.map { ScreenCalibration(screenID: $0.id, frame: $0.frame, samples: $0.samples, calibratedAt: Date()) })
        profile.merge([ScreenCalibration(screenID: "empty", frame: .zero, samples: [], calibratedAt: Date())])
        #expect(profile.pointerScreens(for: ["main", "portrait", "empty"]) == s)
        #expect(profile.pointerScreens(for: ["portrait"]).map(\.id) == ["portrait"])
    }
}
