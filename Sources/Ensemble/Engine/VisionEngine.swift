import AVFoundation
import EnsembleCore
import Foundation
import os
import QuartzCore

enum EngineStatus: Equatable {
    case stopped, starting
    case running(fps: Int, camera: String, cameraID: String)
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
    /// Owned by the camera queue. Decides which analyses run on each frame.
    nonisolated(unsafe) private var planner = FrameRatePlanner()
    private struct RateHints { var forceFull = false; var lastFaceSeenAt: TimeInterval? }
    private let hints = OSAllocatedUnfairLock(initialState: RateHints())
    nonisolated(unsafe) private var generation = 0
    nonisolated(unsafe) private var cameraLabel = ""
    nonisolated(unsafe) private var cameraID = ""
    nonisolated(unsafe) private var fpsWindowStart = 0.0
    nonisolated(unsafe) private var fpsFrames = 0
    nonisolated(unsafe) private var lastFrameAt = 0.0
    private var cameraStarted = false
    private var requestedCamera: String?
    private var watchdog: Timer?
    private var connectObserver: NSObjectProtocol?
    private static let noFrameLimit = 3.0

    init() {
        connectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.deviceConnected() }
        }
        face.onReady = { [weak self] delegate in
            self?.onDiagnostic?("face tracker ready (\(delegate))")
            self?.onStatus?(.faceTrackerReady)
        }
        face.onFailure = { [weak self] message in self?.trackerFailed(message) }
        face.onHead = { [weak self] head in
            guard let self else { return }
            self.trackerRestarted = false
            if head.faceCount >= 1 { self.hints.withLock { $0.lastFaceSeenAt = CACurrentMediaTime() } }
            self.onHead?(head)
        }
        face.onDiagnostic = { [weak self] note in self?.onDiagnostic?(note) }
        camera.onFrame = { [weak self] buffer in self?.process(buffer) }
        camera.onNote = { [weak self] note in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onDiagnostic?(note) } }
        }
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

    /// True while something needs every hand frame (dictating, a send pending, calibrating, a gesture held).
    func setForceFullRate(_ on: Bool) { hints.withLock { if $0.forceFull != on { $0.forceFull = on } } }

    /// A camera (re)appeared. In automatic mode, a camera the owner would now be picked over the one running
    /// (an external camera just plugged in, say) restarts the session onto it.
    private func deviceConnected() {
        guard isRunning, requestedCamera == nil, let preferred = CameraSession.pick(named: nil), preferred.uniqueID != cameraID else { return }
        onDiagnostic?("a camera connected; switching to \(preferred.localizedName)")
        start(cameraName: nil)
    }

    static func cameraNames() -> [String] { CameraSession.names() }

    /// Starts the camera and the face tracker. Calling it while running restarts with the new camera.
    func start(cameraName: String?) {
        if isRunning { halt() }
        isRunning = true
        cameraStarted = false
        requestedCamera = cameraName
        trackerRestarted = false
        generation += 1
        fpsWindowStart = 0
        fpsFrames = 0
        let mine = generation
        onStatus?(.starting)
        face.start()
        Task { @MainActor in
            do {
                let identity = try await camera.start(named: cameraName, token: mine)
                guard mine == generation, isRunning else { camera.stop(token: mine); return }
                cameraLabel = identity.name
                cameraID = identity.id
                lastFrameAt = CACurrentMediaTime()
                cameraStarted = true
                startWatchdog()
                onStatus?(.running(fps: 0, camera: identity.name, cameraID: identity.id))
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

    /// A camera that stops delivering frames (sleep, an interruption, a USB hiccup) is restarted after 3 s.
    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFrames() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func checkFrames() {
        guard isRunning, cameraStarted else { return }
        let silent = CACurrentMediaTime() - lastFrameAt
        guard silent > Self.noFrameLimit else { return }
        onDiagnostic?("no camera frames for \(Int(silent)) s; restarting the camera")
        start(cameraName: requestedCamera)
    }

    private func halt() {
        isRunning = false
        cameraStarted = false
        watchdog?.invalidate()
        watchdog = nil
        generation += 1
        camera.stop()
        face.stop()
    }

    // MARK: Camera queue

    nonisolated private func process(_ buffer: CMSampleBuffer) {
        guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        let t = CACurrentMediaTime()
        lastFrameAt = t
        let mine = generation

        let hint = hints.withLock { $0 }
        let plan = planner.plan(now: t, forceFull: hint.forceFull, lastFaceSeenAt: hint.lastFaceSeenAt)

        var hand: HandObservation?
        if plan.runHand {
            let h = analyzer.hand(from: buffer, at: t)
            planner.noteHand(present: h.present, at: t)
            hand = h
        }
        let light = plan.runLight ? analyzer.light(from: pixels, at: t) : nil

        var jpeg: Data?
        if plan.runFace, face.gate.tryEnter(now: t) {
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
        let id = cameraID
        if hand == nil, light == nil, jpeg == nil, fps == nil { return }

        // Captured by value: older Swift compilers (6.0, 6.1) reject a captured `var` in this concurrently-executing closure.
        DispatchQueue.main.async { [weak self, hand, light, jpeg, fps] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, self.generation == mine else {
                    if jpeg != nil { self?.face.gate.leave() }
                    return
                }
                if let hand { self.onHand?(hand) }
                if let light { self.onLight?(light) }
                if let jpeg { self.face.submit(jpeg: jpeg, t: t) }
                if let fps { self.onStatus?(.running(fps: fps, camera: label, cameraID: id)) }
            }
        }
    }
}
