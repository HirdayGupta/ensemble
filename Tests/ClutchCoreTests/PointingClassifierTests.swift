import CoreGraphics
import Foundation
import Testing
@testable import ClutchCore

/// Builds a camera-facing hand from landmarks. Image coordinates, origin bottom-left, like Vision's.
/// `angle` rotates the whole hand about the wrist (0 = fingers up, pi = fingers down); `scale` shrinks it.
private func makeHand(index: Bool, middle: Bool = false, ring: Bool = false, little: Bool = false,
                      angle: Double = 0, scale: Double = 1, span: Double = 0.025) -> Hand {
    let wrist = CGPoint(x: 0.5, y: 0.5)
    func place(_ u: Double, _ v: Double) -> CGPoint {
        let (c, s) = (cos(angle), sin(angle))
        return CGPoint(x: wrist.x + scale * (u * c - v * s), y: wrist.y + scale * (u * s + v * c))
    }
    var p: [Joint: CGPoint] = [.wrist: wrist]
    let palm = 0.15
    let columns: [(Double, Bool, Joint, Joint, Joint)] = [
        (-1.5 * span, index, .indexMCP, .indexPIP, .indexTip),
        (-0.5 * span, middle, .middleMCP, .middlePIP, .middleTip),
        (0.5 * span, ring, .ringMCP, .ringPIP, .ringTip),
        (1.5 * span, little, .littleMCP, .littlePIP, .littleTip),
    ]
    for (u, extended, mcp, pip, tip) in columns {
        p[mcp] = place(u, palm)
        p[pip] = place(u, palm + 0.05)
        p[tip] = extended ? place(u, palm + 0.11) : place(u, 0.1)
    }
    p[.thumbIP] = place(-3 * span, 0.12)
    p[.thumbTip] = place(-2.2 * span, 0.14)
    return Hand(chirality: .right, points: p, confidence: 1)
}

@Suite struct PointingClassifierTests {
    private let classifier = GestureClassifier()

    @Test func indexUpWithOthersCurledIsPointUp() {
        #expect(classifier.classify(makeHand(index: true)) == .pointUp)
    }

    @Test func indexDownWithOthersCurledIsPointDown() {
        #expect(classifier.classify(makeHand(index: true, angle: .pi)) == .pointDown)
    }

    @Test func pointingDownIsNotRejectedAsNotUpright() {
        let f = classifier.features(makeHand(index: true, angle: .pi))
        #expect(f?.upright ?? 0 < GestureClassifier.minUpright)
        #expect(f?.angled == false)
    }

    @Test func tiltedStillCountsWhileTheTipIsWellAboveTheKnuckle() {
        #expect(classifier.classify(makeHand(index: true, angle: 0.5)) == .pointUp)
        #expect(classifier.classify(makeHand(index: true, angle: .pi - 0.5)) == .pointDown)
    }

    @Test func sidewaysPointingIsNoPose() {
        #expect(classifier.classify(makeHand(index: true, angle: .pi / 2)) == nil)
        #expect(classifier.classify(makeHand(index: true, angle: -.pi / 2)) == nil)
    }

    @Test func riseBelowHalfAPalmLengthIsNoPose() {
        // The index runs 0.11 above its knuckle on a 0.15 palm: 0.73 palm lengths straight up, times cos(tilt).
        #expect(classifier.classify(makeHand(index: true, angle: 1.0)) == nil)        // 0.40
        #expect(classifier.classify(makeHand(index: true, angle: 0.8)) == .pointUp)   // 0.51
    }

    @Test func middleFingerOutIsNotPointing() {
        #expect(classifier.classify(makeHand(index: true, middle: true)) == .twoFingers)
    }

    @Test func otherPosesAreUnchanged() {
        #expect(classifier.classify(makeHand(index: true, middle: true, ring: true, little: true)) == .openPalm)
        #expect(classifier.classify(makeHand(index: false)) == .fist)
    }

    @Test func middleOrRingOrLittleOutBesideTheIndexIsNotPointing() {
        #expect(classifier.classify(makeHand(index: true, ring: true)) == nil)
        #expect(classifier.classify(makeHand(index: true, little: true)) == nil)
        #expect(classifier.classify(makeHand(index: false, middle: true)) == nil)
    }

    @Test func aTinyHandIsNoPose() {
        let f = classifier.features(makeHand(index: true, scale: 0.35))
        #expect(f?.gesture == nil && f?.tooSmall == true)
    }

    @Test func aForeshortenedHandIsNoPose() {
        // Knuckles spread wider than 0.6 palm lengths: seen at an angle, not facing the camera.
        let f = classifier.features(makeHand(index: true, span: 0.05))
        #expect(f?.gesture == nil && f?.angled == true)
    }

    @Test func adapterMapsPointing() {
        #expect(HandClassifierAdapter.pose(for: .pointUp) == .pointUp)
        #expect(HandClassifierAdapter.pose(for: .pointDown) == .pointDown)
    }
}
