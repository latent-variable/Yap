#!/usr/bin/env swift
// Renders Parley's app icon to app/Resources/AppIcon.icns (+ a 1024 preview PNG).
// Apple-style rounded-square tile, indigo gradient, white waveform mark.
// Run: swift scripts/make_icon.swift
import AppKit

let repoRoot = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
    .deletingLastPathComponent().deletingLastPathComponent()
let resDir = repoRoot.appending(path: "app/Resources")
let iconset = repoRoot.appending(path: "dist/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: resDir, withIntermediateDirectories: true)

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    // Apple icon grid: shape ~824/1024 of canvas, corner radius ~22.37% of shape.
    let margin = s * (100.0 / 1024.0)
    let rect = NSRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let radius = rect.width * 0.2237
    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Soft drop shadow for depth.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                 blur: s * 0.03, color: NSColor(white: 0, alpha: 0.28).cgColor)
    NSColor.black.setFill(); shape.fill()
    cg.restoreGState()

    // Indigo -> violet vertical gradient.
    cg.saveGState()
    shape.addClip()
    let top = NSColor(srgbRed: 0.44, green: 0.49, blue: 1.00, alpha: 1)    // #707DFF
    let bot = NSColor(srgbRed: 0.29, green: 0.24, blue: 0.84, alpha: 1)    // #4A3DD6
    let grad = NSGradient(colors: [top, bot])!
    grad.draw(in: rect, angle: -90)

    // Subtle top sheen.
    let sheen = NSGradient(colors: [NSColor(white: 1, alpha: 0.18), NSColor(white: 1, alpha: 0)])!
    sheen.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)

    // Waveform: rounded vertical bars, symmetric, centered.
    let heights: [CGFloat] = [0.30, 0.52, 0.78, 1.00, 0.78, 0.52, 0.30]
    let n = CGFloat(heights.count)
    let span = rect.width * 0.62
    let barW = span / (n * 1.9)
    let gap = (span - barW * n) / (n - 1)
    let maxH = rect.height * 0.52
    var x = rect.midX - span / 2
    NSColor.white.setFill()
    for h in heights {
        let bh = max(barW, maxH * h)
        let bar = NSRect(x: x, y: rect.midY - bh / 2, width: barW, height: bh)
        NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// iconset members.
let members: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in members {
    try! render(px).write(to: iconset.appending(path: "\(name).png"))
}
// Preview PNG for docs.
try! render(1024).write(to: resDir.appending(path: "icon-1024.png"))
print("rendered iconset + icon-1024.png")
