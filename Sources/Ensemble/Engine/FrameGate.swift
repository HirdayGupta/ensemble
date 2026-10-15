import Foundation
import QuartzCore

/// Lets the camera queue ask, without hopping to the main actor, whether the face tracker can take
/// another frame. Only one frame is in flight at a time; a frame that never answers is written off
/// after `timeout` so a wedged page cannot stall tracking forever.
final class FrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var busySince: TimeInterval?
    /// Frames turned away since the frame in flight went out: each is a head reading the dot never gets.
    private var skipped = 0
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 2) { self.timeout = timeout }

    func setOpen(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        open = value
        busySince = nil
        skipped = 0
    }

    func tryEnter(now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard open else { return false }
        if let since = busySince, now - since < timeout { skipped += 1; return false }
        busySince = now
        skipped = 0
        return true
    }

    /// Releases the gate. Returns how long the frame held it and how many frames were turned away meanwhile, for
    /// the detailed trace; nil when nothing was in flight.
    @discardableResult
    func leave(now: TimeInterval = CACurrentMediaTime()) -> (held: TimeInterval, skipped: Int)? {
        lock.lock(); defer { lock.unlock() }
        defer { busySince = nil; skipped = 0 }
        return busySince.map { (now - $0, skipped) }
    }
}
