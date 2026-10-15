import Foundation

/// Skips the face tracker while the picture does not change. Each face frame is first reduced to a coarse grid of
/// luma means (`FrameAnalyzer.lumaGrid`), and `change` is the largest cell difference from the frame last sent to the
/// tracker. After `stillFrames` frames in a row below `threshold` the frame is not sent and the last reading is
/// reused; the first frame at or above it is sent at once, so movement after stillness waits no extra frame.
/// `forceFull` (dictating, a send pending, calibrating, a gesture in progress) always sends.
/// Not thread-safe; one queue owns it.
public struct StillFace {
    public enum Decision: Equatable, Sendable {
        case send
        /// Reuse the last reading; `emit` says whether to hand it on again now (at most every `emitEvery`).
        case reuse(emit: Bool)
    }

    /// Luma levels (0 to 255). Measured from the cell means, which average 64 pixels each, so camera noise stays
    /// near one level; one degree of head turn moves the face's edge by several pixels and its cells by far more.
    public var threshold: Double = 4
    public var stillFrames = 3
    /// A real reading at least this often while still, so a change too small to see here is still caught.
    public var refreshAfter: TimeInterval = 1.0
    /// A reused reading is handed on at most this often: it keeps the nose and presence checks fresh without
    /// waking the main thread on every frame.
    public var emitEvery: TimeInterval = 0.1
    /// Nothing is reused from a reading older than this: a tracker that stopped answering must look stopped.
    public var maxReadingAge: TimeInterval = 1.5
    /// A frame may run this much early, the same as `FrameRatePlanner.slack`.
    public var slack: TimeInterval = 0.012

    private var stillRun = 0
    private var lastSentAt = -TimeInterval.infinity
    private var lastEmitAt = -TimeInterval.infinity

    public init() {}

    /// `change`: from `StillFace.change`, nil when there is no frame to compare with. `lastReadingAt`: when the
    /// tracker last answered, nil before its first answer.
    public mutating func decide(change: Double?, now: TimeInterval, forceFull: Bool, lastReadingAt: TimeInterval?) -> Decision {
        guard !forceFull, let change, change < threshold, let reading = lastReadingAt, now - reading <= maxReadingAge else {
            stillRun = 0
            return .send
        }
        stillRun += 1
        if stillRun < stillFrames || now - lastSentAt >= refreshAfter - slack { return .send }
        let emit = now - lastEmitAt >= emitEvery - slack
        if emit { lastEmitAt = now }
        return .reuse(emit: emit)
    }

    /// The frame `decide` asked to send went to the tracker (it may not have: the tracker can be busy).
    public mutating func sent(at now: TimeInterval) {
        lastSentAt = now
        lastEmitAt = now
    }

    public mutating func reset() {
        self = StillFace()
    }

    /// The largest absolute difference between two luma grids, nil when they are not the same size.
    public static func change(_ a: [Float], _ b: [Float]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var largest: Float = 0
        for i in a.indices { largest = max(largest, abs(a[i] - b[i])) }
        return Double(largest)
    }
}
