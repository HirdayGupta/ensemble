import SceneKit
import AppKit

/// One joint's bend, in radians, for a three-segment finger: base knuckle, middle, tip.
struct FingerCurl {
    var base: Double
    var mid: Double
    var tip: Double
    static let straight = FingerCurl(base: 0, mid: 0, tip: 0)
}

/// A hand pose: how much each finger curls, how the thumb opposes the palm, and where the wrist sits
/// (the scroll gesture moves the wrist, not the fingers). Everything else about the pose follows from these.
struct TourHandPose {
    var index: FingerCurl
    var middle: FingerCurl
    var ring: FingerCurl
    var pinky: FingerCurl
    var thumb: FingerCurl
    /// Rotation swinging the thumb across the palm (toward a pinch) or up and away from it (thumbs-up).
    var thumbOpposition: Double
    /// How far the thumb's base swings forward from the palm's edge (a rotation about the palm's side-to-side axis).
    var thumbSplay: Double = 0.6
    var wristLift: Double

    static let openHand = TourHandPose(
        index: .straight, middle: .straight, ring: .straight, pinky: .straight,
        thumb: .straight, thumbOpposition: 0.3, thumbSplay: 1.2, wristLift: 0)

    /// Solved, not eyeballed: with the rig's real geometry, these angles put the thumb tip within 0.14 of the
    /// index tip (the two tip spheres' radii sum to about 0.16, so they touch). Found by a search over the
    /// index and thumb angles minimising that distance on the built node tree; `TourHandRig.tipGap` measures it.
    static let pinch = TourHandPose(
        index: FingerCurl(base: 0.670, mid: 0.598, tip: 0.720),
        middle: FingerCurl(base: 0.45, mid: 0.7, tip: 0.5),
        ring: FingerCurl(base: 0.55, mid: 0.8, tip: 0.55),
        pinky: FingerCurl(base: 0.65, mid: 0.85, tip: 0.6),
        thumb: FingerCurl(base: 0.859, mid: 0.421, tip: -0.065),
        thumbOpposition: 0.223, thumbSplay: 1.011, wristLift: 0)

    static let thumbsUp = TourHandPose(
        index: FingerCurl(base: 1.15, mid: 1.3, tip: 1.0),
        middle: FingerCurl(base: 1.2, mid: 1.35, tip: 1.05),
        ring: FingerCurl(base: 1.2, mid: 1.35, tip: 1.05),
        pinky: FingerCurl(base: 1.15, mid: 1.3, tip: 1.0),
        thumb: .straight, thumbOpposition: 0, thumbSplay: 0, wristLift: 0)

    func withWristLift(_ lift: Double) -> TourHandPose {
        var p = self
        p.wristLift = lift
        return p
    }
}

/// An articulated wooden mannequin hand built from primitives (a forearm, a palm box, three cylinder-and-
/// sphere segments per finger, a three-segment thumb), in one warm wood material. Poses are applied as
/// eulerAngles on the joint nodes; SceneKit animates the change over `duration` with one easing curve, the
/// SceneKit equivalent of the app's single SwiftUI spring (`docs/gotchas.md`, 9: one motion curve everywhere).
final class TourHandRig {
    let root = SCNNode()
    private let wrist = SCNNode()
    private let thumbBase = SCNNode()
    /// [index, middle, ring, pinky], each [base, mid, tip].
    private var fingerJoints: [[SCNNode]] = []
    private var thumbJoints: [SCNNode] = []
    /// Fingertip markers, used to check (and solve) that a pinch pose really brings the thumb tip to the index tip.
    private(set) var indexTip = SCNNode()
    private(set) var thumbTip = SCNNode()

    private static let woodMaterial: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(calibratedRed: 0.62, green: 0.42, blue: 0.24, alpha: 1)
        m.roughness.contents = 0.6
        m.metalness.contents = 0.0
        return m
    }()

    init() { build() }

    /// Distance between the thumb tip and the index tip in the current (unanimated) pose.
    var tipGap: Double {
        let a = indexTip.worldPosition, b = thumbTip.worldPosition
        return Double(((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z)).squareRoot())
    }

    /// Sets the pose immediately (`duration` 0) or animates to it; call during Reduce Motion with `duration: 0`.
    func apply(_ pose: TourHandPose, duration: TimeInterval) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let fingers = [pose.index, pose.middle, pose.ring, pose.pinky]
        for (i, curl) in fingers.enumerated() {
            fingerJoints[i][0].eulerAngles.x = CGFloat(curl.base)
            fingerJoints[i][1].eulerAngles.x = CGFloat(curl.mid)
            fingerJoints[i][2].eulerAngles.x = CGFloat(curl.tip)
        }
        thumbJoints[0].eulerAngles.x = CGFloat(pose.thumb.base)
        thumbJoints[1].eulerAngles.x = CGFloat(pose.thumb.mid)
        thumbJoints[2].eulerAngles.x = CGFloat(pose.thumb.tip)
        thumbBase.eulerAngles.x = CGFloat(pose.thumbSplay)
        thumbBase.eulerAngles.z = CGFloat(pose.thumbOpposition)
        wrist.position.y = CGFloat(pose.wristLift)
        SCNTransaction.commit()
    }

    private func build() {
        let forearm = SCNNode(geometry: SCNCylinder(radius: 0.32, height: 1.3))
        forearm.geometry?.materials = [Self.woodMaterial]
        forearm.eulerAngles.x = .pi / 2
        forearm.position = SCNVector3(0, 0, -0.9)
        root.addChildNode(forearm)

        wrist.position = SCNVector3(0, 0, -0.25)
        root.addChildNode(wrist)

        let palm = SCNNode(geometry: SCNBox(width: 1.0, height: 0.26, length: 0.9, chamferRadius: 0.08))
        palm.geometry?.materials = [Self.woodMaterial]
        palm.position = SCNVector3(0, 0, 0.2)
        wrist.addChildNode(palm)

        // Four fingers along the front edge of the palm, spread evenly, each pointing forward (+Z).
        let fingerX: [CGFloat] = [-0.36, -0.12, 0.12, 0.36]
        let fingerLengths: [[CGFloat]] = [[0.3, 0.22, 0.16], [0.34, 0.26, 0.18], [0.32, 0.24, 0.17], [0.26, 0.18, 0.14]]
        fingerJoints = fingerX.enumerated().map { i, x in
            let attach = SCNNode()
            attach.position = SCNVector3(x, 0.05, 0.64)
            attach.eulerAngles.x = .pi / 2   // local +Y now points along +Z (forward); a positive curl bends toward -Y, the palm side
            palm.addChildNode(attach)
            let chain = makeChain(from: attach, lengths: fingerLengths[i], radius: 0.07)
            if i == 0 { indexTip = chain.tip }
            return chain.pivots
        }

        // Thumb: its own base node controls opposition (swinging across the palm or up, away from it).
        thumbBase.position = SCNVector3(-0.5, -0.02, 0.28)
        thumbBase.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0.35)
        palm.addChildNode(thumbBase)
        let thumb = makeChain(from: thumbBase, lengths: [0.3, 0.24, 0.18], radius: 0.085)
        thumbJoints = thumb.pivots
        thumbTip = thumb.tip
    }

    /// Builds a chain of pivot nodes under `attach`; rotating pivot `i`'s `eulerAngles.x` bends segment `i`
    /// and everything beyond it, the way a real finger's joints bend one after another.
    private func makeChain(from attach: SCNNode, lengths: [CGFloat], radius: CGFloat) -> (pivots: [SCNNode], tip: SCNNode) {
        var pivots: [SCNNode] = []
        var parent = attach
        for length in lengths {
            let pivot = SCNNode()
            parent.addChildNode(pivot)

            let segment = SCNNode(geometry: SCNCylinder(radius: radius, height: length))
            segment.geometry?.materials = [Self.woodMaterial]
            segment.position = SCNVector3(0, length / 2, 0)
            pivot.addChildNode(segment)

            let joint = SCNNode(geometry: SCNSphere(radius: radius * 1.05))
            joint.geometry?.materials = [Self.woodMaterial]
            joint.position = SCNVector3(0, length, 0)
            pivot.addChildNode(joint)

            let next = SCNNode()
            next.position = SCNVector3(0, length, 0)
            pivot.addChildNode(next)

            pivots.append(pivot)
            parent = next
        }
        return (pivots, parent)
    }
}
