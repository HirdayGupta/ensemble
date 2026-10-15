import Foundation

/// Picks the camera format and frame rate. The trackers want 640 by 480 (the face tracker gets half of it) at 30
/// frames a second: every frame is a head reading, so the frame rate is how smoothly the nose dot can move. Left to
/// the session preset, a webcam may pick a format that tops out lower, and in dim light it lengthens its exposure
/// and halves the rate; asking for a fixed 30 fps forbids that where the camera honours it.
public enum CameraFormatChoice {
    public struct Format: Equatable, Sendable {
        public var width: Int
        public var height: Int
        /// The highest frame rate any of the format's ranges reaches.
        public var maxRate: Double
        /// A compressed format (MJPEG) costs a decode per frame before the trackers can read it.
        public var compressed: Bool
        public init(width: Int, height: Int, maxRate: Double, compressed: Bool) {
            self.width = width; self.height = height; self.maxRate = maxRate; self.compressed = compressed
        }
    }

    public static let targetRate = 30.0
    public static let width = 640, height = 480
    /// Larger frames cost hand pose more for no tracking gain: nothing above 1280 by 720 is used.
    public static let maxPixels = 1280 * 720

    /// Index of the format to use, or nil to keep the session preset (no format from 640 by 480 to 1280 by 720).
    /// Preference: reaches 30 fps, then the fewest pixels at or above 640 by 480 (exactly 640 by 480 when offered),
    /// then uncompressed.
    public static func pick(_ formats: [Format]) -> Int? {
        let usable = formats.indices.filter {
            let f = formats[$0]
            return f.width >= width && f.height >= height && f.width * f.height <= maxPixels && f.maxRate > 0
        }
        return usable.min { a, b in
            let fa = formats[a], fb = formats[b]
            let fastA = fa.maxRate >= targetRate - 0.5, fastB = fb.maxRate >= targetRate - 0.5
            if fastA != fastB { return fastA }
            if !fastA, fa.maxRate != fb.maxRate { return fa.maxRate > fb.maxRate }
            let pa = fa.width * fa.height, pb = fb.width * fb.height
            if pa != pb { return pa < pb }
            return !fa.compressed && fb.compressed
        }
    }

    /// The frame rate to lock the chosen format to: 30, or the format's best when it cannot reach 30.
    public static func rate(for format: Format) -> Double { min(targetRate, format.maxRate) }
}
