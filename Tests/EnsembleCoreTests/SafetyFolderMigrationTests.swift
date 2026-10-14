import Foundation
import Testing
@testable import EnsembleCore

struct SafetyFolderMigrationTests {
    private func folders() throws -> (legacy: URL, current: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ensemble-safety-\(UUID().uuidString)", isDirectory: true)
        let legacy = root.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        return (legacy, root.appendingPathComponent("new", isDirectory: true))
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func episode(_ id: String) -> EpisodeRecord {
        EpisodeRecord(id: id, startedAt: t0, pid: 4242, bootSessionUUID: "boot", sessionID: "s-\(id)", claudeVersion: "1.0")
    }

    private func mute(_ uid: String, at offset: TimeInterval, prior: Float) -> MuteRecord {
        MuteRecord(deviceUID: uid, method: .volume, priorMuted: nil, priorVolume: prior, appliedAt: t0.addingTimeInterval(offset))
    }

    private func write<T: Encodable>(_ value: T, _ dir: URL, _ name: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try SafetyRecordCoding.encoder.encode(value).write(to: dir.appendingPathComponent(name))
    }

    private func read<T: Decodable>(_ type: T.Type, _ dir: URL, _ name: String) throws -> T {
        try SafetyRecordCoding.decoder.decode(type, from: Data(contentsOf: dir.appendingPathComponent(name)))
    }

    private func exists(_ dir: URL, _ name: String = "") -> Bool {
        FileManager.default.fileExists(atPath: name.isEmpty ? dir.path : dir.appendingPathComponent(name).path)
    }

    @Test func recordLeftByAnOlderBuildIsMovedSoRecoveryFindsIt() throws {
        let (legacy, current) = try folders()
        try write(episode("a"), legacy, "episode.json")
        try write([mute("mic", at: 0, prior: 0.8)], legacy, "mute.json")

        let adopted = SafetyFolderMigration.adopt(from: legacy, into: current)

        #expect(Set(adopted) == ["episode.json", "mute.json"])
        #expect(try read(EpisodeRecord.self, current, "episode.json") == episode("a"))
        #expect(try read([MuteRecord].self, current, "mute.json") == [mute("mic", at: 0, prior: 0.8)])
        #expect(!exists(legacy))
    }

    @Test func nothingToAdoptLeavesBothFoldersAlone() throws {
        let (legacy, current) = try folders()
        #expect(SafetyFolderMigration.adopt(from: legacy, into: current).isEmpty)
        #expect(!exists(current))
        let missing = legacy.appendingPathComponent("gone")
        #expect(SafetyFolderMigration.adopt(from: missing, into: current).isEmpty)
    }

    @Test func adoptingTwiceIsHarmless() throws {
        let (legacy, current) = try folders()
        try write(episode("a"), legacy, "episode.json")
        SafetyFolderMigration.adopt(from: legacy, into: current)
        #expect(SafetyFolderMigration.adopt(from: legacy, into: current).isEmpty)
        #expect(try read(EpisodeRecord.self, current, "episode.json") == episode("a"))
    }

    @Test func foldersHoldingTheSameDeviceKeepTheEarlierRecord() throws {
        let (legacy, current) = try folders()
        try write([mute("mic", at: 0, prior: 0.8), mute("usb", at: 5, prior: 0.5)], legacy, "mute.json")
        try write([mute("mic", at: 60, prior: 0), mute("hdmi", at: 70, prior: 0.3)], current, "mute.json")

        SafetyFolderMigration.adopt(from: legacy, into: current)

        let merged = try read([MuteRecord].self, current, "mute.json")
        #expect(merged == [mute("mic", at: 0, prior: 0.8), mute("usb", at: 5, prior: 0.5), mute("hdmi", at: 70, prior: 0.3)])
        #expect(!exists(legacy))
    }

    @Test func twoEpisodesLeaveOneAndRemoveTheOldFile() throws {
        let (legacy, current) = try folders()
        try write(episode("old"), legacy, "episode.json")
        try write(episode("new"), current, "episode.json")
        SafetyFolderMigration.adopt(from: legacy, into: current)
        #expect(try read(EpisodeRecord.self, current, "episode.json") == episode("new"))
        #expect(!exists(legacy, "episode.json"))
    }

    @Test func anUnreadableCurrentFileDoesNotHideAReadableOldOne() throws {
        let (legacy, current) = try folders()
        try write(episode("old"), legacy, "episode.json")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: current.appendingPathComponent("episode.json"))
        try write([mute("mic", at: 0, prior: 0.8)], legacy, "mute.json")
        try Data("{".utf8).write(to: current.appendingPathComponent("mute.json"))

        SafetyFolderMigration.adopt(from: legacy, into: current)

        #expect(try read(EpisodeRecord.self, current, "episode.json") == episode("old"))
        #expect(try read([MuteRecord].self, current, "mute.json") == [mute("mic", at: 0, prior: 0.8)])
    }

    @Test func leftoverTempFilesGoAndOtherFilesKeepTheFolder() throws {
        let (legacy, current) = try folders()
        try write(episode("a"), legacy, "episode.json")
        try Data("x".utf8).write(to: legacy.appendingPathComponent("episode.json.tmp"))
        try Data("keep".utf8).write(to: legacy.appendingPathComponent("notes.txt"))

        SafetyFolderMigration.adopt(from: legacy, into: current)

        #expect(!exists(legacy, "episode.json.tmp"))
        #expect(exists(legacy, "notes.txt"))
    }

    @Test func currentFolderIsPrivateToTheUser() throws {
        let (legacy, current) = try folders()
        try write(episode("a"), legacy, "episode.json")
        SafetyFolderMigration.adopt(from: legacy, into: current)
        let mode = try FileManager.default.attributesOfItem(atPath: current.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }
}
