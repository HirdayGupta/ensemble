import SwiftUI
import SceneKit
import EnsembleCore

/// Hosts the wooden mannequin hand and loops the pose sequence for whichever gesture tab is open. Reduce
/// Motion shows the gesture's resting pose instead of looping (`docs/gotchas.md`, 9: fades are never instant,
/// but Reduce Motion still means static poses here, as the task asks).
struct TourHandView: NSViewRepresentable {
    let tab: TourGestureTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = Self.makeScene(rig: context.coordinator.rig)
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.antialiasingMode = .multisampling4X
        context.coordinator.start(tab: tab, reduceMotion: reduceMotion)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        context.coordinator.start(tab: tab, reduceMotion: reduceMotion)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private static func makeScene(rig: TourHandRig) -> SCNScene {
        let scene = SCNScene()
        scene.rootNode.addChildNode(rig.root)

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 38
        // Three-quarter view from the thumb side (the thumb is on -X), above and ahead, so the thumb tip and
        // the index tip are seen meeting.
        camera.position = SCNVector3(-2.4, 1.0, 2.9)
        camera.look(at: SCNVector3(0, -0.25, 0.55))
        scene.rootNode.addChildNode(camera)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.eulerAngles = SCNVector3(-CGFloat.pi / 3, CGFloat.pi / 5, 0)
        scene.rootNode.addChildNode(key)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 350
        scene.rootNode.addChildNode(ambient)

        return scene
    }

    @MainActor final class Coordinator {
        let rig = TourHandRig()
        private var runningTab: TourGestureTab?
        private var runningReduceMotion: Bool?
        private var task: Task<Void, Never>?

        func start(tab: TourGestureTab, reduceMotion: Bool) {
            guard tab != runningTab || reduceMotion != runningReduceMotion else { return }
            runningTab = tab
            runningReduceMotion = reduceMotion
            task?.cancel()
            guard !reduceMotion else {
                task = nil
                rig.apply(Self.restingPose(for: tab), duration: 0)
                return
            }
            let rig = self.rig
            task = Task { await Self.animate(tab: tab, rig: rig) }
        }

        private static func restingPose(for tab: TourGestureTab) -> TourHandPose {
            switch tab {
            case .look: return .openHand
            case .dictate: return .pinch
            case .send: return .thumbsUp
            case .scroll: return .pinch
            }
        }

        /// One looping keyframe sequence per gesture. Runs until the task is cancelled (the tab changed, or
        /// the view went away).
        @MainActor
        private static func animate(tab: TourGestureTab, rig: TourHandRig) async {
            func hold(_ pose: TourHandPose, _ duration: TimeInterval, _ holdSeconds: Double) async -> Bool {
                rig.apply(pose, duration: duration)
                try? await Task.sleep(nanoseconds: UInt64(holdSeconds * 1_000_000_000))
                return !Task.isCancelled
            }
            while !Task.isCancelled {
                switch tab {
                case .look:
                    guard await hold(.openHand, 0.3, 2.2) else { return }
                case .dictate:
                    guard await hold(.openHand, 0.3, 0.5) else { return }
                    guard await hold(.pinch, 0.22, 0.25) else { return }
                    guard await hold(.openHand, 0.22, 0.2) else { return }
                    guard await hold(.pinch, 0.22, 0.25) else { return }
                    guard await hold(.openHand, 0.3, 1.3) else { return }
                case .send:
                    guard await hold(.openHand, 0.3, 0.5) else { return }
                    guard await hold(.thumbsUp, 0.3, 1.5) else { return }
                    guard await hold(.openHand, 0.3, 0.9) else { return }
                case .scroll:
                    guard await hold(.pinch, 0.3, 0.35) else { return }
                    guard await hold(.pinch.withWristLift(0.18), 0.7, 0.75) else { return }
                    guard await hold(.pinch.withWristLift(-0.18), 0.9, 0.95) else { return }
                    guard await hold(.pinch.withWristLift(0), 0.5, 0.7) else { return }
                    guard await hold(.openHand, 0.3, 0.9) else { return }
                }
            }
        }
    }
}
