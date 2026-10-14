import Foundation

/// Open-at-login as a per-user launchd agent rather than a plain login item: launchd restarts Clutch if it
/// crashes (KeepAlive on unsuccessful exit), which is what lets the startup sweep switch off a microphone a
/// crash left on. Quitting from the menu exits cleanly, so launchd leaves it quit.
enum LoginAgent {
    static let label = "dev.clutch.app"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// Writes the agent; it takes effect at the next login (loading it now would start a second copy).
    static func enable() throws {
        guard let exe = Bundle.main.executablePath else { throw CocoaError(.fileNoSuchFile) }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "ThrottleInterval": 5,
        ]
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    static func disable() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        if isEnabled { try FileManager.default.removeItem(at: plistURL) }
    }
}
