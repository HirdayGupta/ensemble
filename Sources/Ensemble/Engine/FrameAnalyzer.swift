import Accelerate
import EnsembleCore
import CoreMedia
import CoreVideo
import Foundation

/// Per-frame work: hand pose, brightness, and the pixels for the face tracker. Not thread-safe per job: `hand` is
/// called only from the engine's hand queue, `light` and `facePixels` only from the camera queue; they share no state.
final class FrameAnalyzer: @unchecked Sendable {
    private let detector = HandPoseDetector()
    private let classifier = GestureClassifier()

    func hand(from buffer: CMSampleBuffer, at t: TimeInterval) -> HandObservation {
        let h = detector.detect(buffer)
        let obs = HandClassifierAdapter.observation(from: h, at: t, classifier: classifier)
        return obs
    }

    /// Mean and standard deviation of luma over a coarse grid of a BGRA frame.
    func light(from pixels: CVPixelBuffer, at t: TimeInterval) -> FrameLight {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return FrameLight(t: t, meanLuma: 1, lumaStdDev: 1) }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let columns = 40, rows = 30
        var sum = 0.0, sumSquares = 0.0
        for r in 0..<rows {
            let row = base.advanced(by: ((r * height) / rows + height / (2 * rows)) * stride)
            for c in 0..<columns {
                let px = row.advanced(by: (((c * width) / columns) + width / (2 * columns)) * 4).assumingMemoryBound(to: UInt8.self)
                let luma = (0.0722 * Double(px[0]) + 0.7152 * Double(px[1]) + 0.2126 * Double(px[2])) / 255
                sum += luma; sumSquares += luma * luma
            }
        }
        let n = Double(columns * rows)
        let mean = sum / n
        return FrameLight(t: t, meanLuma: mean, lumaStdDev: max(0, sumSquares / n - mean * mean).squareRoot())
    }

    /// The frame for the face tracker: scaled to `FaceFrameSlot.size` and swapped from BGRA to RGBA, tightly packed,
    /// ready to become the page's ImageData. Nil when the frame cannot be read.
    func facePixels(from pixels: CVPixelBuffer) -> (bytes: Data, width: Int, height: Int)? {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
        let (w, h) = FaceFrameSlot.size(cameraWidth: CVPixelBufferGetWidth(pixels), cameraHeight: CVPixelBufferGetHeight(pixels))
        var src = vImage_Buffer(data: base, height: vImagePixelCount(CVPixelBufferGetHeight(pixels)),
                                width: vImagePixelCount(CVPixelBufferGetWidth(pixels)), rowBytes: CVPixelBufferGetBytesPerRow(pixels))
        var bytes = Data(count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            var dst = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            guard vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return false }
            let bgraToRGBA: [UInt8] = [2, 1, 0, 3]
            return vImagePermuteChannels_ARGB8888(&dst, &dst, bgraToRGBA, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
        return ok ? (bytes, w, h) : nil
    }
}
