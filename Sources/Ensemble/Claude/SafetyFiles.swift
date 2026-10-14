import Foundation

/// A dictation press that has been started and not yet proven finished. Written (and fsynced) before the
/// press so that a crash mid-recording is discoverable on the next launch.
struct EpisodeRecord: Codable, Equatable {
    var id: String
    var startedAt: Date
    var pid: Int32
    var bootSessionUUID: String
    var sessionID: String
    var claudeVersion: String?
}

/// An input-device mute (or volume-to-zero) that this app applied as a last-resort safeguard.
struct MuteRecord: Codable, Equatable {
    enum Method: String, Codable { case mute, volume }
    var deviceUID: String
    var method: Method
    var priorMuted: Bool?
    var priorVolume: Float?
    var appliedAt: Date
}

enum SafetyFiles {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Clutch", isDirectory: true)
    }
    static var episodeURL: URL { directory.appendingPathComponent("episode.json") }
    static var muteURL: URL { directory.appendingPathComponent("mute.json") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func bootSessionUUID() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buf)
    }

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    /// Write to a temp file, force it to disk, rename over the target, then force the directory entry.
    static func writeDurably(_ data: Data, to url: URL) throws {
        try ensureDirectory()
        let tmp = url.appendingPathExtension("tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var failure: Error?
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO); return }
                offset += n
            }
        }
        if failure == nil, fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
            failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        close(fd)
        if let failure { unlink(tmp.path); throw failure }
        guard rename(tmp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let dirFD = open(directory.path, O_RDONLY)
        if dirFD >= 0 { _ = fsync(dirFD); close(dirFD) }
    }

    static func writeEpisode(_ record: EpisodeRecord) throws {
        try writeDurably(try encoder.encode(record), to: episodeURL)
    }

    static func readEpisode() -> EpisodeRecord? {
        guard let data = try? Data(contentsOf: episodeURL) else { return nil }
        return try? decoder.decode(EpisodeRecord.self, from: data)
    }

    static func episodeFileExists() -> Bool {
        FileManager.default.fileExists(atPath: episodeURL.path)
    }

    static func deleteEpisode() { try? FileManager.default.removeItem(at: episodeURL) }

    static func writeMutes(_ records: [MuteRecord]) throws {
        try writeDurably(try encoder.encode(records), to: muteURL)
    }

    static func readMutes() -> [MuteRecord] {
        guard let data = try? Data(contentsOf: muteURL) else { return [] }
        return (try? decoder.decode([MuteRecord].self, from: data)) ?? []
    }

    static func deleteMutes() { try? FileManager.default.removeItem(at: muteURL) }
}
