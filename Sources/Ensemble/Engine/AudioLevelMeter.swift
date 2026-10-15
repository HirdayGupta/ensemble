import AVFoundation
import Foundation

/// Live input level (0...1) for the listening waves, measured only while Claude is dictating. Audio is read from
/// the default input and reduced to a single loudness number on the fly: nothing is stored, sent or recorded.
@MainActor
final class AudioLevelMeter {
    private var engine: AVAudioEngine?
    private var smoothed = 0.0
    var onLevel: ((Double) -> Void)?
    /// False once `stop()` ran: a permission answer that arrives late must not switch the microphone on.
    private var wanted = false

    /// True while the microphone tap is delivering levels (only with the microphone permission).
    var isRunning: Bool { engine != nil }

    func start() {
        wanted = true
        guard engine == nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                if ok { DispatchQueue.main.async { MainActor.assumeIsolated { self.begin() } } }
            }
        default: break      // denied: the waves fall back to their idle animation
        }
    }

    func stop() {
        wanted = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        smoothed = 0
        onLevel?(0)
    }

    private func begin() {
        guard wanted, engine == nil else { return }
        let e = AVAudioEngine()
        let input = e.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(max(n, 1)))
            // -55 dB (quiet room) ... -12 dB (raised voice) mapped to 0...1.
            let db = 20 * log10(max(Double(rms), 1e-7))
            let level = min(max((db + 55) / 43, 0), 1)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.smoothed = level > self.smoothed ? 0.5 * self.smoothed + 0.5 * level : 0.85 * self.smoothed + 0.15 * level
                    self.onLevel?(self.smoothed)
                }
            }
        }
        do { try e.start(); engine = e } catch { input.removeTap(onBus: 0) }
    }
}
