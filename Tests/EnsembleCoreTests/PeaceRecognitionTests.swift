import CoreGraphics
import Foundation
import Testing
@testable import EnsembleCore

/// A camera-facing hand making a V, image coordinates with the origin bottom-left like Vision's, palm 0.15 tall.
/// `foldTip` is how high the ring and little fingertips sit above the wrist: 0.1 curls them tight under the thumb
/// (reach about 0.5), 0.19 folds them loosely as they fall with the thumb out (reach about 0.95), 0.215 leaves
/// them nearly straight (about 1.07). `vShift` moves the index and middle tips apart.
private func vSign(vShift: Double = 0.035, foldTip: Double = 0.1, thumbOut: Bool = false) -> Hand {
    let wrist = CGPoint(x: 0.5, y: 0.5)
    func at(_ u: Double, _ v: Double) -> CGPoint { CGPoint(x: wrist.x + u, y: wrist.y + v) }
    let span = 0.025, palm = 0.15
    var p: [Joint: CGPoint] = [.wrist: wrist]
    let columns: [(Double, Double?, Joint, Joint, Joint)] = [
        (-1.5 * span, -vShift, .indexMCP, .indexPIP, .indexTip),
        (-0.5 * span, vShift, .middleMCP, .middlePIP, .middleTip),
        (0.5 * span, nil, .ringMCP, .ringPIP, .ringTip),
        (1.5 * span, nil, .littleMCP, .littlePIP, .littleTip),
    ]
    for (u, shift, mcp, pip, tip) in columns {
        p[mcp] = at(u, palm)
        p[pip] = at(u, palm + 0.05)
        p[tip] = shift.map { at(u + $0, palm + 0.11) } ?? at(u, foldTip)
    }
    if thumbOut {
        p[.thumbIP] = at(-3 * span, 0.08)
        p[.thumbTip] = at(-5 * span, 0.12)
    } else {
        p[.thumbIP] = at(-1 * span, 0.10)
        p[.thumbTip] = at(0.5 * span, 0.12)
    }
    return Hand(chirality: .right, points: p, confidence: 1)
}

/// The recorded two-fingers hold, with the index and middle fingers turned `degrees` each away from the other
/// about their knuckles (a real hand opened into a V), and the whole hand scaled about the wrist by `scale` (a
/// hand farther from the camera).
private func reshaped(_ hand: Hand, degrees: Double, scale: Double = 1) -> Hand {
    var p = hand.points
    if degrees != 0, let iTip = p[.indexTip], let mTip = p[.middleTip] {
        for (mcp, chain, other) in [(Joint.indexMCP, [Joint.indexPIP, .indexDIP, .indexTip], mTip),
                                    (Joint.middleMCP, [Joint.middlePIP, .middleDIP, .middleTip], iTip)] {
            guard let c = p[mcp], let tip = p[chain[2]] else { continue }
            func turn(_ q: CGPoint, _ a: Double) -> CGPoint {
                let x = q.x - c.x, y = q.y - c.y
                return CGPoint(x: c.x + x * cos(a) - y * sin(a), y: c.y + x * sin(a) + y * cos(a))
            }
            let a = degrees * .pi / 180
            let sign: Double = hypot(turn(tip, a).x - other.x, turn(tip, a).y - other.y)
                >= hypot(turn(tip, -a).x - other.x, turn(tip, -a).y - other.y) ? 1 : -1
            for j in chain { if let q = p[j] { p[j] = turn(q, sign * a) } }
        }
    }
    if scale != 1, let w = p[.wrist] {
        p = p.mapValues { CGPoint(x: w.x + ($0.x - w.x) * scale, y: w.y + ($0.y - w.y) * scale) }
    }
    return Hand(chirality: hand.chirality, points: p, confidence: hand.confidence)
}

private func widthIntents(_ observations: [HandObservation]) -> [GestureIntent] {
    let machine = GestureMachine()
    return observations.flatMap { machine.push($0) }.filter { $0 == .maximizeSession || $0 == .evenOutSessions }
}

@Suite struct PeaceRecognitionTests {
    private let classifier = GestureClassifier()

    @Test(arguments: [(0.1, false), (0.1, true), (0.19, false), (0.19, true)])
    func aVSignIsTwoFingersWithTheThumbTuckedOrOut(foldTip: Double, thumbOut: Bool) throws {
        let f = try #require(classifier.features(vSign(foldTip: foldTip, thumbOut: thumbOut)))
        #expect(f.gesture == .twoFingers, "fold \(foldTip), thumb out \(thumbOut)")
        #expect(try #require(f.fingerSpread) >= WidthGestures.openSpread)
    }

    @Test func looselyFoldedFingersAreNotCurled() throws {
        // The case the old rule refused: with the thumb out the ring and little fingers fall only part way.
        let f = try #require(classifier.features(vSign(foldTip: 0.19, thumbOut: true)))
        #expect(f.curled < 2)
        #expect(f.twoUp)
    }

    @Test func aNearlyStraightRingAndLittleIsNotTwoFingers() throws {
        let f = try #require(classifier.features(vSign(foldTip: 0.215, thumbOut: true)))
        #expect(f.gesture != .twoFingers)
        #expect(!f.twoUp)
    }

    @Test func aHeldVWithTheThumbOutMaximizes() {
        let hand = vSign(foldTip: 0.19, thumbOut: true)
        let obs = (0..<45).map { HandClassifierAdapter.observation(from: hand, at: 10 + Double($0) / 30, classifier: classifier) }
        #expect(widthIntents(obs) == [.maximizeSession])
    }

    @Test func theRecordedHoldIsFingersSideBySideAndNeverActs() throws {
        let obs = try FixtureReplay.observations("twoFingers-hold")
        let spreads = obs.filter { $0.pose == .twoFingers }.compactMap(\.fingerSpread)
        #expect(spreads.count > 150)
        #expect(spreads.max() ?? 1 < WidthGestures.openSpread)
        #expect(widthIntents(obs).isEmpty)
    }

    /// The recorded hand opened 4 degrees each way (a narrow V, about 17 degrees between the fingers) reads a median
    /// spread near 0.41: under the old 0.42 threshold it rarely opened at all.
    @Test(arguments: [4.0, 8.0, 12.0])
    func theRecordedHandOpenedIntoAVMaximizes(degrees: Double) throws {
        let frames = try FixtureReplay.load("twoFingers-hold")
        let obs = frames.map { f in
            HandClassifierAdapter.observation(from: f.hand.map { reshaped($0, degrees: degrees) }, at: f.t, classifier: classifier)
        }
        let spreads = obs.filter { $0.pose == .twoFingers }.compactMap(\.fingerSpread).sorted()
        #expect(spreads.count > 150)
        #expect(spreads[spreads.count / 2] >= WidthGestures.openSpread)
        let intents = widthIntents(obs)
        #expect(intents.contains(.maximizeSession), "\(degrees) degrees: \(intents)")
        #expect(!intents.contains(.evenOutSessions), "\(degrees) degrees: \(intents)")
    }

    /// Half the size in frame (desk distance with a wide webcam): extent 0.13-0.18, under the open-palm floor of 0.19
    /// that refused every frame before, and still a peace sign.
    @Test func aSmallVAtDeskDistanceIsStillTwoFingers() throws {
        let frames = try FixtureReplay.load("twoFingers-hold")
        var extents: [CGFloat] = []
        let obs = frames.map { f -> HandObservation in
            let hand = f.hand.map { reshaped($0, degrees: 8, scale: 0.5) }
            if let hand, let e = classifier.features(hand)?.extent, classifier.classify(hand) == .twoFingers { extents.append(e) }
            return HandClassifierAdapter.observation(from: hand, at: f.t, classifier: classifier)
        }
        #expect(extents.count > 150)
        #expect(extents.allSatisfy { $0 < classifier.minOpenExtent })
        #expect(widthIntents(obs).contains(.maximizeSession))
    }

    @Test(arguments: ["fist-hold", "openPalm-hold", "thumbsUp-hold", "none-desk-life", "none-dogfood-1052-fist"])
    func noOtherRecordedHandResizesSessions(name: String) throws {
        #expect(widthIntents(try FixtureReplay.observations(name)).isEmpty, "\(name)")
    }
}

/// Two-fingers frames at a given spread, 30 a second, straight into the machine.
private final class Spreads {
    let machine = GestureMachine()
    var t = 10.0
    var widths: [GestureIntent] = []

    func hold(_ spread: Double, for seconds: Double) {
        for _ in 0..<Int((seconds * 30).rounded()) {
            let o = HandObservation(t: t, present: true, pose: .twoFingers, palmCenter: CGPoint(x: 0.5, y: 0.5), pinch: 0.8,
                                    fingerSpread: spread, twoUp: true)
            widths += machine.push(o).filter { $0 == .maximizeSession || $0 == .evenOutSessions }
            t += 1.0 / 30
        }
    }
}

@Suite struct ScissorsCloseTests {
    @Test func aWideVClosingByHalfEvensOut() {
        let s = Spreads()
        s.hold(0.8, for: 0.2)
        s.hold(0.38, for: 0.3)
        #expect(s.widths == [.evenOutSessions])
    }

    @Test func aNarrowVClosingToSideBySideEvensOut() {
        let s = Spreads()
        s.hold(0.40, for: 0.2)
        s.hold(0.27, for: 0.3)
        #expect(s.widths == [.evenOutSessions])
    }

    @Test func aWideVThatOnlySagsStillMaximizes() {
        let s = Spreads()
        s.hold(0.8, for: 0.2)
        s.hold(0.5, for: 1.0)
        #expect(s.widths == [.maximizeSession])
    }

    @Test func aOneFrameSpikeDoesNotRaiseThePeak() {
        // A single misread frame at 1.2 inside a 0.45 V must not make the V itself read as closed.
        let s = Spreads()
        s.hold(0.45, for: 0.1)
        s.hold(1.2, for: 1.0 / 30)
        s.hold(0.45, for: 1.0)
        #expect(s.widths == [.maximizeSession])
    }
}

@Suite struct TwoFingersHoldTests {
    private func frame(_ t: Double, pose: Pose? = .twoFingers, twoUp: Bool = true, spread: Double? = 0.5, gate: PoseGate? = nil,
                       present: Bool = true) -> HandObservation {
        HandObservation(t: t, present: present, pose: pose, palmCenter: nil, fingerSpread: spread, twoUp: twoUp, gate: gate)
    }

    @Test func aHoldIsSummarisedOnceWhenItEnds() throws {
        var hold = TwoFingersHold()
        var lines: [String] = []
        for i in 0..<31 {
            let fired: GestureIntent? = i == 18 ? .maximizeSession : nil
            if let l = hold.push(frame(10 + Double(i) / 30, spread: 0.4 + Double(i % 3) * 0.1), allowed: true, fired: fired) { lines.append(l) }
        }
        #expect(lines.isEmpty)
        for i in 0..<10 {
            if let l = hold.push(frame(11.1 + Double(i) / 30, pose: nil, twoUp: false), allowed: true, fired: nil) { lines.append(l) }
        }
        let line = try #require(lines.first)
        #expect(lines.count == 1)
        #expect(line == "two fingers held 1.0 s, spread min/median/max 0.40/0.50/0.60, read as two fingers 100%, too far 0%, "
                + "angled 0%, held off 0%, peace fired yes, scissors fired no")
    }

    @Test func aRefusedShapeIsCountedByWhatRefusedIt() throws {
        var hold = TwoFingersHold()
        var lines: [String] = []
        for i in 0..<20 {
            let gate: PoseGate = i < 15 ? .tooFar : .angled
            if let l = hold.push(frame(10 + Double(i) / 30, pose: nil, gate: gate), allowed: false, fired: nil) { lines.append(l) }
        }
        if let l = hold.push(frame(11, present: false), allowed: true, fired: nil) { lines.append(l) }
        let line = try #require(lines.first)
        #expect(line.contains("read as two fingers 0%, too far 75%, angled 25%, held off 100%, peace fired no"))
    }

    @Test func aBriefShapeIsNotReported() {
        var hold = TwoFingersHold()
        var lines: [String] = []
        for i in 0..<6 {
            if let l = hold.push(frame(10 + Double(i) / 30), allowed: true, fired: nil) { lines.append(l) }
        }
        if let l = hold.push(frame(11, present: false), allowed: true, fired: nil) { lines.append(l) }
        #expect(lines.isEmpty)
    }

    @Test func theMachineHandsTheLineOutOnce() {
        let machine = GestureMachine()
        for i in 0..<30 {
            _ = machine.push(frame(10 + Double(i) / 30))
        }
        _ = machine.push(frame(11.5, present: false))
        let lines = machine.takeDiagnostics()
        #expect(lines.count == 1)
        #expect(lines.first?.contains("peace fired yes") == true)
        #expect(machine.takeDiagnostics().isEmpty)
    }
}
