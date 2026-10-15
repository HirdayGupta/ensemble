import CoreGraphics
import Foundation
import Testing
@testable import EnsembleCore

/// A synthetic desk in centimetres. Desk axes: X to the user's right, Y up, Z from the screens toward the user.
/// The camera sits on top of the landscape monitor looking at the user, so camera space is the desk turned half
/// a turn about the vertical axis (x = -X, z = -Z), the way MediaPipe's matrix reports it. Readings come from
/// real ray geometry, never from the model under test.
///
///   main:     2560x1440 points, 59.7 x 33.6 cm, flat, centred on X = 0, the user 70 cm from it.
///   portrait: 1080x1920 points, 29.9 x 53.2 cm, hinged at the main monitor's left edge (3 cm gap) and turned
///             30 degrees toward the user, as in the owner's setup.
struct Desk {
    static let mainFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    static let portraitFrame = CGRect(x: -1080, y: -240, width: 1080, height: 1920)
    static let mainSize = CGSize(width: 59.7, height: 33.6)
    static let portraitSize = CGSize(width: 29.9, height: 53.2)
    static let cameraHeight = 18.3          // above the main monitor's centre
    static let hingeX = -(59.7 / 2 + 3)
    static let angle = Double.pi / 6

    typealias V = (x: Double, y: Double, z: Double)

    /// A point on a screen, in desk centimetres.
    static func desk(main p: CGPoint) -> V {
        let k = mainSize.width / 2560
        return ((Double(p.x) - 1280) * k, -(Double(p.y) - 720) * k, 0)
    }

    static func desk(portrait p: CGPoint) -> V {
        let k = portraitSize.width / 1080
        let along = -Double(p.x) * k                                  // cm from the hinge, away from the main monitor
        return (hingeX - along * cos(angle), -(Double(p.y) - 720) * k, along * sin(angle))
    }

    static func unit(_ v: V) -> V { let l = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot(); return (v.x / l, v.y / l, v.z / l) }

    /// The reading a head at `head` (desk cm) produces when its forward direction points at `target`.
    /// `sway` makes the reported head position sit off the aim line the way a face does when the neck turns.
    static func reading(head: V, target: V, sway: Bool = false, t: Double = 0) -> HeadObservation {
        var origin = head
        var d = unit((target.x - head.x, target.y - head.y, target.z - head.z))
        if sway {
            // The face origin is 10 cm in front of a neck pivot at `head` and 3 cm to the side of the line.
            for _ in 0..<12 {
                let side = unit((d.z, 0, -d.x))
                origin = (head.x + 10 * d.x + 3 * side.x, head.y + 10 * d.y, head.z + 10 * d.z + 3 * side.z)
                d = unit((target.x - origin.x, target.y - origin.y, target.z - origin.z))
            }
        }
        let c = (x: -d.x, y: d.y, z: -d.z)
        return HeadObservation(t: t, yaw: atan2(c.x, c.z), pitch: asin(c.y), faceCount: 1,
                               position: HeadPosition(x: -origin.x, y: origin.y - cameraHeight, z: -origin.z))
    }

    static func targets(in f: CGRect) -> [CGPoint] {
        let dx = f.width * 0.08, dy = f.height * 0.08
        return [CGPoint(x: f.midX, y: f.midY), CGPoint(x: f.minX + dx, y: f.midY), CGPoint(x: f.maxX - dx, y: f.midY),
                CGPoint(x: f.midX, y: f.minY + dy), CGPoint(x: f.midX, y: f.maxY - dy)]
    }

    /// The pointer calibrated the way the app does: five dots per screen from `head`.
    static func calibratedPointer(head: V = (0, 0, 70), sway: Bool = false, withPosition: Bool = true) -> NosePointer {
        func samples(_ f: CGRect, _ to: (CGPoint) -> V) -> [CalibrationSample] {
            targets(in: f).map {
                let r = reading(head: head, target: to($0), sway: sway)
                return CalibrationSample(yaw: r.yaw, pitch: r.pitch, target: $0, position: withPosition ? r.position : nil)
            }
        }
        let p = NosePointer()
        let ok = p.fit(screens: [
            PointerScreen(id: "main", frame: mainFrame, samples: samples(mainFrame, desk(main:)), physicalSize: mainSize),
            PointerScreen(id: "portrait", frame: portraitFrame, samples: samples(portraitFrame, desk(portrait:)), physicalSize: portraitSize),
        ])
        precondition(ok)
        return p
    }

    /// Centres and corners of a session on each monitor, plus edge middles: a 3 x 3 grid at 10%, 50%, 90%.
    static func aims() -> [(screen: String, point: CGPoint)] {
        var out: [(String, CGPoint)] = []
        for (name, f) in [("main", mainFrame), ("portrait", portraitFrame)] {
            for fy in [0.1, 0.5, 0.9] { for fx in [0.1, 0.5, 0.9] {
                out.append((name, CGPoint(x: f.minX + f.width * fx, y: f.minY + f.height * fy)))
            } }
        }
        return out
    }

    static func deskPoint(_ screen: String, _ p: CGPoint) -> V { screen == "main" ? desk(main: p) : desk(portrait: p) }
}

@Suite struct HeadPositionTests {
    static let places: [(name: String, head: Desk.V)] = [
        ("30 cm left", (-30, 0, 70)), ("60 cm left", (-60, 0, 70)), ("90 cm left", (-90, 0, 70)),
        ("30 cm right", (30, 0, 70)), ("60 cm right", (60, 0, 70)), ("90 cm right", (90, 0, 70)),
        ("20 cm back", (0, 0, 90)),
    ]

    /// Worst miss per monitor over every aim at `head`, in points. A reading that gives no target (the pointer
    /// fell off every screen) counts as an infinite miss and is also counted in `lost`; `landed` is the worst
    /// miss among the aims that did land on a screen.
    struct Miss {
        var main = 0.0, portrait = 0.0, lost = 0, landed = 0.0
        var total = 0
    }

    static func worstMiss(_ pointer: NosePointer, head: Desk.V, sway: Bool = false) -> Miss {
        var worst = Miss()
        for aim in Desk.aims() {
            let r = Desk.reading(head: head, target: Desk.deskPoint(aim.screen, aim.point), sway: sway)
            let got = pointer.raw(for: r)
            let miss = got.map { Double(hypot($0.x - aim.point.x, $0.y - aim.point.y)) } ?? .infinity
            if aim.screen == "main" { worst.main = max(worst.main, miss) } else { worst.portrait = max(worst.portrait, miss) }
            worst.total += 1
            if got == nil { worst.lost += 1 } else { worst.landed = max(worst.landed, miss) }
        }
        return worst
    }

    @Test func geometryRecoversTheDesk() throws {
        let p = Desk.calibratedPointer()
        let main = try #require(p.geometry(forScreen: "main")), portrait = try #require(p.geometry(forScreen: "portrait"))
        // The camera is mirrored against the desk, so a screen turned toward the user's side has the opposite sign.
        #expect(abs(main.theta) < 0.02)
        #expect(abs(main.distance - 70) < 1.5)
        #expect(abs(abs(portrait.theta) - Desk.angle) < 0.03)
        #expect(main.residual < 0.5 && portrait.residual < 0.5)
    }

    @Test func correctionKeepsPointingAtEveryPosition() {
        let p = Desk.calibratedPointer()
        var lines = ["position        without correction: lost / worst landed miss    with correction: worst miss main / portrait (pt)"]
        for place in Self.places {
            p.correctsForPosition = false
            let before = Self.worstMiss(p, head: place.head)
            p.correctsForPosition = true
            let after = Self.worstMiss(p, head: place.head)
            lines.append(String(format: "%-14@  %2d of %d lost, worst landed %5.0f pt          %5.1f / %5.1f", place.name as NSString, before.lost, before.total, before.landed, after.main, after.portrait))
            #expect(after.main <= 80, "main at \(place.name): \(after.main)")
            #expect(after.portrait <= 120, "portrait at \(place.name): \(after.portrait)")
            #expect(before.lost > 0 || before.landed > 200, "without correction \(place.name) should miss badly")
            #expect(after.lost == 0)
        }
        print(lines.joined(separator: "\n"))
    }

    @Test func calibrationSpotIsUnchanged() {
        let p = Desk.calibratedPointer()
        for aim in Desk.aims() {
            let r = Desk.reading(head: (0, 0, 70), target: Desk.deskPoint(aim.screen, aim.point))
            p.correctsForPosition = false
            let before = p.raw(for: r)
            p.correctsForPosition = true
            let after = p.raw(for: r)
            #expect(before != nil && after != nil)
            if let b = before, let a = after { #expect(hypot(a.x - b.x, a.y - b.y) < 1e-6) }
        }
    }

    @Test func turningTheHeadAtTheCalibrationSpotIsNotMovement() {
        // The reported position swings a few centimetres as the neck turns; that must not shift the pointer.
        let p = Desk.calibratedPointer(sway: true)
        var shift = 0.0
        for aim in Desk.aims() {
            let r = Desk.reading(head: (0, 0, 70), target: Desk.deskPoint(aim.screen, aim.point), sway: true)
            p.correctsForPosition = true
            let with = p.raw(for: r)
            p.correctsForPosition = false
            let without = p.raw(for: r)
            guard let a = with, let b = without else { Issue.record("lost an aim at the calibration spot"); continue }
            shift = max(shift, Double(hypot(a.x - b.x, a.y - b.y)))
        }
        print("head turning at the calibration spot: correction moves the pointer by at most \(shift) pt")
        #expect(shift < 5)
    }

    @Test func swayDoesNotBreakMovingAround() {
        let p = Desk.calibratedPointer(sway: true)
        for place in Self.places {
            p.correctsForPosition = true
            let after = Self.worstMiss(p, head: place.head, sway: true)
            print("sway \(place.name): \(Int(after.main)) / \(Int(after.portrait)) pt")
            #expect(after.main <= 100 && after.portrait <= 150, "\(place.name): \(after)")
        }
    }

    @Test func oldCalibrationWithoutPositionsPointsAsBefore() {
        let old = Desk.calibratedPointer(withPosition: false)
        #expect(old.geometry(forScreen: "main") == nil)
        let r = Desk.reading(head: (60, 0, 70), target: Desk.desk(main: CGPoint(x: 1280, y: 720)))
        let corrected = old.raw(for: r)
        old.correctsForPosition = false
        #expect(corrected == old.raw(for: r))
    }

    @Test func readingWithoutPositionPointsAsBefore() {
        let p = Desk.calibratedPointer()
        var r = Desk.reading(head: (0, 0, 70), target: Desk.desk(main: CGPoint(x: 900, y: 500)))
        r.position = nil
        let with = p.raw(for: r)
        p.correctsForPosition = false
        #expect(with == p.raw(for: r))
    }

    @Test func calibrationSurvivesSaveAndLoad() throws {
        let p = Desk.calibratedPointer()
        let blob = try #require(p.calibration)
        let q = NosePointer()
        q.calibration = blob
        let r = Desk.reading(head: (60, 0, 70), target: Desk.desk(portrait: CGPoint(x: -540, y: 720)))
        #expect(q.raw(for: r) == p.raw(for: r))
        #expect(q.geometry(forScreen: "main") == p.geometry(forScreen: "main"))
    }

    @Test func oldSampleJSONDecodesWithoutPosition() throws {
        let json = #"{"yaw":0.1,"pitch":-0.2,"target":[10,20]}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(CalibrationSample.self, from: json)
        #expect(s.position == nil && s.yaw == 0.1)
    }

    @Test func implausibleTranslationsAreIgnored() {
        var t = HeadPositionTracker()
        let ok = HeadPosition(x: 0, y: 0, z: -70)
        #expect(t.update(ok, at: 0) == ok)
        // A 40 cm jump between consecutive readings is a glitch: the last position stands.
        let glitch = HeadPosition(x: 40, y: 0, z: -70)
        for i in 1..<9 { #expect(t.update(glitch, at: Double(i) * 0.07) == ok) }
        // A face on the lens, a non-number, and no position at all.
        #expect(!HeadPositionTracker.isPlausible(HeadPosition(x: 0, y: 0, z: -2)))
        #expect(!HeadPositionTracker.isPlausible(HeadPosition(x: .nan, y: 0, z: -70)))
        #expect(t.update(nil, at: 0.7) == ok)
        // A position that stays put for a second is the user having moved: accept it.
        var moved: HeadPosition?
        for i in 9..<30 { moved = t.update(glitch, at: Double(i) * 0.07) }
        #expect(moved != nil && abs(moved!.x - 40) < 1)
        // After more than a second without a face the old position is not carried forward.
        #expect(t.update(nil, at: 10) == nil)
    }

    @Test func positionSmoothingAddsLittleJitter() {
        var t = HeadPositionTracker()
        var rng = SystemRandomNumberGenerator()
        var rawSpread = 0.0, smoothSpread = 0.0
        var last: HeadPosition?
        for i in 0..<300 {
            let noise = Double.random(in: -0.4...0.4, using: &rng)
            let out = t.update(HeadPosition(x: 20 + noise, y: 0, z: -70), at: Double(i) / 15)!
            if i > 30 { rawSpread = max(rawSpread, abs(noise)); smoothSpread = max(smoothSpread, abs(out.x - 20)) }
            last = out
        }
        #expect(smoothSpread < rawSpread)
        #expect(abs(last!.x - 20) < 0.4)
    }

    @Test func filteredPointFollowsAfterMoving() {
        let p = Desk.calibratedPointer()
        let aim = CGPoint(x: 1800, y: 400)
        var got: CGPoint?
        for i in 0..<60 {
            let r = Desk.reading(head: (60, 0, 70), target: Desk.desk(main: aim), t: Double(i) / 15)
            got = p.point(for: r)
        }
        #expect(got != nil && hypot(got!.x - aim.x, got!.y - aim.y) < 80)
    }
}
