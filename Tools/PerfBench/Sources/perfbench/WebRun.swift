import AppKit
import CoreImage
import EnsembleCore
import Foundation
import WebKit

/// Serves the app's web folder, the bench page, the detector model and the frame waiting in the slot, like the app's
/// `AssetSchemeHandler`.
final class BenchScheme: NSObject, WKURLSchemeHandler {
    let root: URL
    let detectorModel: URL?
    let frames = FaceFrameSlot()
    init(root: URL, detectorModel: URL?) { self.root = root; self.detectorModel = detectorModel }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let url = task.request.url!
        var data: Data
        var mime = "application/octet-stream"
        if let n = FaceFrameSlot.number(inPath: url.path) {
            guard let d = frames.take(n) else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
            data = d
        } else if url.path == "/bench.html" { data = Data(benchPage.utf8); mime = "text/html" }
        else if url.path == "/face_detector.tflite", let detectorModel, let d = try? Data(contentsOf: detectorModel) { data = d }
        else {
            let file = root.appendingPathComponent(String(url.path.dropFirst()))
            guard let d = try? Data(contentsOf: file, options: .mappedIfSafe) else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
            data = d
            switch file.pathExtension { case "html": mime = "text/html"; case "mjs", "js": mime = "text/javascript"; case "wasm": mime = "application/wasm"; default: break }
        }
        let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"])!
        task.didReceive(r); task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

struct WebConfig {
    var transfer = "pull"       // pull (the app's page) | b64 (the old protocol) | bgra
    var w = 320, h = 240
    var quality = 0.6
    var hz = 30.0
    var seconds = 15.0
    var delegate = "GPU"
    var model = "landmarker"    // landmarker | detector
    var face = true
    var maxCPUms: Double?       // exit 1 when total CPU per answered frame is over this
    var maxGrowthMB: Double?    // exit 1 when the web content process grows more than this during the measured run
}

@MainActor
final class WebBench: NSObject, WKScriptMessageHandler {
    let cfg: WebConfig
    var view: WKWebView!
    var window: NSWindow!
    let scheme: BenchScheme
    var ready = false
    var inFlight = false
    var sentAt = 0.0
    var latencies: [Double] = []
    var answered = 0, faceSeen = 0, errors = 0, bytesSent = 0
    var lastError = ""
    var yaws: [Double] = []
    var done: ((Int32) -> Void)?
    let gpuBefore: Set<pid_t>
    let ci = CIContext(options: [.cacheIntermediates: false])
    /// The app's own page runs only the app's protocol and model.
    var appPage: Bool { cfg.transfer == "pull" && cfg.model == "landmarker" }

    init(cfg: WebConfig, root: URL, detectorModel: URL?) {
        self.cfg = cfg
        gpuBefore = Set(WebBench.pidsMatching("com.apple.WebKit.GPU"))
        scheme = BenchScheme(root: root, detectorModel: detectorModel)
        super.init()
        let conf = WKWebViewConfiguration()
        conf.setURLSchemeHandler(scheme, forURLScheme: "ensemble-asset")
        conf.userContentController.add(self, name: "head")
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: conf)
        window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.contentView = view; window.orderFrontRegardless()
        let page = appPage ? "head.html" : "bench.html?delegate=\(cfg.delegate)&model=\(cfg.model)"
        view.load(URLRequest(url: URL(string: "ensemble-asset://local/\(page)")!))
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any] else { return }
        if m["ready"] as? Bool == true { ready = true; print("  ready: \(appPage ? "the app's head.html" : "bench page"), \(cfg.model), delegate \(m["delegate"] ?? "?")") }
        else if let e = m["error"] as? String, m["t"] == nil { print("  ERROR \(e)"); exit(1) }
        else if m["t"] != nil {
            inFlight = false
            latencies.append((Date().timeIntervalSinceReferenceDate - sentAt) * 1000)
            answered += 1
            if let e = m["frameError"] as? String { errors += 1; lastError = e }
            if ((m["faces"] as? NSNumber)?.intValue ?? 0) > 0 { faceSeen += 1; if let y = (m["yaw"] as? NSNumber)?.doubleValue { yaws.append(y) } }
        } else if let note = m["log"] as? String { print("  page: \(note)") }
    }

    func waitReady() async { while !ready { try? await Task.sleep(nanoseconds: 50_000_000) } }

    /// Prepares and sends one frame the way the chosen protocol would in the app, so the frame preparation lands in
    /// the harness process as it lands in the app.
    func submit(_ pb: CVPixelBuffer) {
        let t = Date().timeIntervalSinceReferenceDate
        sentAt = t
        inFlight = true
        let w = cfg.w, h = cfg.h
        let report: (Any?, Error?) -> Void = { _, e in if let e { print("  eval error \(e)") } }
        switch cfg.transfer {
        case "b64":
            let scale = CGFloat(w) / CGFloat(CVPixelBufferGetWidth(pb))
            let img = CIImage(cvPixelBuffer: pb).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let q = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            let s = ci.jpegRepresentation(of: img, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [q: cfg.quality])!.base64EncodedString()
            bytesSent += s.utf8.count
            view.evaluateJavaScript("frameB64('\(s)', \(t), \(w), \(h)); 0", completionHandler: report)
        default:
            let bgra = cfg.transfer == "bgra"
            var d = Data(count: w * h * 4)
            d.withUnsafeMutableBytes { scalePixels(pb, into: $0, w: w, h: h, rgba: !bgra) }
            bytesSent += d.count
            let n = scheme.frames.put(d)
            let call = appPage ? "ensembleFrame(\(n), \(w), \(h), \(t))" : "frameRaw(\(n), \(t), \(w), \(h), \(bgra))"
            view.evaluateJavaScript("\(call); 0", completionHandler: report)
        }
    }

    func run() async {
        await waitReady()
        let frames = Synthetic.frames(count: 60, face: cfg.face, hand: false)
        var i = 0
        let period = 1.0 / cfg.hz
        func pump(for seconds: Double, sample: (() -> Void)? = nil) async {
            let end = Date().addingTimeInterval(seconds)
            var next = Date(), nextSample = Date()
            while Date() < end {
                if !inFlight { submit(frames[i % 60]); i += 1 }
                if Date() >= nextSample { sample?(); nextSample = nextSample.addingTimeInterval(0.5) }
                next = next.addingTimeInterval(period)
                let wait = next.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) } else { next = Date() }
            }
        }
        // 4 s warm-up at the target rate (not measured): the first frames compile shaders.
        await pump(for: 4)
        latencies = []; answered = 0; faceSeen = 0; errors = 0; yaws = []; bytesSent = 0
        let web = (view.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value
        let gpu = Set(Self.pidsMatching("com.apple.WebKit.GPU")).subtracting(gpuBefore)
        func cpu() -> (me: Double, web: Double, gpu: Double, wall: Double) {
            let me = selfCPU()
            return (me.user + me.system, web.flatMap { cpuSeconds(pid: $0) } ?? 0,
                    gpu.compactMap { cpuSeconds(pid: $0) }.reduce(0, +), Date().timeIntervalSinceReferenceDate)
        }
        func memory() -> (web: Double, gpu: Double, me: Double) {
            (web.map { Self.footprintMB(pid: $0) } ?? 0, gpu.map { Self.footprintMB(pid: $0) }.reduce(0, +), Self.footprintMB(pid: getpid()))
        }
        let memStart = memory()
        var peak = memStart
        let a = cpu()
        await pump(for: cfg.seconds) {
            let now = memory()
            peak = (max(peak.web, now.web), max(peak.gpu, now.gpu), max(peak.me, now.me))
        }
        let b = cpu()
        let memEnd = memory()
        let wall = b.wall - a.wall, n = Double(max(answered, 1))
        let meS = b.me - a.me, webS = b.web - a.web, gpuS = b.gpu - a.gpu, totalS = meS + webS + gpuS
        let sorted = latencies.sorted()
        let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2], p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        print(String(format: "  %@ %@ %dx%d %@ @%.0f Hz for %.0f s | %.1f frames/s, %d bytes/frame | latency p50 %.1f p95 %.1f ms",
                     cfg.transfer as NSString, cfg.model as NSString, cfg.w, cfg.h, cfg.delegate as NSString, cfg.hz, wall,
                     Double(answered) / wall, Int(Double(bytesSent) / n), p50, p95))
        print(String(format: "      CPU ms per frame: harness %.2f  web %.2f  gpu %.2f  total %.2f | CPU %% of one core: %.1f",
                     meS * 1000 / n, webS * 1000 / n, gpuS * 1000 / n, totalS * 1000 / n, totalS / wall * 100))
        print(String(format: "      memory MB start/peak/end: web %.0f/%.0f/%.0f  gpu %.0f/%.0f/%.0f  harness %.0f/%.0f/%.0f",
                     memStart.web, peak.web, memEnd.web, memStart.gpu, peak.gpu, memEnd.gpu, memStart.me, peak.me, memEnd.me))
        print(String(format: "      faces %d of %d frames, errors %d %@", faceSeen, answered, errors, lastError as NSString))
        if let lo = yaws.min(), let hi = yaws.max() { print(String(format: "      yaw %.4f ... %.4f", lo, hi)) }
        var status: Int32 = 0
        if let limit = cfg.maxCPUms, totalS * 1000 / n > limit {
            print(String(format: "  FAIL: %.2f CPU ms per frame, over the limit of %.2f", totalS * 1000 / n, limit)); status = 1
        }
        if let limit = cfg.maxGrowthMB, memEnd.web - memStart.web > limit {
            print(String(format: "  FAIL: the web content process grew %.0f MB, over the limit of %.0f", memEnd.web - memStart.web, limit)); status = 1
        }
        if Double(answered) < wall * cfg.hz * 0.5 { print("  FAIL: fewer than half the frames were answered"); status = 1 }
        if errors > 0 { print("  FAIL: frame errors"); status = 1 }
        done?(status)
    }

    static func pidsMatching(_ s: String) -> [pid_t] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-f", s]
        let out = Pipe(); p.standardOutput = out
        try? p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
    }

    /// Physical footprint, the number Activity Monitor shows as Memory.
    static func footprintMB(pid: pid_t) -> Double {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
        return rc == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : 0
    }
}

@MainActor
func runWeb(_ cfg: WebConfig) {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let root = repo.appendingPathComponent("Sources/Ensemble/Resources/web")
    var detector: URL?
    if cfg.model == "detector" {
        // The detector is the first stage inside the landmarker bundle; it is unzipped to a temporary folder.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perfbench-detector-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-o", "-q", root.appendingPathComponent("face_landmarker.task").path, "face_detector.tflite", "-d", dir.path]
        try? p.run(); p.waitUntilExit()
        detector = dir.appendingPathComponent("face_detector.tflite")
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let bench = WebBench(cfg: cfg, root: root, detectorModel: detector)
    bench.done = { status in exit(status) }
    Task { @MainActor in await bench.run() }
    app.run()
}
