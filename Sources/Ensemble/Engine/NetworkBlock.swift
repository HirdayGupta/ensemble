import WebKit

/// Keeps the face tracker's web view off the network. Two independent layers: a compiled WebKit content rule list
/// that blocks every http(s), ws(s) and ftp load, and a navigation check that admits only the app's own scheme.
/// If the rule list cannot be compiled the tracker does not start.
enum NetworkBlock {
    static let identifier = "ensemble-block-network"

    static let rules = """
    [
      {"trigger": {"url-filter": "^https?://"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^wss?://"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^ftp://"}, "action": {"type": "block"}}
    ]
    """

    struct CompileFailure: LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    static func allowsNavigation(to url: URL?) -> Bool {
        url?.scheme?.lowercased() == AssetSchemeHandler.scheme
    }

    static func compile(store: WKContentRuleListStore = .default()) async throws -> WKContentRuleList {
        guard let list = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules) else {
            throw CompileFailure(detail: "WebKit returned no rule list")
        }
        return list
    }
}
