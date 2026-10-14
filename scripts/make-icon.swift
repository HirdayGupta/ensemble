#!/usr/bin/env swift
// Draws the Ensemble app icon with CoreGraphics and writes Assets/AppIcon.iconset, Assets/AppIcon.icns and Assets/logo.png.
// Run from the repo root: swift scripts/make-icon.swift
import AppKit
import CoreGraphics
import Foundation

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

let fullRange: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}

/// Apple-style continuous-corner squircle (superellipse), centred on (512, 512).
func squircle(half: CGFloat, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 360
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = 512 + half * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = 512 + half * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil)
}

func fill(_ ctx: CGContext, _ path: CGPath, top: CGColor, bottom: CGColor, in rect: CGRect) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, top), (1, bottom)]), start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: fullRange)
    ctx.restoreGState()
}

/// The closed fist, front view, as one silhouette: a palm block with four knuckle bumps, plus the thumb across it.
func fistPaths() -> (silhouette: CGPath, thumb: CGPath, creases: [CGPath]) {
    let left: CGFloat = 372, width: CGFloat = 280, gap: CGFloat = 8
    let fingerW = (width - 3 * gap) / 4
    let silhouette = CGMutablePath()
    silhouette.addPath(roundedRect(CGRect(x: left - 6, y: 300, width: width + 12, height: 280), 84))
    let heights: [CGFloat] = [176, 196, 196, 172]
    var creases: [CGPath] = []
    for i in 0..<4 {
        let x = left + CGFloat(i) * (fingerW + gap)
        silhouette.addPath(roundedRect(CGRect(x: x, y: 646 - heights[i], width: fingerW, height: heights[i]), fingerW / 2))
        creases.append(roundedRect(CGRect(x: x + 1, y: 478, width: fingerW - 2, height: 110), (fingerW - 2) / 2))
    }
    let thumb = roundedRect(CGRect(x: left - 16, y: 346, width: 216, height: 88), 44)
    return (silhouette, thumb, creases)
}

func drawWaves(_ ctx: CGContext, small: Bool) {
    let center = CGPoint(x: 512, y: 484)
    let radii: [CGFloat] = [222, 292, 362]
    let alphas: [CGFloat] = [0.95, 0.7, 0.45]
    let spread: CGFloat = 36 * .pi / 180
    ctx.setLineCap(.round)
    ctx.setLineWidth(small ? 34 : 28)
    for (radius, alpha) in zip(radii, alphas) {
        ctx.setStrokeColor(rgb(0xFFFFFF, alpha))
        for side in [CGFloat(0), .pi] {
            ctx.addArc(center: center, radius: radius, startAngle: side - spread, endAngle: side + spread, clockwise: false)
            ctx.strokePath()
        }
    }
}

func draw(_ ctx: CGContext, pixels: Int) {
    let small = pixels <= 64
    let body = squircle(half: 412)
    let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)

    // Contact shadow under the whole icon.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 24, color: rgb(0x0A0830, 0.30))
    ctx.addPath(body)
    ctx.setFillColor(rgb(0x1B1580))
    ctx.fillPath()
    ctx.restoreGState()

    // Base gradient: electric violet down to deep indigo.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0x7B6BFF)), (0.45, rgb(0x4A3FE0)), (1, rgb(0x1A1470))]),
        start: CGPoint(x: 330, y: 924), end: CGPoint(x: 700, y: 100), options: fullRange)
    // Warm bloom bottom-right and cool bloom top-left give the surface depth.
    ctx.drawRadialGradient(
        gradient([(0, rgb(0xFF5FA8, 0.55)), (1, rgb(0xFF5FA8, 0))]),
        startCenter: CGPoint(x: 800, y: 190), startRadius: 0, endCenter: CGPoint(x: 800, y: 190), endRadius: 460, options: [])
    ctx.drawRadialGradient(
        gradient([(0, rgb(0x4FE0FF, 0.40)), (1, rgb(0x4FE0FF, 0))]),
        startCenter: CGPoint(x: 230, y: 860), startRadius: 0, endCenter: CGPoint(x: 230, y: 860), endRadius: 420, options: [])
    ctx.restoreGState()

    // Glyph with a soft lifted shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 30, color: rgb(0x120C5C, 0.5))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    drawWaves(ctx, small: small)
    let fist = fistPaths()
    fill(ctx, fist.silhouette, top: rgb(0xFFFFFF), bottom: rgb(0xC9C5FF), in: CGRect(x: 366, y: 300, width: 292, height: 346))
    if !small {
        ctx.setStrokeColor(rgb(0x4A3FE0, 0.28))
        ctx.setLineWidth(5)
        ctx.setLineCap(.round)
        for crease in fist.creases { ctx.addPath(crease); ctx.strokePath() }
    }
    // The thumb sits in front: a darker rim above it separates it from the fingers.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 10, color: rgb(0x2A1FA8, 0.45))
    ctx.translateBy(x: 464, y: 390)
    ctx.rotate(by: -7 * .pi / 180)
    ctx.translateBy(x: -464, y: -390)
    fill(ctx, fist.thumb, top: rgb(0xFFFFFF), bottom: rgb(0xE4E1FF), in: CGRect(x: 356, y: 346, width: 216, height: 88))
    ctx.restoreGState()
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Glass sheen over the top, clipped to the squircle.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0xFFFFFF, 0.0)), (1, rgb(0xFFFFFF, 0.20))]),
        start: CGPoint(x: 512, y: 600), end: CGPoint(x: 512, y: 924), options: fullRange)
    ctx.restoreGState()

    // Hairline rim: bright on top, faint underneath.
    ctx.saveGState()
    ctx.setLineWidth(3)
    ctx.addPath(squircle(half: 410))
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0xFFFFFF, 0.05)), (0.5, rgb(0xFFFFFF, 0.15)), (1, rgb(0xFFFFFF, 0.65))]),
        start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: fullRange)
    ctx.restoreGState()
}

func render(pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(ctx, pixels: pixels)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let assets = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Assets")
let iconset = assets.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_256x256", 256), ("icon_512x512", 512),
]
for (name, px) in sizes {
    try render(pixels: px).write(to: iconset.appendingPathComponent("\(name).png"))
    print("wrote \(name).png (\(px)px)")
}
try render(pixels: 1024).write(to: assets.appendingPathComponent("logo.png"))

let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try tool.run()
tool.waitUntilExit()
print(tool.terminationStatus == 0 ? "wrote Assets/AppIcon.icns" : "iconutil failed")
