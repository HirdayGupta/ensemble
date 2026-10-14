import ClutchCore
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

/// Per-frame work that runs on the camera queue: hand pose, brightness, and the JPEG for the face tracker.
/// Not thread-safe; only the camera queue may call it.
final class FrameAnalyzer: @unchecked Sendable {
    private let detector = HandPoseDetector()
    private let classifier = GestureClassifier()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static let jpegScale: CGFloat = 0.75      // 640x480 -> 480x360
    static let jpegQuality = 0.6


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

    func jpeg(from pixels: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixels).transformed(by: CGAffineTransform(scaleX: Self.jpegScale, y: Self.jpegScale))
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: [quality: Self.jpegQuality])
    }
}
