import Foundation

/// When Ensemble reopens itself after Accessibility is granted. macOS applies a new Accessibility grant to a process
/// only when it starts again, so a copy that began without the grant relaunches once, the moment the grant shows.
/// A copy that began with the grant never relaunches for this reason, which is what stops a relaunch loop.
public struct GrantRelaunch: Equatable {
    private let startedWithGrant: Bool
    private var relaunched = false

    public init(startedWithGrant: Bool) { self.startedWithGrant = startedWithGrant }

    /// True exactly once: the first reading that shows the grant in a copy that started without it.
    public mutating func shouldRelaunch(granted: Bool) -> Bool {
        guard !startedWithGrant, !relaunched, granted else { return false }
        relaunched = true
        return true
    }
}
