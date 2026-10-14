import Compression
import Foundation
import WebKit

/// Serves the bundled `web` folder under `ensemble-asset://local/...` so the face tracker page, the
/// MediaPipe script, its wasm and the model never touch the network. A packaged build ships large files as
/// `<name>.lzma` (scripts/pack-web.swift: an 8-byte little-endian size, then LZMA data); the page still asks for `<name>`.
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "ensemble-asset"
    static let root: URL? = EnsembleResources.bundle.resourceURL?.appendingPathComponent("web", isDirectory: true)

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "wasm": return "application/wasm"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }

    /// Maps a request path to a file inside the web folder. Anything that resolves outside it is refused.
    static func fileURL(forPath path: String, root: URL? = AssetSchemeHandler.root) -> URL? {
        guard let root else { return nil }
        let relative = (path.isEmpty || path == "/") ? "head.html" : String(path.drop(while: { $0 == "/" }))
        let candidate = root.appendingPathComponent(relative).standardizedFileURL
        guard candidate.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
        return candidate
    }

    static let packedSuffix = ".lzma"
    private static let maxUnpackedBytes: UInt64 = 64 << 20

    /// The file's bytes, from the file itself or from its packed sibling.
    static func contents(of file: URL) -> Data? {
        if let data = try? Data(contentsOf: file, options: .mappedIfSafe) { return data }
        guard let packed = try? Data(contentsOf: URL(fileURLWithPath: file.path + packedSuffix), options: .mappedIfSafe),
              packed.count > 8 else { return nil }
        let size = packed.prefix(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        guard size > 0, size <= maxUnpackedBytes else { return nil }
        var out = Data(count: Int(size))
        let written = out.withUnsafeMutableBytes { dst in
            packed.dropFirst(8).withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, Int(size),
                                          src.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_LZMA)
            }
        }
        return written == Int(size) ? out : nil
    }

    /// The response and body for a request URL, or nil when there is no such asset.
    static func response(for url: URL) -> (HTTPURLResponse, Data)? {
        guard let file = fileURL(forPath: url.path),
              let data = contents(of: file),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                  "Content-Type": mimeType(forExtension: file.pathExtension),
                  "Content-Length": String(data.count),
                  "Access-Control-Allow-Origin": "*",
                  "Cache-Control": "no-store",
              ])
        else { return nil }
        return (response, data)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let url = urlSchemeTask.request.url ?? URL(string: "\(Self.scheme)://local/")!
        guard let (response, data) = Self.response(for: url) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
