import AppKit
import SwiftUI
import WebKit
import EnsembleCore

/// The scenes scene3d.js draws, by the names the page takes.
enum TourScene: String {
    case welcome, calibrate, look, dictate, send, scroll

    init(_ tab: TourGestureTab) {
        switch tab {
        case .look: self = .look
        case .dictate: self = .dictate
        case .send: self = .send
        case .scroll: self = .scroll
        }
    }
}

/// What the page reports about the scene on each frame, for the SwiftUI session mock to follow.
struct TourSceneFrame: Equatable {
    var listening = false
    var draft = 0.0        // 0...1: how much of the dictated sentence has appeared
    var hold = 0.0         // 0...1: how far the thumbs-up hold has run
    var sent = false
    var scroll = 0.0       // 0...1: how far the pane has scrolled

    /// The frame shown before the page reports one, and as the still when 3D is unavailable: each gesture at its
    /// most telling moment.
    static func resting(_ scene: TourScene) -> TourSceneFrame {
        switch scene {
        case .dictate: return TourSceneFrame(listening: true, draft: 0.6)
        case .send: return TourSceneFrame(hold: 1, sent: true)
        case .scroll: return TourSceneFrame(scroll: 0.6)
        case .welcome, .calibrate, .look: return TourSceneFrame()
        }
    }

    init(listening: Bool = false, draft: Double = 0, hold: Double = 0, sent: Bool = false, scroll: Double = 0) {
        self.listening = listening; self.draft = draft; self.hold = hold; self.sent = sent; self.scroll = scroll
    }

    init?(message: [String: Any]) {
        func number(_ key: String) -> Double { (message[key] as? NSNumber)?.doubleValue ?? 0 }
        guard message["scene"] is String else { return nil }
        self.init(listening: (message["listening"] as? NSNumber)?.boolValue ?? false,
                  draft: min(max(number("draft"), 0), 1), hold: min(max(number("hold"), 0), 1),
                  sent: (message["sent"] as? NSNumber)?.boolValue ?? false, scroll: min(max(number("scroll"), 0), 1))
    }
}

/// Owns the tour's one WKWebView for a step. The page is bundled and reached only through `ensemble-asset://`;
/// like the face tracker it is never loaded before the network block list is installed, and any navigation off
/// the app's own scheme is cancelled. Nothing is stored (non-persistent data store) and no frame of video ever
/// reaches it: the page draws a scripted scene.
@MainActor
final class TourSceneController: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    @Published private(set) var frame: TourSceneFrame
    /// True when the 3D page could not start (WebGL off, a file missing, the web process ended); the view then
    /// shows a plain still.
    @Published private(set) var failed = false

    /// The AppKit view SwiftUI hosts; the web view is added to it once the block list is ready.
    let container = NSView()

    private var scene: TourScene
    private let wantsFrames: Bool
    private let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var webView: WKWebView?
    private var pageReady = false
    private var pageScene: TourScene
    private var started = false
    private var readyTimeout: Task<Void, Never>?
    private static let readyTimeoutSeconds: UInt64 = 8

    init(scene: TourScene, wantsFrames: Bool) {
        self.scene = scene
        self.pageScene = scene
        self.wantsFrames = wantsFrames
        self.frame = TourSceneFrame.resting(scene)
        super.init()
        container.wantsLayer = true
        container.layer?.cornerRadius = 16
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor(red: 0.016, green: 0.027, blue: 0.047, alpha: 1).cgColor
    }

    func start() {
        guard !started else { return }
        started = true
        readyTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.readyTimeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, !self.pageReady else { return }
            self.fail("the page did not become ready within \(Self.readyTimeoutSeconds) s")
        }
        Task { @MainActor [weak self] in
            do {
                let blockList = try await NetworkBlock.compile()
                self?.load(blockList: blockList)
            } catch {
                self?.fail("the network block could not be set up: \(error.localizedDescription)")
            }
        }
    }

    func setScene(_ new: TourScene) {
        guard new != scene else { return }
        scene = new
        if !pageReady { return }          // applied when the page reports ready
        apply(scene)
    }

    func stop() {
        readyTimeout?.cancel()
        readyTimeout = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "tour")
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        pageReady = false
        started = false
    }

    private func load(blockList: WKContentRuleList) {
        guard started, webView == nil else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(blockList)
        config.setURLSchemeHandler(AssetSchemeHandler(), forURLScheme: AssetSchemeHandler.scheme)
        config.userContentController.add(WeakScriptHandler(self), name: "tour")
        let view = WKWebView(frame: container.bounds, configuration: config)
        view.autoresizingMask = [.width, .height]
        view.navigationDelegate = self
        container.addSubview(view)
        webView = view
        let query = "scene=\(scene.rawValue)&rm=\(reducedMotion ? 1 : 0)&frames=\(wantsFrames ? 1 : 0)"
        pageScene = scene
        view.load(URLRequest(url: URL(string: "\(AssetSchemeHandler.scheme)://local/tour/tour.html?\(query)")!))
    }

    private func apply(_ scene: TourScene) {
        pageScene = scene
        webView?.evaluateJavaScript("EnsembleTour.setScene('\(scene.rawValue)')", completionHandler: nil)
    }

    private func fail(_ reason: String) {
        EnsembleLog.write("tour 3D scene unavailable: \(reason)")
        stop()
        failed = true
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if let reason = body["failed"] as? String {
            fail("the page reported \(reason)")
        } else if body["ready"] as? Bool == true {
            pageReady = true
            readyTimeout?.cancel()
            if pageScene != scene { apply(scene) }
        } else if let raw = body["frame"] as? [String: Any], let new = TourSceneFrame(message: raw), new != frame {
            frame = new
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        NetworkBlock.allowsNavigation(to: navigationAction.request.url) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("the page failed to load: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail("the page failed to load: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fail("the web content process ended")
    }
}

private struct TourSceneHost: NSViewRepresentable {
    let controller: TourSceneController
    func makeNSView(context: Context) -> NSView { controller.container }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// A tour illustration: the 3D scene, or a plain still with the step's text when 3D is unavailable.
struct TourSceneStage: View {
    @ObservedObject var controller: TourSceneController
    let symbol: String
    let caption: String

    var body: some View {
        ZStack {
            TourSceneHost(controller: controller)
            if controller.failed {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.45))
                VStack(spacing: 10) {
                    Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(Color.ensembleBlue)
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
                .padding(20)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
    }
}
