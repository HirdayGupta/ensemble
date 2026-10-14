import Foundation

/// Open-at-login as a per-user launchd agent rather than a plain login item: launchd restarts Clutch if it
/// crashes (KeepAlive on unsuccessful exit), which is what lets the startup sweep switch off a microphone a
/// crash left on. Quitting from the menu exits cleanly, so launchd leaves it quit.
enum LoginAgent {
    static let label = "dev.ensemble.app"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// The executable the agent file launches, or nil when there is no readable agent file.
    static var registeredExecutable: String? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String] else { return nil }
        return args.first
    }

    /// On only when the agent file points at the copy of Clutch that is running now.
    static var isEnabled: Bool {
        guard let registered = registeredExecutable else { return false }
        return registered == Bundle.main.executablePath
    }

    /// An agent file left by another copy of Clutch (moved or reinstalled app) is repointed at this one.
    /// A SwiftPM debug build never takes the file over.
    static func repointIfStale() {
        guard let registered = registeredExecutable, let exe = Bundle.main.executablePath,
              registered != exe, !exe.contains("/.build/") else { return }
        do { try enable(); ClutchLog.write("open at login: repointed from \(registered) to \(exe)") }
        catch { ClutchLog.write("open at login: could not repoint (\(error))") }
    }

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

    /// Removes the agent file first, so a failure partway cannot leave a file behind. The loaded job is booted out
    /// only when this process is not the one launchd runs: booting it out would terminate Clutch itself.
    static func disable() throws {
        if FileManager.default.fileExists(atPath: plistURL.path) { try FileManager.default.removeItem(at: plistURL) }
        guard ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != label else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }
}
