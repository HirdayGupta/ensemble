import Foundation
import Testing
@testable import EnsembleCore

struct RotatingLogFileTests {
    private func tempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-log-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ensemble.log")
    }

    @Test func appendsAcrossCallsAndKeepsOneFile() throws {
        let url = tempURL()
        let log = RotatingLogFile(url: url, limit: 1000)
        log.append("one\n"); log.append("two\n")
        #expect(try String(contentsOf: url, encoding: .utf8) == "one\ntwo\n")
        #expect(!FileManager.default.fileExists(atPath: log.backupURL.path))
    }

    @Test func rollsOverToOneBackupWhenFull() throws {
        let url = tempURL()
        let log = RotatingLogFile(url: url, limit: 20)
        for i in 0..<10 { log.append("line-\(i)\n") }     // 7 bytes each
        let current = try String(contentsOf: url, encoding: .utf8)
        let backup = try String(contentsOf: log.backupURL, encoding: .utf8)
        #expect(current.utf8.count <= 20)
        #expect(backup.utf8.count <= 20)
        #expect(current.hasSuffix("line-9\n"))
        #expect(backup.hasSuffix("\n"))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("2").path))
    }

    @Test func resumesSizeFromAnExistingFile() throws {
        let url = tempURL()
        try Data(repeating: 0x61, count: 15).write(to: url)
        let log = RotatingLogFile(url: url, limit: 20)
        log.append("12345678\n")                           // 15 + 9 > 20: rolls over first
        #expect(try String(contentsOf: url, encoding: .utf8) == "12345678\n")
        #expect(try Data(contentsOf: log.backupURL).count == 15)
    }
}
