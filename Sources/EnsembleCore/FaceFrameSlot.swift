import Foundation

/// The one camera frame waiting for the face tracker page, as raw RGBA. The engine puts a frame in under a number
/// and asks the page to fetch that number; the page's request takes it out, so memory holds at most one frame and a
/// late request for an older number gets nothing instead of the wrong frame. Raw pixels replaced a JPEG sent as
/// base64 text: no encode in the app, no decode in the page (docs/performance.md).
public final class FaceFrameSlot: @unchecked Sendable {
    /// The face tracker gets frames this many pixels wide, whatever the camera format.
    public static let width = 320

    private let lock = NSLock()
    private var number = 0
    private var waiting: (number: Int, bytes: Data)?

    public init() {}

    /// The frame size sent for a camera frame: 320 wide, height kept in proportion and even, at least 2.
    public static func size(cameraWidth: Int, cameraHeight: Int) -> (width: Int, height: Int) {
        guard cameraWidth > 0, cameraHeight > 0 else { return (width, width * 3 / 4) }
        let h = Int((Double(cameraHeight) * Double(width) / Double(cameraWidth) / 2).rounded()) * 2
        return (width, max(2, h))
    }

    /// Stores a frame, replacing any frame not yet fetched, and returns the number the page must ask for.
    public func put(_ bytes: Data) -> Int {
        lock.lock(); defer { lock.unlock() }
        number &+= 1
        waiting = (number, bytes)
        return number
    }

    /// Hands out the frame stored under `number` and empties the slot; nil when that frame was replaced or already taken.
    public func take(_ number: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let w = waiting, w.number == number else { return nil }
        waiting = nil
        return w.bytes
    }

    /// Drops any frame waiting, so a stopped tracker holds no pixels.
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        waiting = nil
    }

    /// The request path the page fetches for a frame number: `/frame/<number>`.
    public static func path(for number: Int) -> String { "/frame/\(number)" }

    /// The frame number in a request path, or nil when the path is not a frame request.
    public static func number(inPath path: String) -> Int? {
        let prefix = "/frame/"
        guard path.hasPrefix(prefix) else { return nil }
        return Int(path.dropFirst(prefix.count))
    }
}
