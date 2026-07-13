#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate-app-icon.swift /path/to/Attache.icns\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let fileManager = FileManager.default
let iconsetURL = fileManager.temporaryDirectory
    .appendingPathComponent("Attache-\(UUID().uuidString).iconset", isDirectory: true)

try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconsetURL) }

// Mirrors AttacheAppIcon.draw in Sources/AttacheApp/AppIcon.swift so the
// packaged icon and the running app's Dock icon stay identical: Volt, the
// default companion character (INF-286, original in-house artwork), on the
// macOS-blue tile with the voice-arc crown.
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

    // macOS-blue brand palette, shared with the Bubbles-era tile.
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

    // Voice arcs crown Volt just like they crowned Bubbles: the brand is
    // still "give your agents a voice". AppKit is y-up, so the upward
    // arcs sweep counterclockwise around the shared center.
    let arcSpecs: [(radius: CGFloat, alpha: CGFloat)] = [(24, 1.0), (33, 0.62), (42, 0.34)]
    for spec in arcSpecs {
        white.withAlphaComponent(spec.alpha).setStroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: m(120, 56), radius: spec.radius * k * s, startAngle: 52, endAngle: 128)
        arc.lineWidth = 7 * k * s
        arc.lineCapStyle = .round
        arc.stroke()
    }

    // Volt: antenna, steel plate, navy screen, LED eyes, side bolts, and
    // the resting smile bar.
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

func pngData(pixelSize: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "AttacheIcon", code: 1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize).fill()
    drawIcon(side: CGFloat(pixelSize))

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AttacheIcon", code: 2)
    }
    return png
}

let specs: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2)
]

for spec in specs {
    let pixels = spec.points * spec.scale
    let suffix = spec.scale == 1 ? "" : "@\(spec.scale)x"
    let name = "icon_\(spec.points)x\(spec.points)\(suffix).png"
    try pngData(pixelSize: pixels).write(to: iconsetURL.appendingPathComponent(name))
}

try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try? fileManager.removeItem(at: outputURL)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()

if process.terminationStatus != 0 {
    exit(process.terminationStatus)
}
