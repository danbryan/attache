#!/usr/bin/env swift

import AppKit
import Foundation

// Regenerates the public web/marketing brand images from the current robot
// artwork so they stay in lockstep with the app icon (INF-291 rebrand):
//   - favicon.png (128) and apple-touch-icon.png (180) for attache.fm
//   - the 1280x720 YouTube thumbnail ("Any voice. Any personality.")
//
// The robot tile below mirrors AttacheAppIcon.draw / generate-app-icon.swift's
// drawIcon so every surface renders the same Attaché head. Edit those together.
//
// usage: generate-brand-web-assets.swift <favicon.png> <apple-touch-icon.png> <thumb.png>

guard CommandLine.arguments.count == 4 else {
    fputs("usage: generate-brand-web-assets.swift <favicon.png> <apple-touch-icon.png> <thumb.png>\n", stderr)
    exit(2)
}
let faviconURL = URL(fileURLWithPath: CommandLine.arguments[1])
let appleTouchURL = URL(fileURLWithPath: CommandLine.arguments[2])
let thumbURL = URL(fileURLWithPath: CommandLine.arguments[3])

// The robot app-icon tile, filling a `side` x `side` square. Verbatim from
// scripts/generate-app-icon.swift (drawIcon) so the geometry matches exactly.
func drawIcon(side: CGFloat) {
    let s = side / 512
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
    }
    let k: CGFloat = 3.2
    let ox: CGFloat = 256 - 120 * k
    let oy: CGFloat = 256 - 96 * k
    func m(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: (ox + x * k) * s, y: (512 - oy - y * k) * s)
    }
    func mrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: (ox + x * k) * s, y: (512 - oy - (y + h) * k) * s, width: w * k * s, height: h * k * s)
    }

    let tileTop = NSColor(srgbRed: 0.180, green: 0.565, blue: 1.000, alpha: 1)
    let tileMid = NSColor(srgbRed: 0.043, green: 0.420, blue: 0.902, alpha: 1)
    let tileDeep = NSColor(srgbRed: 0.024, green: 0.235, blue: 0.620, alpha: 1)
    let ringColor = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.14)
    let white = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1)
    let steel = NSColor(srgbRed: 0.780, green: 0.816, blue: 0.863, alpha: 1)
    let screenNavy = NSColor(srgbRed: 0.063, green: 0.141, blue: 0.243, alpha: 1)
    let led = NSColor(srgbRed: 0.400, green: 0.890, blue: 1.000, alpha: 1)
    let coral = NSColor(srgbRed: 1.0, green: 0.616, blue: 0.631, alpha: 1)

    let tile = NSBezierPath(roundedRect: rect(28, 28, 456, 456), xRadius: 112 * s, yRadius: 112 * s)
    NSGradient(colors: [tileTop, tileMid, tileDeep])?.draw(in: tile, angle: 305)

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()

    ringColor.setStroke()
    for radius in [150.0, 205.0] as [CGFloat] {
        let circle = NSBezierPath(ovalIn: rect(256 - radius, 256 - radius, radius * 2, radius * 2))
        circle.lineWidth = 5 * s
        circle.stroke()
    }

    let arcSpecs: [(radius: CGFloat, alpha: CGFloat)] = [(24, 1.0), (33, 0.62), (42, 0.34)]
    for spec in arcSpecs {
        white.withAlphaComponent(spec.alpha).setStroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: m(120, 56), radius: spec.radius * k * s, startAngle: 52, endAngle: 128)
        arc.lineWidth = 7 * k * s
        arc.lineCapStyle = .round
        arc.stroke()
    }

    steel.setStroke()
    let stem = NSBezierPath()
    stem.lineWidth = 3 * k * s
    stem.lineCapStyle = .round
    stem.move(to: m(120, 82))
    stem.line(to: m(120, 73))
    stem.stroke()
    coral.setFill()
    NSBezierPath(ovalIn: mrect(116.5, 64, 7, 7)).fill()

    steel.setFill()
    NSBezierPath(roundedRect: mrect(88, 82, 64, 60), xRadius: 14 * k * s, yRadius: 14 * k * s).fill()
    screenNavy.setFill()
    NSBezierPath(roundedRect: mrect(94, 92, 52, 34), xRadius: 8 * k * s, yRadius: 8 * k * s).fill()

    led.setFill()
    NSBezierPath(roundedRect: mrect(99, 100.5, 14, 11), xRadius: 2.5 * k * s, yRadius: 2.5 * k * s).fill()
    NSBezierPath(roundedRect: mrect(127, 100.5, 14, 11), xRadius: 2.5 * k * s, yRadius: 2.5 * k * s).fill()

    coral.setFill()
    NSBezierPath(ovalIn: mrect(92.5, 117, 4, 4)).fill()
    NSBezierPath(ovalIn: mrect(143.5, 117, 4, 4)).fill()

    screenNavy.setFill()
    NSBezierPath(roundedRect: mrect(109.2, 131, 21.6, 3.5), xRadius: 1.75 * k * s, yRadius: 1.75 * k * s).fill()

    NSGraphicsContext.restoreGraphicsState()
}

func makeBitmap(width: Int, height: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
}

func render(_ rep: NSBitmapImageRep, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

// Web icons: the robot tile alone.
for (px, url) in [(128, faviconURL), (180, appleTouchURL)] {
    let rep = makeBitmap(width: px, height: px)
    render(rep) { drawIcon(side: CGFloat(px)) }
    try writePNG(rep, to: url)
    print(url.path)
}

// The robot tile rendered to an NSImage for compositing onto the thumbnail.
func tileImage(side: Int) -> NSImage {
    let rep = makeBitmap(width: side, height: side)
    render(rep) { drawIcon(side: CGFloat(side)) }
    let image = NSImage(size: NSSize(width: side, height: side))
    image.addRepresentation(rep)
    return image
}

// YouTube thumbnail: dark aurora ground, headline, waveform, robot tile.
let W = 1280, H = 720
let thumb = makeBitmap(width: W, height: H)
render(thumb) {
    let bgTop = NSColor(srgbRed: 0.043, green: 0.055, blue: 0.098, alpha: 1)
    let bgBottom = NSColor(srgbRed: 0.016, green: 0.020, blue: 0.035, alpha: 1)
    let blue = NSColor(srgbRed: 0.157, green: 0.549, blue: 1.0, alpha: 1)
    let purple = NSColor(srgbRed: 0.353, green: 0.180, blue: 0.651, alpha: 1)
    let waveBlue = NSColor(srgbRed: 0.118, green: 0.541, blue: 1.0, alpha: 1)

    NSGradient(colors: [bgTop, bgBottom])?.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -55)

    // Aurora washes: cool blue behind the tile, faint violet lower-left.
    let tileCenter = NSPoint(x: 1048, y: 360)
    NSGradient(colors: [blue.withAlphaComponent(0.24), blue.withAlphaComponent(0)])?
        .draw(fromCenter: tileCenter, radius: 0, toCenter: tileCenter, radius: 450,
              options: .drawsBeforeStartingLocation)
    let violetCenter = NSPoint(x: 120, y: 90)
    NSGradient(colors: [purple.withAlphaComponent(0.20), purple.withAlphaComponent(0)])?
        .draw(fromCenter: violetCenter, radius: 0, toCenter: violetCenter, radius: 430,
              options: .drawsBeforeStartingLocation)

    // Robot tile, right of center, with a soft drop shadow for depth.
    let tileSide = 400
    let tileRect = NSRect(x: 848, y: 160, width: tileSide, height: tileSide)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    shadow.shadowBlurRadius = 46
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    tileImage(side: tileSide).draw(in: tileRect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    // Waveform, lower-left, bars growing from a common baseline.
    let heights: [CGFloat] = [26, 44, 66, 40, 90, 112, 70, 100, 54, 82, 46, 32, 22]
    let barW: CGFloat = 15, gap: CGFloat = 9, baseX: CGFloat = 88, baseY: CGFloat = 92
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = waveBlue.withAlphaComponent(0.6)
    glow.shadowBlurRadius = 16
    glow.shadowOffset = .zero
    glow.set()
    waveBlue.setFill()
    for (i, h) in heights.enumerated() {
        let x = baseX + CGFloat(i) * (barW + gap)
        NSBezierPath(roundedRect: NSRect(x: x, y: baseY, width: barW, height: h),
                     xRadius: barW / 2, yRadius: barW / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    // Headline: "Any voice." / "Any personality." with the accent word in blue.
    // Sized so the second line clears the tile's left edge (x=848).
    let titleFont = NSFont.systemFont(ofSize: 96, weight: .heavy)
    let white = NSColor.white
    let leftX: CGFloat = 84
    let line1Y: CGFloat = 400
    let line2Y: CGFloat = 268

    ("Any voice." as NSString).draw(at: NSPoint(x: leftX, y: line1Y),
        withAttributes: [.font: titleFont, .foregroundColor: white])

    let anyAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: white]
    ("Any " as NSString).draw(at: NSPoint(x: leftX, y: line2Y), withAttributes: anyAttrs)
    let anyWidth = ("Any " as NSString).size(withAttributes: anyAttrs).width
    ("personality." as NSString).draw(at: NSPoint(x: leftX + anyWidth, y: line2Y),
        withAttributes: [.font: titleFont, .foregroundColor: blue])
}
try writePNG(thumb, to: thumbURL)
print(thumbURL.path)
