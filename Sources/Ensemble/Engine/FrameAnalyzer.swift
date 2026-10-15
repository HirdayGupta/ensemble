import EnsembleCore
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

/// Per-frame work: hand pose, brightness, and the JPEG for the face tracker. Not thread-safe per job: `hand` is
/// called only from the engine's hand queue, `light` and `jpeg` only from the camera queue; they share no state.
final class FrameAnalyzer: @unchecked Sendable {
    private let detector = HandPoseDetector()
    private let classifier = GestureClassifier()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The face tracker gets a frame 320 points wide (320x240 from the usual 640x480), whatever the camera format.
    static let jpegWidth: CGFloat = 320
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

    /// Mean luma (0 to 255) of each cell of a 32 by 24 grid over a BGRA frame, from 8 by 8 pixels spread over the
    /// cell: enough samples that camera noise moves a cell by about a level, for `StillFace`. About 49,000 reads,
    /// a small fraction of the JPEG encode it can save.
    func lumaGrid(from pixels: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return [] }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let columns = 32, rows = 24, samples = 8
        guard width >= columns * samples, height >= rows * samples else { return [] }
        var grid = [Float](repeating: 0, count: columns * rows)
        for r in 0..<rows {
            for sy in 0..<samples {
                let y = (r * samples + sy) * height / (rows * samples)
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for c in 0..<columns {
                    var sum: UInt32 = 0
                    for sx in 0..<samples {
                        let x = (c * samples + sx) * width / (columns * samples)
                        let px = row + x * 4
                        // Integer Rec. 709 weights (out of 256) on B, G, R.
                        sum += 18 * UInt32(px[0]) + 183 * UInt32(px[1]) + 55 * UInt32(px[2])
                    }
                    grid[r * columns + c] += Float(sum) / 256
                }
            }
        }
        let n = Float(samples * samples)
        for i in grid.indices { grid[i] /= n }
        return grid
    }

    func jpeg(from pixels: CVPixelBuffer) -> Data? {
        let scale = Self.jpegWidth / CGFloat(max(CVPixelBufferGetWidth(pixels), 1))
        let image = CIImage(cvPixelBuffer: pixels).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: [quality: Self.jpegQuality])
    }
}
