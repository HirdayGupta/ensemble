import Foundation

/// Lets the camera queue ask, without hopping to the main actor, whether the face tracker can take
/// another frame. Only one frame is in flight at a time; a frame that never answers is written off
/// after `timeout` so a wedged page cannot stall tracking forever.
final class FrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var busySince: TimeInterval?
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 2) { self.timeout = timeout }

    func setOpen(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        open = value
        busySince = nil
    }

    func tryEnter(now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard open else { return false }
        if let since = busySince, now - since < timeout { return false }
        busySince = now
        return true
    }

    func leave() {
        lock.lock(); defer { lock.unlock() }
        busySince = nil
    }
}
