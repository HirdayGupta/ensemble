import ClutchCore
import Foundation

/// Plain-text event log at ~/Library/Logs/Clutch/clutch.log, rolled over to clutch.log.1 at 1 MB. Events and
/// reasons only: never images, transcripts or session titles.
enum ClutchLog {
    private static let queue = DispatchQueue(label: "clutch.log")
    private static let file: RotatingLogFile = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clutch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return RotatingLogFile(url: dir.appendingPathComponent("clutch.log"))
    }()
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    /// Per-frame hand-tuning numbers ("hand:", "gather:", "pinch:") are written only when the hidden setting
    /// `verboseLog` is on (read once at launch).
    static let verbose: Bool = UserDefaults.standard.bool(forKey: "verboseLog")

    static func write(_ line: String) {
        let now = Date()
        queue.async { file.append("[\(stamp.string(from: now))] \(line)\n") }
    }

    /// Waits for queued lines to reach the file; the quit path calls it so the last events are not lost.
    static func flush() { queue.sync {} }
}
