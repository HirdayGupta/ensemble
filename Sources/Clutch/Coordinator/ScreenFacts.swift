import AppKit
import CoreGraphics

/// Facts about what is on screen, read without Screen Recording permission (window owner and bounds only).
enum ScreenFacts {
    /// Owner pid of the frontmost normal window under a global top-left point, ignoring Clutch's own overlays.
    static func topWindowOwner(at p: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        for w in list {   // front to back
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  CGRect(x: x, y: y, width: width, height: height).contains(p) else { continue }
            return pid
        }
        return nil
    }

    /// A stable description of the current screen arrangement (screen ids and frames).
    static func displayFingerprint() -> String {
        NSScreen.screens.map { s in
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "\(id)"
            let f = s.frame
            return "\(uuid)@\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width))x\(Int(f.height))"
        }.sorted().joined(separator: "|")
    }
}
