import Foundation

/// Plain-text event log at ~/Library/Logs/Clutch/clutch.log. Events and reasons only: never images,
/// transcripts or session titles.
enum ClutchLog {
    private static let queue = DispatchQueue(label: "clutch.log")
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clutch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("clutch.log")
    }()
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    static func write(_ line: String) {
        let text = "[\(stamp.string(from: Date()))] \(line)\n"
        queue.async {
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        }
    }
}
