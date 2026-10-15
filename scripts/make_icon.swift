#!/usr/bin/env swift
// Renders Yap's app icon to app/Resources/AppIcon.icns (+ a 1024 preview PNG).
// Apple-style rounded-square tile in the brand gradient, with the Yap mark: a
// speech bubble whose face has a waveform for a mouth.
// Run: swift scripts/make_icon.swift
import AppKit

let repoRoot = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
    .deletingLastPathComponent().deletingLastPathComponent()
let resDir = repoRoot.appending(path: "app/Resources")
let iconset = repoRoot.appending(path: "dist/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: resDir, withIntermediateDirectories: true)

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

    // Brand gradient, corner to corner: violet -> magenta -> coral (Theme.swift).
    cg.saveGState()
    shape.addClip()
    let violet = NSColor(srgbRed: 0.49, green: 0.36, blue: 1.00, alpha: 1)   // #7D5CFF
    let magenta = NSColor(srgbRed: 0.86, green: 0.15, blue: 0.47, alpha: 1)  // #DB2777
    let coral = NSColor(srgbRed: 0.98, green: 0.42, blue: 0.36, alpha: 1)    // #FA6B5C
    NSGradient(colors: [violet, magenta, coral], atLocations: [0, 0.62, 1], colorSpace: .sRGB)!
        .draw(in: rect, angle: -50)
    // Soft light from the top-left, so the tile reads as a lit surface.
    NSGradient(colors: [NSColor(white: 1, alpha: 0.30), NSColor(white: 1, alpha: 0)])!
        .draw(fromCenter: NSPoint(x: rect.minX + rect.width * 0.22, y: rect.maxY - rect.height * 0.12), radius: 0,
              toCenter: NSPoint(x: rect.minX + rect.width * 0.22, y: rect.maxY - rect.height * 0.12),
              radius: rect.width * 0.75, options: [])

    // The mark: a speech bubble with a face whose mouth is a waveform. It talks
    // (the mouth) and it listens (the face looks at you): the two halves of Yap.
    let u = rect.width
    let bw = u * 0.62, bh = u * 0.50
    let bx = rect.midX - bw / 2, by = rect.midY - bh / 2 + u * 0.035
    let bubbleRect = NSRect(x: bx, y: by, width: bw, height: bh)
    let bubble = NSBezierPath(roundedRect: bubbleRect, xRadius: bh * 0.46, yRadius: bh * 0.46)
    // Tail, bottom-left, curving out of the body.
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: bx + bw * 0.20, y: by + bh * 0.20))
    tail.curve(to: NSPoint(x: bx + bw * 0.06, y: by - bh * 0.20),
               controlPoint1: NSPoint(x: bx + bw * 0.18, y: by + bh * 0.02),
               controlPoint2: NSPoint(x: bx + bw * 0.14, y: by - bh * 0.10))
    tail.curve(to: NSPoint(x: bx + bw * 0.42, y: by + bh * 0.06),
               controlPoint1: NSPoint(x: bx + bw * 0.20, y: by - bh * 0.16),
               controlPoint2: NSPoint(x: bx + bw * 0.34, y: by - bh * 0.06))
    tail.close()
    bubble.append(tail)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -u * 0.025), blur: u * 0.06,
                 color: NSColor(srgbRed: 0.30, green: 0.05, blue: 0.25, alpha: 0.45).cgColor)
    NSColor.white.setFill(); bubble.fill()
    cg.restoreGState()
    cg.saveGState()
    bubble.addClip()
    NSGradient(colors: [NSColor.white, NSColor(srgbRed: 0.95, green: 0.92, blue: 1.0, alpha: 1)])!
        .draw(in: bubble.bounds, angle: -90)
    cg.restoreGState()

    // Eyes: two tall ovals with a small highlight.
    let ink = NSColor(srgbRed: 0.17, green: 0.10, blue: 0.36, alpha: 1)      // deep indigo
    let ew = u * 0.052, eh = u * 0.075
    let eyeY = by + bh * 0.56
    for dx in [-1.0, 1.0] {
        let ex = rect.midX + CGFloat(dx) * bw * 0.17 - ew / 2
        ink.setFill(); NSBezierPath(ovalIn: NSRect(x: ex, y: eyeY, width: ew, height: eh)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: ex + ew * 0.52, y: eyeY + eh * 0.58, width: ew * 0.32, height: ew * 0.32)).fill()
    }
    // Cheeks.
    for dx in [-1.0, 1.0] {
        let cx = rect.midX + CGFloat(dx) * bw * 0.31
        NSColor(srgbRed: 1.0, green: 0.45, blue: 0.55, alpha: 0.30).setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - u * 0.04, y: eyeY - u * 0.035, width: u * 0.08, height: u * 0.045)).fill()
    }
    // Mouth: a waveform in the brand gradient.
    let heights: [CGFloat] = [0.35, 0.75, 1.0, 0.75, 0.35]
    let barW = u * 0.034, gap = u * 0.024
    let span = barW * CGFloat(heights.count) + gap * CGFloat(heights.count - 1)
    let maxH = bh * 0.30
    let mouthCY = by + bh * 0.30
    let mouth = NSBezierPath()
    var x = rect.midX - span / 2
    for h in heights {
        let hh = max(barW, maxH * h)
        mouth.append(NSBezierPath(roundedRect: NSRect(x: x, y: mouthCY - hh / 2, width: barW, height: hh),
                                  xRadius: barW / 2, yRadius: barW / 2))
        x += barW + gap
    }
    cg.saveGState()
    mouth.addClip()
    NSGradient(colors: [violet, magenta, coral])!.draw(in: mouth.bounds, angle: 0)
    cg.restoreGState()

    // Two sound arcs off the top-right: it's mid-sentence.
    for i in 0..<2 {
        // Centred inside the bubble's top-right, so both arcs hug its corner.
        let r = u * (0.18 + CGFloat(i) * 0.065)
        let c = NSPoint(x: bx + bw * 0.78, y: by + bh * 0.74)
        let arc = NSBezierPath()
        arc.appendArc(withCenter: c, radius: r, startAngle: 12, endAngle: 78)
        arc.lineWidth = u * 0.03; arc.lineCapStyle = .round
        NSColor(white: 1, alpha: i == 0 ? 0.95 : 0.6).setStroke(); arc.stroke()
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
