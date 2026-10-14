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

    private var lastDiag: TimeInterval = 0
    private var lastPinchLog: TimeInterval = 0

    func hand(from buffer: CMSampleBuffer, at t: TimeInterval) -> HandObservation {
        let h = detector.detect(buffer)
        // Twice a second while a hand is in view, log why it was or wasn't read as a pose (numbers only).
        if let h, t - lastDiag >= 0.5, let f = classifier.features(h) {
            lastDiag = t
            // Fingertip cluster, for the "gather" (all fingertips pinched together) gesture being tuned.
            let tips: [Joint] = [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]
            let pts = tips.compactMap { h[$0] }
            var spread = -1.0, reach = -1.0
            if pts.count == 5, let w = h[.wrist], let m = h[.middleMCP] {
                let palm = Double(hypot(w.x - m.x, w.y - m.y))
                var maxD = 0.0
                for i in 0..<5 { for j in (i + 1)..<5 { maxD = max(maxD, Double(hypot(pts[i].x - pts[j].x, pts[i].y - pts[j].y))) } }
                let cx = pts.map(\.x).reduce(0, +) / 5, cy = pts.map(\.y).reduce(0, +) / 5
                spread = palm > 0 ? maxD / palm : -1
                reach = palm > 0 ? Double(hypot(cx - w.x, cy - w.y)) / palm : -1
            }
            ClutchLog.write(String(format: "gather: tipSpread=%.2f tipReach=%.2f", spread, reach))
            ClutchLog.write(String(format: "hand: pose=%@ curled=%d ext=%d tipReach=%.2f thumbStraight=%d thumbClear=%d thumbUp=%d span=%.2f upright=%.2f extent=%.2f tooSmall=%d angled=%d joints=%d",
                f.gesture?.rawValue ?? "-", f.curled, f.extendedCount, f.tipReach, f.thumbStraight ? 1 : 0, f.thumbClear ? 1 : 0, f.thumbUp ? 1 : 0,
                f.span, f.upright, f.extent, f.tooSmall ? 1 : 0, f.angled ? 1 : 0, h.points.count))
        }
        let obs = HandClassifierAdapter.observation(from: h, at: t, classifier: classifier)
        // While tuning the double tap: twice a second while the fingertips are near each other.
        if let p = obs.pinch, p < 0.5, t - lastPinchLog >= 0.5 { lastPinchLog = t; ClutchLog.write(String(format: "pinch: %.2f", p)) }
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
