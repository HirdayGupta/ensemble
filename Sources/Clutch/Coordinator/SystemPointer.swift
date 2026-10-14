import Foundation

/// The user's own pointer preferences, so gesture scrolling feels like their trackpad or mouse.
enum SystemPointer {
    private static var global: [String: Any] { UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:] }

    /// System Settings › Trackpad/Mouse › "Natural scrolling" (on by default): content follows the fingers.
    static var naturalScrolling: Bool { global["com.apple.swipescrolldirection"] as? Bool ?? true }

    /// Scroll speed factor from the tracking speed slider (0...3 in both trackpad and mouse settings): 0.5...2.
    static var speedFactor: Double {
        let scaling = (global["com.apple.trackpad.scaling"] as? Double) ?? (global["com.apple.mouse.scaling"] as? Double) ?? 1.0
        return 0.5 + min(max(scaling, 0), 3) / 3 * 1.5
    }
}
