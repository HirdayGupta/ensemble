import AppKit
import WebKit
import CoreImage
import Foundation

let benchPage = #"""
<!doctype html><html><head><meta charset="utf-8"></head><body>
<script type="module">
import { FilesetResolver, FaceLandmarker } from './vision_bundle.mjs';
const post = (m) => window.webkit.messageHandlers.head.postMessage(m);
const BASE = 'ensemble-asset://local';
const q = new URLSearchParams(location.search);
const delegate = q.get('delegate') || 'GPU';
let landmarker = null, lastTs = 0;
async function init() {
  try {
    const fileset = await FilesetResolver.forVisionTasks(BASE + '/wasm');
    landmarker = await FaceLandmarker.createFromOptions(fileset, {
      baseOptions: { modelAssetPath: BASE + '/face_landmarker.task', delegate },
      runningMode: q.get('running') || 'VIDEO', numFaces: 1, outputFacialTransformationMatrixes: true });
    post({ ready: true, delegate });
  } catch (e) { post({ error: String(e && e.message ? e.message : e) }); }
}
function decode(b64) {
  const bin = atob(b64); const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return createImageBitmap(new Blob([bytes], { type: 'image/jpeg' }));
}
function angles(m) { return { yaw: Math.atan2(m[8], m[10]), pitch: Math.asin(Math.max(-1, Math.min(1, m[9]))) }; }
function detect(src, t) {
  lastTs = Math.max(lastTs + 1, Math.round(t * 1000));
  return (q.get('running') === 'IMAGE') ? landmarker.detect(src) : landmarker.detectForVideo(src, lastTs);
}
async function run(source, t) {
  let bitmap = null;
  try {
    const result = detect(source, t);
    const mats = result.facialTransformationMatrixes;
    const faces = (result.faceLandmarks || []).length;
    if (faces > 0 && mats && mats.length > 0) { const a = angles(mats[0].data); post({ t, yaw: a.yaw, pitch: a.pitch, faces }); }
    else post({ t, faces });
  } catch (e) { post({ t, frameError: String(e) }); }
}
// mode b64: the current protocol. mode jpegpull / rgbapull / lumapull: bytes fetched from the scheme handler.
window.frameB64 = async (b64, t) => { const bmp = await decode(b64); await run(bmp, t); bmp.close(); };
window.framePull = async (kind, w, h, t) => {
  try {
    const res = await fetch('ensemble-asset://local/frame');
    const buf = await res.arrayBuffer();
    if (kind === 'jpeg') { const bmp = await createImageBitmap(new Blob([buf], { type: 'image/jpeg' })); await run(bmp, t); bmp.close(); }
    else if (kind === 'rgba') { await run(new ImageData(new Uint8ClampedArray(buf), w, h), t); }
    else if (kind === 'luma') {
      const l = new Uint8Array(buf); const rgba = new Uint8ClampedArray(w * h * 4);
      for (let i = 0, j = 0; i < l.length; i++, j += 4) { const v = l[i]; rgba[j] = v; rgba[j+1] = v; rgba[j+2] = v; rgba[j+3] = 255; }
      await run(new ImageData(rgba, w, h), t);
    }
  } catch (e) { post({ t, frameError: String(e) }); }
};
init();
</script></body></html>
"""#

final class BenchScheme: NSObject, WKURLSchemeHandler {
    let root: URL
    let lock = NSLock()
    var frame = Data()
    init(root: URL) { self.root = root }
    func setFrame(_ d: Data) { lock.lock(); frame = d; lock.unlock() }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let url = task.request.url!
        var data: Data
        var mime = "application/octet-stream"
        if url.path == "/frame" { lock.lock(); data = frame; lock.unlock() }
        else if url.path == "/bench.html" { data = Data(benchPage.utf8); mime = "text/html" }
        else {
            let file = root.appendingPathComponent(String(url.path.dropFirst()))
            guard let d = try? Data(contentsOf: file, options: .mappedIfSafe) else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
            data = d
            switch file.pathExtension { case "mjs", "js": mime = "text/javascript"; case "wasm": mime = "application/wasm"; default: break }
        }
        let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"])!
        task.didReceive(r); task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

struct WebConfig {
    var transfer = "b64"        // b64 | jpegpull | rgbapull | lumapull
    var w = 480, h = 360
    var quality = 0.6
    var hz = 30.0
    var seconds = 15.0
    var delegate = "GPU"
    var running = "VIDEO"
    var face = true
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
    var answered = 0, faceSeen = 0, errors = 0
    var lastError = ""
    var yaws: [Double] = []
    var done: (() -> Void)?
    let gpuBefore: Set<pid_t>

    init(cfg: WebConfig, root: URL) {
        self.cfg = cfg
        gpuBefore = Set(WebBench.pidsMatching("com.apple.WebKit.GPU"))
        scheme = BenchScheme(root: root)
        super.init()
        let conf = WKWebViewConfiguration()
        conf.setURLSchemeHandler(scheme, forURLScheme: "ensemble-asset")
        conf.userContentController.add(self, name: "head")
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: conf)
        window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.contentView = view; window.orderFrontRegardless()
        view.load(URLRequest(url: URL(string: "ensemble-asset://local/bench.html?delegate=\(cfg.delegate)&running=\(cfg.running)")!))
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any] else { return }
        if m["ready"] as? Bool == true { ready = true; print("  ready, delegate \(m["delegate"] ?? "?")") }
        else if let e = m["error"] as? String, m["t"] == nil { print("  ERROR \(e)"); exit(1) }
        else if m["t"] != nil {
            inFlight = false
            latencies.append((Date().timeIntervalSinceReferenceDate - sentAt) * 1000)
            answered += 1
            if let e = m["frameError"] as? String { errors += 1; lastError = e }
            if ((m["faces"] as? NSNumber)?.intValue ?? 0) > 0 { faceSeen += 1; if let y = (m["yaw"] as? NSNumber)?.doubleValue { yaws.append(y) } }
        }
    }

    func waitReady() async { while !ready { try? await Task.sleep(nanoseconds: 50_000_000) } }

    func pids() -> (web: pid_t?, others: [pid_t]) {
        let web = (view.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value
        return (web, [])
    }

    func run() async {
        await waitReady()
        let frames = Synthetic.frames(count: 60, face: cfg.face, hand: false)
        let ci = CIContext(options: [.cacheIntermediates: false])
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let q = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        var rgba = [UInt8](repeating: 0, count: cfg.w * cfg.h * 4)
        var scratch = rgba, luma = [UInt8](repeating: 0, count: cfg.w * cfg.h)
        let scale = CGFloat(cfg.w) / 640
        // Warm up: let the first frames compile shaders.
        func submit(_ i: Int) {
            let t = Date().timeIntervalSinceReferenceDate
            sentAt = t
            inFlight = true
            let pb = frames[i % 60]
            switch cfg.transfer {
            case "b64":
                let img = CIImage(cvPixelBuffer: pb).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let d = ci.jpegRepresentation(of: img, colorSpace: srgb, options: [q: cfg.quality])!
                view.evaluateJavaScript("frameB64('\(d.base64EncodedString())', \(t))")
            case "jpegpull":
                let img = CIImage(cvPixelBuffer: pb).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                scheme.setFrame(ci.jpegRepresentation(of: img, colorSpace: srgb, options: [q: cfg.quality])!)
                view.evaluateJavaScript("framePull('jpeg',\(cfg.w),\(cfg.h),\(t))")
            case "rgbapull":
                scaleToRGBA(pb, w: cfg.w, h: cfg.h, into: &rgba)
                scheme.setFrame(Data(rgba))
                view.evaluateJavaScript("framePull('rgba',\(cfg.w),\(cfg.h),\(t))")
            default:
                scaleToLuma(pb, w: cfg.w, h: cfg.h, scratch: &scratch, into: &luma)
                scheme.setFrame(Data(luma))
                view.evaluateJavaScript("framePull('luma',\(cfg.w),\(cfg.h),\(t))")
            }
        }
        // 3 s warm-up at the target rate (not measured).
        var i = 0
        let period = 1.0 / cfg.hz
        func pump(for seconds: Double) async {
            let end = Date().addingTimeInterval(seconds)
            var next = Date()
            while Date() < end {
                if !inFlight { submit(i); i += 1 }
                next = next.addingTimeInterval(period)
                let wait = next.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) } else { next = Date() }
            }
        }
        await pump(for: 4)
        latencies = []; answered = 0; faceSeen = 0; errors = 0; yaws = []
        let web = pids().web
        let gpu = Set(Self.pidsMatching("com.apple.WebKit.GPU")).subtracting(gpuBefore)
        let net = Self.pidsMatching("com.apple.WebKit.Networking")
        func snap() -> (me: CPUTimes, web: Double, gpu: Double, wall: Double) {
            (selfCPU(), web.flatMap { cpuSeconds(pid: $0) } ?? 0, gpu.compactMap { cpuSeconds(pid: $0) }.reduce(0, +), Date().timeIntervalSinceReferenceDate)
        }
        let a = snap()
        await pump(for: cfg.seconds)
        let b = snap()
        let wall = b.wall - a.wall
        let me = ((b.me.user + b.me.system) - (a.me.user + a.me.system)) / wall * 100
        let webCPU = (b.web - a.web) / wall * 100, gpuCPU = (b.gpu - a.gpu) / wall * 100
        let sorted = latencies.sorted()
        let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2], p95 = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count) * 0.95)]
        _ = net
        let rss = web.map { Self.rssMB(pid: $0) } ?? 0
        print(String(format: "  %-9@ %dx%d %@ %@ @%.0fHz | answered %.1f/s  latency p50 %.1f p95 %.1f ms | cpu%%: harness %.1f  webcontent %.1f  gpu %.1f  total %.1f | web rss %.0f MB | faces %d/%d err %d %@",
                     cfg.transfer as NSString, cfg.w, cfg.h, cfg.delegate as NSString, cfg.running as NSString, cfg.hz,
                     Double(answered) / wall, p50, p95, me, webCPU, gpuCPU, me + webCPU + gpuCPU, rss, faceSeen, answered, errors, lastError as NSString))
        if let lo = yaws.min(), let hi = yaws.max() { print(String(format: "      yaw range %.4f ... %.4f rad over %d readings", lo, hi, yaws.count)) }
        done?()
    }

    static func pidsMatching(_ s: String) -> [pid_t] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-f", s]
        let out = Pipe(); p.standardOutput = out
        try? p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
    }

    static func rssMB(pid: pid_t) -> Double {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
        return rc == 0 ? Double(info.ri_resident_size) / 1_048_576 : 0
    }
}

@MainActor
func runWeb(_ cfg: WebConfig) {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Ensemble/Resources/web")
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let bench = WebBench(cfg: cfg, root: root)
    bench.done = { exit(0) }
    Task { @MainActor in await bench.run() }
    app.run()
}
