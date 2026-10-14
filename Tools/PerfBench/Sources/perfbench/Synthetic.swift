import AppKit
import CoreVideo

enum Synthetic {
    static let width = 640, height = 480

    /// A 640x480 BGRA scene: a gradient wall, a face emoji and a hand emoji. `variants` copies are offset a few pixels
    /// so consecutive frames differ like a live camera.
    static func frames(count variants: Int, face: Bool = true, hand: Bool = true) -> [CVPixelBuffer] {
        let base = render(face: face, hand: hand)
        return (0..<variants).map { i in
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer)
            let pb = buffer!
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            let dx = CGFloat(sin(Double(i) / Double(variants) * 2 * .pi) * 6), dy = CGFloat(cos(Double(i) / Double(variants) * 2 * .pi) * 4)
            ctx.draw(base, in: CGRect(x: dx, y: dy, width: CGFloat(width), height: CGFloat(height)))
            CVPixelBufferUnlockBaseAddress(pb, [])
            return pb
        }
    }

    static func render(face: Bool, hand: Bool) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [CGColor(red: 0.55, green: 0.5, blue: 0.45, alpha: 1), CGColor(red: 0.25, green: 0.27, blue: 0.3, alpha: 1)] as CFArray,
                              locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: width, y: height), options: [])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        if face { ("😀" as NSString).draw(at: CGPoint(x: 170, y: 120), withAttributes: [.font: NSFont(name: "AppleColorEmoji", size: 300) ?? NSFont.systemFont(ofSize: 300)]) }
        if hand { ("✋" as NSString).draw(at: CGPoint(x: 470, y: 250), withAttributes: [.font: NSFont(name: "AppleColorEmoji", size: 150) ?? NSFont.systemFont(ofSize: 150)]) }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    static func writePNG(_ pb: CVPixelBuffer, to path: String) {
        let ci = CIImage(cvPixelBuffer: pb)
        let rep = NSBitmapImageRep(ciImage: ci)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
