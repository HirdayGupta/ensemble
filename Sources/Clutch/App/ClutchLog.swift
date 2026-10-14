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

    static func write(_ line: String) {
        let now = Date()
        queue.async { file.append("[\(stamp.string(from: now))] \(line)\n") }
    }

    /// Waits for queued lines to reach the file; the quit path calls it so the last events are not lost.
    static func flush() { queue.sync {} }
}

/// Per-frame trace at ~/Library/Logs/Clutch/trace.log, for tuning how the nose and hand feel. Off unless
/// `defaults write dev.ensemble.app detailedTrace -bool true`; numbers and states only, never names or text.
/// Rolls over to trace.old.log at 20 MB, so it never holds more than about 40 MB.
enum ClutchTrace {
    static let enabled = UserDefaults.standard.bool(forKey: "detailedTrace")
    private static let queue = DispatchQueue(label: "clutch.trace")
    private static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clutch", isDirectory: true)
    private static let url = dir.appendingPathComponent("trace.log")
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var size: UInt64 = 0
    private static let limit: UInt64 = 20_000_000

    /// `t` is the frame's monotonic time; lines sort and diff by it.
    static func write(_ t: TimeInterval, _ line: @autoclosure () -> String) {
        guard enabled else { return }
        let text = String(format: "%.3f ", t) + line() + "\n"
        queue.async {
            if handle == nil || size > limit {
                try? handle?.close(); handle = nil
                if size > limit {
                    let old = dir.appendingPathComponent("trace.old.log")
                    try? FileManager.default.removeItem(at: old)
                    try? FileManager.default.moveItem(at: url, to: old)
                }
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                handle = try? FileHandle(forWritingTo: url)
                size = (try? handle?.seekToEnd()) ?? 0
            }
            let data = Data(text.utf8)
            handle?.write(data); size += UInt64(data.count)
        }
    }
}
