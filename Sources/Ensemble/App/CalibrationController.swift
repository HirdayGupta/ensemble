import AppKit
import SwiftUI
import EnsembleCore

@MainActor
final class CalibrationModel: ObservableObject {
    @Published var dot = CGPoint(x: 0, y: 0)
    @Published var dotVisible = false
    @Published var sampling = 0.0          // 0...1 progress of the averaging window
    @Published var headline = "Point your nose at the dot"
    @Published var detail = ""
    @Published var step = ""
    @Published var faceMissing = false
}

/// Full-screen calibration: a dot visits five spots per screen and the head angles are averaged at each.
/// Esc cancels. The completion is called exactly once; an empty array means cancelled or failed.
@MainActor
final class CalibrationController {
    static let shared = CalibrationController()

    private let settleSeconds = 0.8
    private let sampleSeconds = 1.2
    private let minimumSamples = 10
    private let attemptsPerTarget = 3
    private let inset = 0.08

    private let model = CalibrationModel()
    private var window: CalibrationWindow?
    private var task: Task<Void, Never>?
    private var keyMonitor: Any?
    private var completion: (([CalibrationSample]) -> Void)?

    var isRunning: Bool { task != nil }

    func run(headSource: @escaping () -> HeadObservation?, completion: @escaping ([CalibrationSample]) -> Void) {
        guard task == nil else { completion([]); return }
        self.completion = completion
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.cancel()
            return nil
        }
        task = Task { [weak self] in
            guard let self else { return }
            let samples = await self.collect(headSource: headSource)
            self.finish(samples)
        }
    }

    func cancel() {
        task?.cancel()
        finish([])
    }

    private func finish(_ samples: [CalibrationSample]) {
        guard let done = completion else { return }
        completion = nil
        task?.cancel()
        task = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        model.dotVisible = false
        done(samples)
    }

    private func collect(headSource: () -> HeadObservation?) async -> [CalibrationSample] {
        var results: [CalibrationSample] = []
        let screens = NSScreen.screens
        for (index, screen) in screens.enumerated() {
            let frame = ScreenGeometry.topLeftFrame(of: screen)
            present(on: screen)
            model.dotVisible = false
            model.step = screens.count > 1 ? "Screen \(index + 1) of \(screens.count)" : ""
            model.headline = "Point your nose at the dot"
            model.detail = screens.count > 1 && index > 0 ? "Turn to face this screen. Keep your head still and move only your nose." : "Keep your head still and move only your nose."
            guard await pause(seconds: index == 0 ? 1.2 : 2.0) else { return [] }

            let spots = targets(in: frame)
            for (spotIndex, spot) in spots.enumerated() {
                model.dotVisible = true
                model.dot = CGPoint(x: spot.x - frame.minX, y: spot.y - frame.minY)
                model.sampling = 0
                model.faceMissing = false
                model.detail = "Point \(spotIndex + 1) of \(spots.count)"
                guard await pause(seconds: settleSeconds) else { return [] }

                var sample: CalibrationSample?
                for _ in 0..<attemptsPerTarget {
                    switch await average(headSource: headSource, target: spot) {
                    case .cancelled: return []
                    case .sample(let value): sample = value
                    case .tooFew: break
                    }
                    if sample != nil { break }
                    model.faceMissing = true
                    model.detail = "I cannot see your face. Look at the camera."
                    guard await pause(seconds: 1.0) else { return [] }
                }
                guard let sample else { return [] }
                results.append(sample)
            }
        }
        return results
    }

    private enum Averaging {
        case cancelled
        case tooFew
        case sample(CalibrationSample)
    }

    private func average(headSource: () -> HeadObservation?, target: CGPoint) async -> Averaging {
        var yaws: [Double] = []
        var pitches: [Double] = []
        var lastT: TimeInterval = -1
        let start = ContinuousClock.now
        while true {
            if Task.isCancelled { return .cancelled }
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            model.sampling = min(seconds / sampleSeconds, 1)
            if seconds >= sampleSeconds { break }
            if let head = headSource(), head.faceCount == 1, head.t != lastT {
                lastT = head.t
                yaws.append(head.yaw)
                pitches.append(head.pitch)
            }
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        guard yaws.count >= minimumSamples else { return .tooFew }
        return .sample(CalibrationSample(
            yaw: yaws.reduce(0, +) / Double(yaws.count),
            pitch: pitches.reduce(0, +) / Double(pitches.count),
            target: target
        ))
    }

    private func pause(seconds: Double) async -> Bool {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return !Task.isCancelled
    }

    /// Centre, left, right, top, bottom, in global top-left coordinates.
    private func targets(in frame: CGRect) -> [CGPoint] {
        let dx = frame.width * inset
        let dy = frame.height * inset
        return [
            CGPoint(x: frame.midX, y: frame.midY),
            CGPoint(x: frame.minX + dx, y: frame.midY),
            CGPoint(x: frame.maxX - dx, y: frame.midY),
            CGPoint(x: frame.midX, y: frame.minY + dy),
            CGPoint(x: frame.midX, y: frame.maxY - dy),
        ]
    }

    private func present(on screen: NSScreen) {
        window?.orderOut(nil)
        window?.close()
        let next = CalibrationWindow(screen: screen) { [weak self] in self?.cancel() }
        let host = NSHostingView(rootView: CalibrationView(model: model, size: screen.frame.size))
        host.sizingOptions = []
        next.contentView = host
        window = next
        NSApp.activate(ignoringOtherApps: true)
        next.makeKeyAndOrderFront(nil)
    }
}

/// A plain borderless window cannot become key, so it never receives Esc; this one can.
private final class CalibrationWindow: NSWindow {
    private let onEscape: () -> Void

    init(screen: NSScreen, onEscape: @escaping () -> Void) {
        self.onEscape = onEscape
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 0.94)
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onEscape() }
}

private struct CalibrationView: View {
    @ObservedObject var model: CalibrationModel
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 10) {
                if !model.step.isEmpty {
                    Text(model.step).font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.5))
                }
                Text(model.headline).font(.system(size: 30, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                Text(model.detail)
                    .font(.title3)
                    .foregroundStyle(model.faceMissing ? Color.orange : Color.white.opacity(0.65))
            }
            .multilineTextAlignment(.center)
            .frame(width: size.width, height: size.height * 0.5, alignment: .center)
            .offset(y: size.height * 0.18)

            if model.dotVisible {
                TargetDot(progress: model.sampling)
                    .position(model.dot)
                    .animation(.smooth(duration: 0.5), value: model.dot)
            }

            Text("Press Esc to cancel")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: size.width)
                .offset(y: size.height - 56)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

private struct TargetDot: View {
    let progress: Double
    @State private var breathe = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.25))
                .frame(width: breathe ? 84 : 64, height: breathe ? 84 : 64)
            Circle().stroke(.white.opacity(0.25), lineWidth: 4).frame(width: 58, height: 58)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 58, height: 58)
                .rotationEffect(.degrees(-90))
            Circle().fill(.white).frame(width: 22, height: 22).shadow(color: Color.accentColor, radius: 10)
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathe = true } }
    }
}
