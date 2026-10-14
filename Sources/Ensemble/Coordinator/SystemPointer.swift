import Foundation

/// The user's own pointer preferences, so gesture scrolling feels like their trackpad or mouse.
enum SystemPointer {
    // Read at camera frame rate while dragging, and the defaults read copies the whole global domain: cache for a second.
    private static let lock = NSLock()
    private static var cached: (domain: [String: Any], at: TimeInterval)?

    private static var global: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if let c = cached, now - c.at < 1 { return c.domain }
        let domain = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        cached = (domain, now)
        return domain
    }

    /// System Settings › Trackpad/Mouse › "Natural scrolling" (on by default): content follows the fingers.
    static var naturalScrolling: Bool { global["com.apple.swipescrolldirection"] as? Bool ?? true }

    /// Scroll speed factor from the tracking speed slider (0...3 in both trackpad and mouse settings): 0.5...2.
    static var speedFactor: Double {
        let g = global
        let scaling = (g["com.apple.trackpad.scaling"] as? Double) ?? (g["com.apple.mouse.scaling"] as? Double) ?? 1.0
        return 0.5 + min(max(scaling, 0), 3) / 3 * 1.5
    }
}
