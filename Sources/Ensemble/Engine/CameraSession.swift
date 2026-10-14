import AVFoundation
import Foundation

enum CameraError: Error, Equatable {
    case permissionDenied
    case noCamera
    case failed(String)
}

/// Owns the AVCaptureSession. Frames arrive on `queue`; everything else is serialized on it too.
final class CameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "ensemble.camera", qos: .userInitiated)
    var onFrame: ((CMSampleBuffer) -> Void)?
    var onInterrupted: ((String) -> Void)?
    var onNote: ((String) -> Void)?

    private var session: AVCaptureSession?
    /// Token of the start that owns `session`. Queue-confined.
    private var activeToken = 0
    private var observers: [NSObjectProtocol] = []

    private static let deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]

    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .unspecified).devices
    }

    static func names() -> [String] { devices().map(\.localizedName) }

    /// By name when given and present; otherwise the first external camera, else the built-in one.
    static func pick(named name: String?) -> AVCaptureDevice? {
        let all = devices()
        if let name, let match = all.first(where: { $0.localizedName == name }) { return match }
        return all.first(where: { $0.deviceType == .external }) ?? all.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? all.first
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Builds and starts the session on the camera queue. Returns the camera's name.
    func start(named name: String?, token: Int) async throws -> String {
        guard await Self.requestAccess() else { throw CameraError.permissionDenied }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.startOnQueue(named: name, token: token)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func startOnQueue(named name: String?, token: Int) throws -> String {
        teardownOnQueue()
        activeToken = token
        guard let device = Self.pick(named: name) else { throw CameraError.noCamera }
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.vga640x480) ? .vga640x480 : .high

        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch { throw CameraError.failed(error.localizedDescription) }
        guard session.canAddInput(input) else { throw CameraError.failed("Cannot use camera \(device.localizedName)") }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CameraError.failed("Cannot read frames from \(device.localizedName)") }
        session.addOutput(output)
        session.commitConfiguration()

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self?.onInterrupted?(error?.localizedDescription ?? "Camera error")
            },
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
                self?.onInterrupted?("\(device.localizedName) was disconnected")
            },
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
                self?.onNote?("camera interrupted; frames pause until it ends")
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
                self?.onNote?("camera interruption ended")
            },
        ]

        self.session = session
        session.startRunning()
        guard session.isRunning else {
            teardownOnQueue()
            throw CameraError.failed("Camera \(device.localizedName) did not start")
        }
        return device.localizedName
    }

    /// Stops and releases the session. Queued behind any start in progress, so it never blocks the caller.
    /// With a token, only the session that start created is torn down: a superseded start must not stop a newer one.
    func stop(token: Int? = nil) {
        queue.async {
            if let token, token != self.activeToken { return }
            self.teardownOnQueue()
        }
    }

    private func teardownOnQueue() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let session else { return }
        self.session = nil
        session.stopRunning()
        session.beginConfiguration()
        for output in session.outputs {
            (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            session.removeOutput(output)
        }
        session.inputs.forEach(session.removeInput)
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer)
    }
}
