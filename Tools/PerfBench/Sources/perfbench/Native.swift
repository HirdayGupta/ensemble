import Accelerate
import CoreImage
import CoreVideo
import Foundation
import Vision

/// Scales a BGRA buffer to w x h and swaps to RGBA. Returns tightly packed bytes.
func scaleToRGBA(_ pb: CVPixelBuffer, w: Int, h: Int, into out: inout [UInt8]) {
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    var src = vImage_Buffer(data: CVPixelBufferGetBaseAddress(pb), height: vImagePixelCount(CVPixelBufferGetHeight(pb)),
                            width: vImagePixelCount(CVPixelBufferGetWidth(pb)), rowBytes: CVPixelBufferGetBytesPerRow(pb))
    out.withUnsafeMutableBytes { raw in
        var dst = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
        vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
        var map: [UInt8] = [2, 1, 0, 3]
        vImagePermuteChannels_ARGB8888(&dst, &dst, &map, vImage_Flags(kvImageNoFlags))
    }
}

/// Same, but the destination is a single luma plane (what a luma-only transfer would carry).
func scaleToLuma(_ pb: CVPixelBuffer, w: Int, h: Int, scratch: inout [UInt8], into out: inout [UInt8]) {
    scaleToRGBA(pb, w: w, h: h, into: &scratch)
    scratch.withUnsafeMutableBytes { s in
        out.withUnsafeMutableBytes { o in
            var src = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            var dst = vImage_Buffer(data: o.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
            // RGBA -> Planar8 luma, Rec.601-ish weights in 0...256.
            var matrix: [Int16] = [77, 150, 29, 0]
            vImageMatrixMultiply_ARGB8888ToPlanar8(&src, &dst, &matrix, 256, nil, 0, vImage_Flags(kvImageNoFlags))
        }
    }
}

/// Scales a BGRA frame to w x h, tightly packed, as RGBA or left as BGRA, into `out` (w * h * 4 bytes). The same
/// vImage calls as `FrameAnalyzer.facePixels` in the app.
func scalePixels(_ pb: CVPixelBuffer, into out: UnsafeMutableRawBufferPointer, w: Int, h: Int, rgba: Bool) {
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    var src = vImage_Buffer(data: CVPixelBufferGetBaseAddress(pb), height: vImagePixelCount(CVPixelBufferGetHeight(pb)),
                            width: vImagePixelCount(CVPixelBufferGetWidth(pb)), rowBytes: CVPixelBufferGetBytesPerRow(pb))
    var dst = vImage_Buffer(data: out.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
    vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
    if rgba {
        let map: [UInt8] = [2, 1, 0, 3]
        vImagePermuteChannels_ARGB8888(&dst, &dst, map, vImage_Flags(kvImageNoFlags))
    }
}

func visionPerform(_ pb: CVPixelBuffer, request: VNDetectHumanHandPoseRequest) -> Int {
    let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
    try? handler.perform([request])
    return request.results?.count ?? 0
}

func runNative() {
    let frames = Synthetic.frames(count: 60)
    Synthetic.writePNG(frames[0], to: "/tmp/ensemble-perfbench-frame.png")
    let noHand = Synthetic.frames(count: 60, face: true, hand: false)
    let none = Synthetic.frames(count: 60, face: false, hand: false)
    let ci = CIContext(options: [.cacheIntermediates: false])
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    let q = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)

    print("JPEG via CIContext (what the app does now)")
    for (name, scale, quality) in [("480x360 q0.6 (now)", 0.75, 0.6), ("320x240 q0.6", 0.5, 0.6), ("320x240 q0.4", 0.5, 0.4), ("256x192 q0.5", 0.4, 0.5)] {
        var size = 0
        bench("jpeg \(name)", n: 300) { i in
            let img = CIImage(cvPixelBuffer: frames[i % 60]).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let d = ci.jpegRepresentation(of: img, colorSpace: srgb, options: [q: quality])!
            size = d.count
            _ = d.base64EncodedString()
        }
        print("      bytes \(size), base64 chars \(size * 4 / 3)")
    }

    print("vImage scale + channel swap to RGBA")
    for (w, h) in [(480, 360), (320, 240), (256, 192), (192, 144)] {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        bench("rgba \(w)x\(h) (\(w * h * 4) bytes)", n: 600) { i in scaleToRGBA(frames[i % 60], w: w, h: h, into: &out) }
    }
    do {
        var scratch = [UInt8](repeating: 0, count: 320 * 240 * 4), out = [UInt8](repeating: 0, count: 320 * 240)
        bench("luma 320x240 (\(320 * 240) bytes)", n: 600) { i in scaleToLuma(frames[i % 60], w: 320, h: 240, scratch: &scratch, into: &out) }
    }

    print("Vision hand pose, one request per frame")
    let request = VNDetectHumanHandPoseRequest(); request.maximumHandCount = 1
    var found = 0
    bench("640x480 hand emoji present", n: 200) { i in found = visionPerform(frames[i % 60], request: request) }
    print("      hands found: \(found)")
    bench("640x480 no hand (face only)", n: 200) { i in found = visionPerform(noHand[i % 60], request: request) }
    print("      hands found: \(found)")
    bench("640x480 empty wall", n: 200) { i in found = visionPerform(none[i % 60], request: request) }

    print("Brightness grid (the covered-camera check)")
    bench("40x30 sampled grid", n: 3000) { i in
        let pb = frames[i % 60]
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let base = CVPixelBufferGetBaseAddress(pb)!, stride = CVPixelBufferGetBytesPerRow(pb)
        var sum = 0.0
        for r in 0..<30 { let row = base.advanced(by: ((r * 480) / 30 + 8) * stride)
            for c in 0..<40 { let px = row.advanced(by: ((c * 640) / 40 + 8) * 4).assumingMemoryBound(to: UInt8.self)
                sum += 0.0722 * Double(px[0]) + 0.7152 * Double(px[1]) + 0.2126 * Double(px[2]) } }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        if sum < 0 { print(sum) }
    }
}
