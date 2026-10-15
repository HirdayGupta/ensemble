import CoreGraphics
import Foundation
import Testing
@testable import EnsembleCore

/// A camera-facing hand, image coordinates with the origin bottom-left like Vision's, palm 0.15 tall.
/// `tipShift` moves each extended fingertip sideways (index, middle, ring, little), which is how a peace sign
/// opens its fingers into a V. `thumbOnIndex` puts the thumb tip on the index tip (a pinch).
private func hand(index: Bool, middle: Bool, ring: Bool, little: Bool, tipShift: [Double] = [0, 0, 0, 0],
                  thumbUp: Bool = false, thumbOnIndex: Bool = false) -> Hand {
    let wrist = CGPoint(x: 0.5, y: 0.5)
    func at(_ u: Double, _ v: Double) -> CGPoint { CGPoint(x: wrist.x + u, y: wrist.y + v) }
    let span = 0.025, palm = 0.15
    var p: [Joint: CGPoint] = [.wrist: wrist]
    let columns: [(Double, Bool, Joint, Joint, Joint)] = [
        (-1.5 * span, index, .indexMCP, .indexPIP, .indexTip),
        (-0.5 * span, middle, .middleMCP, .middlePIP, .middleTip),
        (0.5 * span, ring, .ringMCP, .ringPIP, .ringTip),
        (1.5 * span, little, .littleMCP, .littlePIP, .littleTip),
    ]
    for (i, (u, extended, mcp, pip, tip)) in columns.enumerated() {
        p[mcp] = at(u, palm)
        p[pip] = at(u, palm + 0.05)
        p[tip] = extended ? at(u + tipShift[i], palm + 0.11) : at(u, 0.1)
    }
    if thumbUp {
        p[.thumbIP] = at(-3 * span, palm + 0.05)
        p[.thumbTip] = at(-3 * span, palm + 0.12)
    } else if thumbOnIndex, let tip = p[.indexTip] {
        p[.thumbIP] = at(-3.5 * span, palm)
        p[.thumbTip] = CGPoint(x: tip.x - 0.004, y: tip.y - 0.004)
    } else {
        p[.thumbIP] = at(-3 * span, 0.12)
        p[.thumbTip] = at(-2.2 * span, 0.14)
    }
    return Hand(chirality: .right, points: p, confidence: 1)
}

private let peace = hand(index: true, middle: true, ring: false, little: false, tipShift: [-0.035, 0.035, 0, 0])
private let fingersTogether = hand(index: true, middle: true, ring: false, little: false)
private let openPalm = hand(index: true, middle: true, ring: true, little: true, tipShift: [-0.02, -0.007, 0.007, 0.02])
private let thumbsUp = hand(index: false, middle: false, ring: false, little: false, thumbUp: true)
private let pointing = hand(index: true, middle: false, ring: false, little: false)
private let pinching = hand(index: false, middle: false, ring: false, little: false, thumbOnIndex: true)
private let pinchWithFingersOut = hand(index: false, middle: true, ring: true, little: true, thumbOnIndex: true)

@Suite struct PeaceClassifierTests {
    private let classifier = GestureClassifier()

    @Test func aPeaceSignIsTwoFingersHeldApart() throws {
        let f = try #require(classifier.features(peace))
        #expect(f.gesture == .twoFingers)
        #expect(try #require(f.fingerSpread) >= WidthGestures.openSpread)
    }

    @Test func fingersSideBySideAreTwoFingersHeldClosed() throws {
        let f = try #require(classifier.features(fingersTogether))
        #expect(f.gesture == .twoFingers)
        #expect(try #require(f.fingerSpread) <= WidthGestures.closedSpread)
    }

    @Test func theAdapterCarriesTheSpread() {
        let o = HandClassifierAdapter.observation(from: peace, at: 1, classifier: classifier)
        #expect(o.pose == .twoFingers)
        #expect((o.fingerSpread ?? 0) >= WidthGestures.openSpread)
    }

    @Test(arguments: [("open palm", openPalm), ("thumbs-up", thumbsUp), ("pointing", pointing),
                      ("pinch", pinching), ("pinch with fingers out", pinchWithFingersOut)])
    func otherHandsAreNeverTwoFingers(_ name: String, _ h: Hand) {
        #expect(classifier.classify(h) != .twoFingers, "\(name)")
    }

    /// The whole path, classifier to machine: two seconds of each other hand ask for no width change, while the
    /// same two seconds of a peace sign do.
    @Test(arguments: [("open palm", openPalm), ("thumbs-up", thumbsUp), ("pointing", pointing),
                      ("pinch", pinching), ("pinch with fingers out", pinchWithFingersOut)])
    func otherHandsNeverResizeSessions(_ name: String, _ h: Hand) {
        #expect(widthIntents(holding: [h]).isEmpty, "\(name)")
    }

    @Test func aHeldPeaceSignMaximizesThroughTheWholePath() {
        #expect(widthIntents(holding: [peace]) == [.maximizeSession])
    }

    @Test func peaceClosedQuicklyEvensOutThroughTheWholePath() {
        #expect(widthIntents(holding: [peace, peace, peace, peace, fingersTogether, fingersTogether, fingersTogether]) == [.evenOutSessions])
    }

    private func widthIntents(holding hands: [Hand]) -> [GestureIntent] {
        let machine = GestureMachine()
        var out: [GestureIntent] = []
        for i in 0..<60 {
            let h = hands[min(i, hands.count - 1)]
            let o = HandClassifierAdapter.observation(from: h, at: 10 + Double(i) / 30, classifier: classifier)
            out += machine.push(o).filter { $0 == .maximizeSession || $0 == .evenOutSessions }
        }
        return out
    }
}

/// Drives the machine with two-fingers frames at a given fingertip spread, 30 frames a second.
private final class SpreadSim {
    let machine: GestureMachine
    var t = 10.0
    var log: [(t: Double, intent: GestureIntent)] = []

    init(mapping: GestureMapping = GestureMapping()) { machine = GestureMachine(mapping: mapping) }

    var widths: [GestureIntent] { log.map(\.intent).filter { $0 == .maximizeSession || $0 == .evenOutSessions } }

    func hold(spread: Double?, for seconds: Double, pose: Pose? = .twoFingers, present: Bool = true) {
        for _ in 0..<Int((seconds * 30).rounded()) {
            let o = HandObservation(t: t, present: present, pose: pose, palmCenter: CGPoint(x: 0.5, y: 0.5), pinch: 0.8,
                                    fingerSpread: spread)
            log += machine.push(o).map { (t, $0) }
            t += 1.0 / 30
        }
    }
}

@Suite struct WidthGestureTimingTests {
    @Test func peaceHeldMaximizesOnceAfterItsHold() throws {
        let s = SpreadSim()
        s.hold(spread: nil, for: 0.2, pose: nil)
        let start = s.t
        s.hold(spread: 0.6, for: 2)
        #expect(s.widths == [.maximizeSession])
        let at = try #require(s.log.first { $0.intent == .maximizeSession }?.t) - start
        #expect(at >= WidthGestures.maximizeHold && at < WidthGestures.maximizeHold + 0.1)
    }

    @Test func peaceClosedWithinTheWindowEvensOutAndNeverMaximizes() {
        let s = SpreadSim()
        s.hold(spread: 0.6, for: 0.3)
        s.hold(spread: 0.15, for: 1.5)
        #expect(s.widths == [.evenOutSessions])
    }

    @Test func peaceClosedAfterMaximizingDoesNotAlsoEvenOut() {
        let s = SpreadSim()
        s.hold(spread: 0.6, for: 1.0)
        s.hold(spread: 0.15, for: 1.0)
        #expect(s.widths == [.maximizeSession])
    }

    @Test func fingersSideBySideNeverAct() {
        let s = SpreadSim()
        s.hold(spread: 0.3, for: 3)
        s.hold(spread: 0.15, for: 1)
        s.hold(spread: 0.3, for: 1)
        #expect(s.widths.isEmpty)
    }

    @Test func aOneFrameSpikeIsNotAPeaceSign() {
        let s = SpreadSim()
        for _ in 0..<5 {
            s.hold(spread: 0.15, for: 0.3)
            s.hold(spread: 0.7, for: 1.0 / 30)
        }
        s.hold(spread: 0.15, for: 1)
        #expect(s.widths.isEmpty)
    }

    @Test func aRelaxingPeaceStillCountsAsOpenUntilItCloses() {
        // Between the two thresholds the open state holds: a V that sags a little keeps counting toward maximize.
        let s = SpreadSim()
        s.hold(spread: 0.6, for: 0.2)
        s.hold(spread: 0.32, for: 0.8)
        #expect(s.widths == [.maximizeSession])
    }

    @Test func otherPosesDoNothing() {
        for pose in Pose.allCases where pose != .twoFingers {
            let s = SpreadSim()
            s.hold(spread: 0.6, for: 0.3, pose: pose)
            s.hold(spread: 0.1, for: 1, pose: pose)
            s.hold(spread: 0.6, for: 2, pose: pose)
            #expect(s.widths.isEmpty, "\(pose)")
        }
    }

    @Test func eachCanBeTurnedOffAlone() {
        let a = SpreadSim()
        a.machine.maximizeByPeace = false
        a.hold(spread: 0.6, for: 2)
        a.hold(spread: 0.1, for: 1)
        a.hold(spread: 0.6, for: 0.3)
        a.hold(spread: 0.1, for: 1)
        #expect(a.widths == [.evenOutSessions])

        let b = SpreadSim()
        b.machine.evenOutByScissors = false
        b.hold(spread: 0.6, for: 0.3)
        b.hold(spread: 0.1, for: 1.5)
        b.hold(spread: 0.6, for: 1.0)
        #expect(b.widths == [.maximizeSession])
    }

    @Test func nothingWhileTwoFingersBelongsToAnotherAction() {
        for slot in [\GestureMapping.send, \.scrollUp, \.scrollDown] as [WritableKeyPath<GestureMapping, Pose?>] {
            var m = GestureMapping()
            m[keyPath: slot] = .twoFingers
            let s = SpreadSim(mapping: m)
            s.hold(spread: 0.6, for: 2)
            s.hold(spread: 0.6, for: 0.3, pose: nil)
            s.hold(spread: 0.6, for: 0.3)
            s.hold(spread: 0.1, for: 1)
            #expect(s.widths.isEmpty)
        }
    }

    @Test func nothingWhileDictatingAndAPeaceHeldAcrossTheEndMustDropFirst() {
        let s = SpreadSim()
        s.machine.beginTalkExternally()
        s.hold(spread: 0.6, for: 1.5)
        s.machine.abortTalk()
        s.hold(spread: 0.6, for: 1.5)
        #expect(s.widths.isEmpty)
        s.hold(spread: nil, for: 0.3, pose: nil)
        s.hold(spread: 0.6, for: 1.0)
        #expect(s.widths == [.maximizeSession])
    }

    @Test func theHandLeavingEndsTheGesture() {
        let s = SpreadSim()
        s.hold(spread: 0.6, for: 0.3)
        s.hold(spread: nil, for: 0.5, present: false)
        s.hold(spread: 0.1, for: 1)
        #expect(s.widths.isEmpty)
    }

    @Test func aBriefDropoutDoesNotEndIt() {
        let s = SpreadSim()
        s.hold(spread: 0.6, for: 0.3)
        s.hold(spread: 0.6, for: 0.1, pose: nil)
        s.hold(spread: 0.1, for: 0.2)
        #expect(s.widths == [.evenOutSessions])
    }

    @Test func aCooldownFollowsEachAction() {
        let s = SpreadSim()
        s.hold(spread: 0.6, for: 0.2)
        s.hold(spread: 0.1, for: 0.1)
        s.hold(spread: 0.6, for: 0.2)
        s.hold(spread: 0.1, for: 0.2)
        #expect(s.widths == [.evenOutSessions])
    }

    @Test func nonFiniteSpreadIsIgnored() {
        let s = SpreadSim()
        s.hold(spread: .nan, for: 2)
        s.hold(spread: .infinity, for: 2)
        #expect(s.widths.isEmpty)
    }

    @Test func resetForgetsAnOpenPeace() {
        let s = SpreadSim()
        s.hold(spread: 0.6, for: 0.3)
        #expect(s.machine.peaceOpen)
        s.machine.reset()
        #expect(!s.machine.peaceOpen)
        s.hold(spread: 0.1, for: 0.5)
        #expect(s.widths.isEmpty)
    }
}

@Suite struct PaneWidthsTests {
    @Test func dividersPairWithTheSplitterAtEachGap() throws {
        // Measured on Claude: four 630 pt panels 10 pt apart, each divider a 12 pt splitter over the gap.
        let panes = [9.0, 649, 1289, 1929].map { CGRect(x: $0, y: 39, width: 630, height: 1309) }
        let splitters = [634.0, 1274, 1914].map { CGRect(x: $0, y: 30, width: 12, height: 1327) }
            + [CGRect(x: 0, y: 30, width: 12, height: 1327), CGRect(x: 446, y: 46, width: 1, height: 16)]
        let d = try #require(PaneWidths.dividers(between: panes, splitters: splitters))
        #expect(d == [640, 1280, 1920])
    }

    @Test func plannedWidthsGiveThePanesTheirNewFrames() throws {
        let panes = [9.0, 649, 1289, 1929].map { CGRect(x: $0, y: 39, width: 630, height: 1309) }
        let frames = try #require(PaneWidths.frames(panes: panes, dividers: [640, 1280, 1920], widths: [316, 1572, 316, 316]))
        #expect(frames.map(\.minX) == [9, 335, 1917, 2243])
        #expect(frames.map(\.width) == [316, 1572, 316, 316])
        #expect(frames[3].maxX == panes[3].maxX)
        #expect(frames.allSatisfy { $0.minY == 39 && $0.height == 1309 })
        // Read back the way `layout` reads a row, the same widths come out.
        let dividers = (0..<3).map { Double(frames[$0].maxX + frames[$0 + 1].minX) / 2 }
        #expect(PaneWidths.layout(panes: frames, dividers: dividers).widths == [316, 1572, 316, 316])
        #expect(PaneWidths.frames(panes: panes, dividers: [640], widths: [630, 630, 630, 630]) == nil)
    }

    @Test func aMissingSplitterIsNoPlan() {
        let panes = [0.0, 853, 1706].map { CGRect(x: $0, y: 30, width: 854, height: 1327) }
        #expect(PaneWidths.dividers(between: panes, splitters: [CGRect(x: 847, y: 30, width: 12, height: 1327)]) == nil)
    }

    @Test func theRowIsTheTargetsWindowSideBySide() {
        let a = ClaudeSession(id: "a", frame: CGRect(x: 853, y: 30, width: 854, height: 1327), windowNumber: 1)
        let b = ClaudeSession(id: "b", frame: CGRect(x: 0, y: 30, width: 854, height: 1327), windowNumber: 1)
        let other = ClaudeSession(id: "c", frame: CGRect(x: 1706, y: 30, width: 854, height: 1327), windowNumber: 2)
        let below = ClaudeSession(id: "d", frame: CGRect(x: 0, y: 1400, width: 854, height: 300), windowNumber: 1)
        #expect(PaneWidths.row(of: a, in: [a, other, below, b]).map(\.id) == ["b", "a"])
    }
}
