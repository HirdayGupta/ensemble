import Foundation
import WebKit

/// Serves the bundled `web` folder under `ensemble-asset://local/...` so the face tracker page, the
/// MediaPipe script, its wasm and the model never touch the network.
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

    /// The response and body for a request URL, or nil when there is no such asset.
    static func response(for url: URL) -> (HTTPURLResponse, Data)? {
        guard let file = fileURL(forPath: url.path),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe),
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
