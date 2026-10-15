import AppKit

/// Global coordinates are top-left origin (Accessibility space); AppKit's are bottom-left, anchored on the
/// primary screen (the first in `NSScreen.screens`). The flip uses the primary screen's height.
enum ScreenGeometry {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func topLeftFrame(of screen: NSScreen) -> CGRect {
        topLeftFrame(ofAppKitFrame: screen.frame, primaryHeight: primaryHeight)
    }

    static func topLeftFrame(ofAppKitFrame frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    static func appKitRect(fromGlobal rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The screen under a global top-left point, falling back to the primary screen.
    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { topLeftFrame(of: $0).contains(point) } ?? NSScreen.screens.first
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// A screen id stable across sleep, wake and reconnection (unlike `CGDirectDisplayID`, which can change).
    /// Falls back to the display id itself for the rare display that has no UUID (some virtual displays).
    static func stableID(of screen: NSScreen) -> String? {
        guard let id = displayID(of: screen) else { return nil }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id) else { return "\(id)" }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }
}
