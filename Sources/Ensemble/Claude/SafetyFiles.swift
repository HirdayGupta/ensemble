import EnsembleCore
import Foundation

enum SafetyFiles {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Ensemble", isDirectory: true)
    }
    /// The folder builds from before the rename wrote to. Records still in it (a dictation left recording, an input
    /// muted) are moved into `directory` the first time any safety file is touched, which is early in every launch.
    static var legacyDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Clutch", isDirectory: true)
    }
    private static let adoptedLegacyRecords: [String] = {
        let adopted = SafetyFolderMigration.adopt(from: legacyDirectory, into: directory)
        if !adopted.isEmpty { EnsembleLog.write("safety files: adopted \(adopted.joined(separator: ", ")) from the previous app folder") }
        return adopted
    }()
    static var episodeURL: URL { _ = adoptedLegacyRecords; return directory.appendingPathComponent(SafetyFolderMigration.episodeName) }
    static var muteURL: URL { _ = adoptedLegacyRecords; return directory.appendingPathComponent(SafetyFolderMigration.muteName) }

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
        try writeDurably(try SafetyRecordCoding.encoder.encode(record), to: episodeURL)
    }

    static func readEpisode() -> EpisodeRecord? {
        guard let data = try? Data(contentsOf: episodeURL) else { return nil }
        return try? SafetyRecordCoding.decoder.decode(EpisodeRecord.self, from: data)
    }

    static func episodeFileExists() -> Bool {
        FileManager.default.fileExists(atPath: episodeURL.path)
    }

    static func deleteEpisode() { try? FileManager.default.removeItem(at: episodeURL) }

    static func writeMutes(_ records: [MuteRecord]) throws {
        try writeDurably(try SafetyRecordCoding.encoder.encode(records), to: muteURL)
    }

    static func readMutes() -> [MuteRecord] {
        guard let data = try? Data(contentsOf: muteURL) else { return [] }
        return (try? SafetyRecordCoding.decoder.decode([MuteRecord].self, from: data)) ?? []
    }

    static func deleteMutes() { try? FileManager.default.removeItem(at: muteURL) }
}
