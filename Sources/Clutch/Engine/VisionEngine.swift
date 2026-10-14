import AVFoundation
import ClutchCore
import Foundation
import QuartzCore

enum EngineStatus: Equatable {
    case stopped, starting
    case running(fps: Int, camera: String)
    case noCamera, permissionDenied
    case error(String)
    case faceTrackerReady
    case faceTrackerRestarting
    case faceTrackerFailed(String)
}

/// Camera in, observations out: hand pose, head angles and frame brightness for every frame.
/// All callbacks run on the main actor.
@MainActor
final class VisionEngine {
    var onHand: ((HandObservation) -> Void)?
    var onHead: ((HeadObservation) -> Void)?
    var onLight: ((FrameLight) -> Void)?
    var onStatus: ((EngineStatus) -> Void)?
    var onDiagnostic: ((String) -> Void)?

    private(set) var isRunning = false
    /// The face tracker is restarted once after a failure; a good reading re-arms that.
    private var trackerRestarted = false

    private let camera = CameraSession()
    private let face = FaceTracker()
    private let analyzer = FrameAnalyzer()
    nonisolated(unsafe) private var generation = 0
    nonisolated(unsafe) private var cameraLabel = ""
    nonisolated(unsafe) private var fpsWindowStart = 0.0
    nonisolated(unsafe) private var fpsFrames = 0

    init() {
        face.onReady = { [weak self] delegate in
            self?.onDiagnostic?("face tracker ready (\(delegate))")
            self?.onStatus?(.faceTrackerReady)
        }
        face.onFailure = { [weak self] message in self?.trackerFailed(message) }
        face.onHead = { [weak self] head in self?.trackerRestarted = false; self?.onHead?(head) }
        face.onDiagnostic = { [weak self] note in self?.onDiagnostic?(note) }
        camera.onFrame = { [weak self] buffer in self?.process(buffer) }
        camera.onInterrupted = { [weak self] message in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fail(message) } }
        }
    }

    private func trackerFailed(_ message: String) {
        guard isRunning else { return }
        if trackerRestarted {
            onStatus?(.faceTrackerFailed(message))
        } else {
            trackerRestarted = true
            onDiagnostic?("face tracker failed (\(message)); restarting it once")
            onStatus?(.faceTrackerRestarting)
            face.start()
        }
    }

    static func cameraNames() -> [String] { CameraSession.names() }

    /// Starts the camera and the face tracker. Calling it while running restarts with the new camera.
    func start(cameraName: String?) {
        if isRunning { halt() }
        isRunning = true
        trackerRestarted = false
        generation += 1
        fpsWindowStart = 0
        fpsFrames = 0
        let mine = generation
        onStatus?(.starting)
        face.start()
        Task { @MainActor in
            do {
                let name = try await camera.start(named: cameraName)
                guard mine == generation, isRunning else { camera.stop(); return }
                cameraLabel = name
                onStatus?(.running(fps: 0, camera: name))
            } catch {
                guard mine == generation else { return }
                halt()
                switch error as? CameraError {
                case .permissionDenied: onStatus?(.permissionDenied)
                case .noCamera: onStatus?(.noCamera)
                case .failed(let message): onStatus?(.error(message))
                case nil: onStatus?(.error(error.localizedDescription))
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        halt()
        onStatus?(.stopped)
    }

    private func fail(_ message: String) {
        guard isRunning else { return }
        halt()
        onStatus?(.error(message))
    }

    private func halt() {
        isRunning = false
        generation += 1
        camera.stop()
        face.stop()
    }

    // MARK: Camera queue

    nonisolated private func process(_ buffer: CMSampleBuffer) {
        guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        let t = CACurrentMediaTime()
        let mine = generation

        let hand = analyzer.hand(from: buffer, at: t)
        let light = analyzer.light(from: pixels, at: t)

        var jpeg: Data?
        if face.gate.tryEnter(now: t) {
            jpeg = analyzer.jpeg(from: pixels)
            if jpeg == nil { face.gate.leave() }
        }

        if fpsWindowStart == 0 { fpsWindowStart = t }
        fpsFrames += 1
        var fps: Int?
        if t - fpsWindowStart >= 1 {
            fps = Int((Double(fpsFrames) / (t - fpsWindowStart)).rounded())
            fpsWindowStart = t
            fpsFrames = 0
        }
        let label = cameraLabel

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, self.generation == mine else {
                    if jpeg != nil { self?.face.gate.leave() }
                    return
                }
                self.onHand?(hand)
                self.onLight?(light)
                if let jpeg { self.face.submit(jpeg: jpeg, t: t) }
                if let fps { self.onStatus?(.running(fps: fps, camera: label)) }
            }
        }
    }
}
