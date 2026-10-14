import AppKit
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
setvbuf(stdout, nil, _IOLBF, 0)
guard let mode = args.first else { print("usage: perfbench native | web [transfer=b64|jpegpull|rgbapull|lumapull] [w=480] [h=360] [q=0.6] [hz=30] [sec=15] [delegate=GPU|CPU] [running=VIDEO|IMAGE] [face=1|0]"); exit(2) }
switch mode {
case "native": runNative()
case "web":
    var cfg = WebConfig()
    for a in args.dropFirst() {
        let kv = a.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2 else { continue }
        switch kv[0] {
        case "transfer": cfg.transfer = kv[1]
        case "w": cfg.w = Int(kv[1])!
        case "h": cfg.h = Int(kv[1])!
        case "q": cfg.quality = Double(kv[1])!
        case "hz": cfg.hz = Double(kv[1])!
        case "sec": cfg.seconds = Double(kv[1])!
        case "delegate": cfg.delegate = kv[1]
        case "running": cfg.running = kv[1]
        case "face": cfg.face = kv[1] == "1"
        default: break
        }
    }
    MainActor.assumeIsolated { runWeb(cfg) }
default: print("unknown mode"); exit(2)
}
