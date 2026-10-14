#!/usr/bin/env swift
// Packs the large files of a bundled web folder as LZMA to shrink the app: <name> becomes <name>.lzma, an 8-byte
// little-endian size followed by the LZMA data. Sources/Ensemble/Engine/AssetSchemeHandler.swift reads them back.
// A file is packed only if it is at least 32 KB and the result is under 90% of its size, and only after a round trip check.
// Usage: swift scripts/pack-web.swift <web folder>
//        swift scripts/pack-web.swift --unpack <packed web folder> <output folder>   (full copy with every .lzma expanded; used by scripts/check-network.sh)
import Compression
import Foundation

func log(_ message: String) { print("[\(ISO8601DateFormatter().string(from: Date()))] \(message)") }

let fm = FileManager.default

if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--unpack" {
    let from = URL(fileURLWithPath: CommandLine.arguments[2]), to = URL(fileURLWithPath: CommandLine.arguments[3])
    try? fm.removeItem(at: to)
    try fm.copyItem(at: from, to: to)
    guard let found = fm.enumerator(at: to, includingPropertiesForKeys: nil) else { exit(1) }
    for case let url as URL in found where url.pathExtension == "lzma" {
        let packed = try Data(contentsOf: url)
        let size = packed.prefix(8).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        var out = [UInt8](repeating: 0, count: size)
        let n = packed.dropFirst(8).withUnsafeBytes { compression_decode_buffer(&out, size, $0.bindMemory(to: UInt8.self).baseAddress!, $0.count, nil, COMPRESSION_LZMA) }
        guard n == size else { log("error: cannot unpack \(url.lastPathComponent)"); exit(1) }
        try Data(out).write(to: url.deletingPathExtension())
        try fm.removeItem(at: url)
    }
    exit(0)
}

guard CommandLine.arguments.count == 2 else { FileHandle.standardError.write(Data("usage: pack-web.swift <web folder> | --unpack <packed web folder> <output folder>\n".utf8)); exit(2) }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { exit(1) }

for case let url as URL in walker {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let size = values.fileSize, size >= 32 * 1024, url.pathExtension != "html", url.pathExtension != "lzma" else { continue }
    let source = try Data(contentsOf: url)
    var packed = [UInt8](repeating: 0, count: size + 4096)
    let n = source.withUnsafeBytes { src in
        compression_encode_buffer(&packed, packed.count, src.bindMemory(to: UInt8.self).baseAddress!, size, nil, COMPRESSION_LZMA)
    }
    guard n > 0, n + 8 < size * 9 / 10 else { log("kept \(url.lastPathComponent) (\(size) bytes, does not pack well)"); continue }
    var back = [UInt8](repeating: 0, count: size)
    let m = packed.withUnsafeBufferPointer { compression_decode_buffer(&back, size, $0.baseAddress!, n, nil, COMPRESSION_LZMA) }
    guard m == size, Data(back) == source else { log("error: round trip failed for \(url.lastPathComponent)"); exit(1) }
    var out = Data((0..<8).map { UInt8((UInt64(size) >> (8 * UInt64($0))) & 0xFF) })
    out.append(contentsOf: packed[0..<n])
    try out.write(to: URL(fileURLWithPath: url.path + ".lzma"))
    try fm.removeItem(at: url)
    log("packed \(url.lastPathComponent): \(size) -> \(out.count) bytes")
}
