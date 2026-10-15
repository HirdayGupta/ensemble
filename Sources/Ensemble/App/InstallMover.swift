import AppKit
import EnsembleCore

/// The standard "Move to Applications" offer for a copy opened from the disk image or Downloads. The copy
/// there cannot keep open-at-login (the recorded path goes away) and cannot be updated by Sparkle.
@MainActor
enum InstallMover {
    /// Remembered per location, so declining once does not ask at every launch. The login item stays refused
    /// from a temporary location either way (`LoginAgent.enable`).
    private static let declinedKey = "moveToApplicationsDeclinedFrom"

    static func offer() {
        let current = Bundle.main.bundlePath
        guard UserDefaults.standard.string(forKey: declinedKey) != current else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Ensemble to your Applications folder?"
        alert.informativeText = InstallLocation.explanation
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(current, forKey: declinedKey)
            return
        }
        do {
            let destination = try move()
            EnsembleLog.write("moved to \(destination.path); relaunching")
            relaunch(destination)
        } catch {
            EnsembleLog.write("move to Applications failed: \(error)")
            let failed = NSAlert()
            failed.messageText = "Ensemble could not be moved"
            failed.informativeText = "\(error.localizedDescription) Drag Ensemble to the Applications folder yourself, then open it from there."
            failed.runModal()
        }
    }

    /// Copies the running bundle into /Applications (or ~/Applications when that is not writable). An older copy
    /// already there goes to the Trash first; this copy is the only one running, because a second launch exits.
    private static func move() throws -> URL {
        let fm = FileManager.default
        let directory: URL
        if fm.isWritableFile(atPath: "/Applications") {
            directory = URL(fileURLWithPath: "/Applications", isDirectory: true)
        } else {
            directory = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let destination = directory.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
        if fm.fileExists(atPath: destination.path) { try fm.trashItem(at: destination, resultingItemURL: nil) }
        try fm.copyItem(at: Bundle.main.bundleURL, to: destination)
        return destination
    }

    /// Opens the new copy a moment after this process exits (the one-copy check would otherwise stop it).
    private static func relaunch(_ app: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
