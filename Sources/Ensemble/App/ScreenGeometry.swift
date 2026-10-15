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

    /// The physical size in centimetres of the connected screen with this stable id. macOS reports it from the
    /// display's own data (CGDisplayScreenSize); a missing or implausible report (zero, or an aspect that does
    /// not match the screen's) falls back to 0.0233 cm per point, a 27 inch 1440p panel's density.
    static func physicalSizeCm(ofScreenID id: String) -> CGSize? {
        guard let screen = NSScreen.screens.first(where: { stableID(of: $0) == id }) else { return nil }
        let frame = screen.frame.size
        let fallback = CGSize(width: frame.width * 0.0233, height: frame.height * 0.0233)
        guard let display = displayID(of: screen) else { return fallback }
        let mm = CGDisplayScreenSize(display)
        guard mm.width >= 80, mm.width <= 3000, mm.height >= 50, mm.height <= 2000 else { return fallback }
        let reported = mm.width / mm.height, actual = frame.width / frame.height
        guard abs(reported / actual - 1) <= 0.2 else { return fallback }
        return CGSize(width: mm.width / 10, height: mm.height / 10)
    }
}
