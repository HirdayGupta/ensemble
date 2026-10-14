import AppKit
import ClutchCore
import WebKit

/// MediaPipe Face Landmarker running in a hidden WKWebView. Frames go in as JPEG, head angles come out.
@MainActor
final class FaceTracker: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var onReady: ((_ delegate: String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onHead: ((HeadObservation) -> Void)?
    var onDiagnostic: ((String) -> Void)?

    nonisolated let gate = FrameGate()

    private var webView: WKWebView?
    private var window: NSWindow?
    private(set) var isReady = false
    private var consecutiveFrameErrors = 0
    private var readyTimeout: Task<Void, Never>?
    private static let readyTimeoutSeconds: UInt64 = 10

    /// Loads the page. Safe to call again after `stop()`.
    func start() {
        stop()
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(AssetSchemeHandler(), forURLScheme: AssetSchemeHandler.scheme)
        config.userContentController.add(WeakScriptHandler(self), name: "head")
        config.mediaTypesRequiringUserActionForPlayback = []

        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        view.navigationDelegate = self
        // Without a window WebKit throttles the page as if it were in a background tab.
        let host = OffscreenWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1, height: 1),
                                   styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.ignoresMouseEvents = true
        host.alphaValue = 0
        host.level = .normal
        host.collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces]
        host.contentView = view
        host.orderFrontRegardless()

        webView = view
        window = host
        view.load(URLRequest(url: URL(string: "\(AssetSchemeHandler.scheme)://local/head.html")!))
        readyTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.readyTimeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.webView === view, !self.isReady else { return }
            self.fail("The face tracker did not become ready within \(Self.readyTimeoutSeconds) s")
        }
    }

    private func fail(_ message: String) {
        gate.setOpen(false)
        isReady = false
        onFailure?(message)
    }

    func stop() {
        readyTimeout?.cancel()
        readyTimeout = nil
        gate.setOpen(false)
        isReady = false
        consecutiveFrameErrors = 0
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "head")
        webView?.stopLoading()
        window?.orderOut(nil)
        window?.contentView = nil
        webView = nil
        window = nil
    }

    /// Sends one frame. The caller must already hold the gate; it is released when the page answers.
    func submit(jpeg: Data, t: TimeInterval) {
        guard isReady, let webView else { gate.leave(); return }
        let script = "clutchFrame('\(jpeg.base64EncodedString())', \(t))"
        webView.evaluateJavaScript(script) { [weak self] _, error in
            guard let error else { return }
            MainActor.assumeIsolated {
                self?.gate.leave()
                self?.onDiagnostic?("evaluateJavaScript failed: \(error.localizedDescription)")
            }
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        handle(message.body)
    }

    private func handle(_ body: Any) {
        guard let m = body as? [String: Any] else { return }
        if let message = m["error"] as? String, m["t"] == nil {
            fail(message)
        } else if m["ready"] as? Bool == true {
            readyTimeout?.cancel()
            isReady = true
            gate.setOpen(true)
            onReady?(m["delegate"] as? String ?? "?")
        } else if let t = (m["t"] as? NSNumber)?.doubleValue {
            gate.leave()
            if let message = m["frameError"] as? String {
                consecutiveFrameErrors += 1
                onDiagnostic?("frame error: \(message)")
                if consecutiveFrameErrors >= 30 { fail("Face tracking failed repeatedly: \(message)") }
                return
            }
            consecutiveFrameErrors = 0
            let faces = (m["faces"] as? NSNumber)?.intValue ?? 0
            onHead?(HeadObservation(t: t,
                                    yaw: (m["yaw"] as? NSNumber)?.doubleValue ?? 0,
                                    pitch: (m["pitch"] as? NSNumber)?.doubleValue ?? 0,
                                    faceCount: faces))
        } else if let note = m["log"] as? String {
            onDiagnostic?(note)
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        fail("The face tracker page failed to load: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        fail("The face tracker page failed to load: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        fail("The face tracker's web content process ended")
    }
}

/// WKUserContentController retains its handlers; this keeps the tracker from being kept alive by its own web view.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
