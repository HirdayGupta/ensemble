import Foundation

/// Append-only text file that keeps one open handle and rolls over to `<name>.1` (replacing any older backup)
/// when a line would push it past `limit` bytes. Not thread-safe; callers serialize access.
public final class RotatingLogFile {
    public let url: URL
    public let limit: Int
    private var handle: FileHandle?
    private var size: Int = 0

    public init(url: URL, limit: Int = 1_000_000) {
        self.url = url
        self.limit = limit
    }

    public var backupURL: URL { url.appendingPathExtension("1") }

    public func append(_ text: String) {
        let data = Data(text.utf8)
        if handle == nil { open() }
        if size > 0, size + data.count > limit { rotate() }
        guard let handle else { return }
        do { try handle.write(contentsOf: data); size += data.count } catch { close(); open() }
    }

    public func close() {
        try? handle?.close()
        handle = nil
    }

    private func open() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        size = Int((try? h.seekToEnd()) ?? 0)
        handle = h
    }

    private func rotate() {
        close()
        let fm = FileManager.default
        try? fm.removeItem(at: backupURL)
        try? fm.moveItem(at: url, to: backupURL)
        open()
    }
}
