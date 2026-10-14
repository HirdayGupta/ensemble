import Foundation

/// Decides whether the camera lens is covered (a deliberate privacy gesture) from frame brightness.
public final class CoverDetector {
    public private(set) var covered = false

    private var darkSince: TimeInterval?
    private var brightSince: TimeInterval?

    public init() {}

    /// Returns the new state when it changes, otherwise nil.
    public func push(_ l: FrameLight) -> Bool? {
        let dark = l.meanLuma < 0.08 && l.lumaStdDev < 0.04
        let bright = l.meanLuma > 0.12
        darkSince = dark ? (darkSince ?? l.t) : nil
        brightSince = bright ? (brightSince ?? l.t) : nil
        if !covered, let since = darkSince, l.t - since >= 1.5 {
            covered = true
            return true
        }
        if covered, let since = brightSince, l.t - since >= 1.0 {
            covered = false
            return false
        }
        return nil
    }
}
