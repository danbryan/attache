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
// default Attaché character (INF-286, original in-house artwork), on the
// macOS-blue tile with the voice-arc crown.
func drawIcon(side: CGFloat) {
    let s = side / 512
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
    }
    // The face is scaled up to fill the tile (2026-07-17 icon refresh); the
    // head, not a plaque, is the icon. Centered on the plate's midpoint.
    let k: CGFloat = 4.8
    let ox: CGFloat = 256 - 120 * k
    let oy: CGFloat = 256 - 112 * k
    func mrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: (ox + x * k) * s, y: (512 - oy - (y + h) * k) * s, width: w * k * s, height: h * k * s)
    }

    let steel = NSColor(srgbRed: 0.780, green: 0.816, blue: 0.863, alpha: 1)
    let screenNavy = NSColor(srgbRed: 0.063, green: 0.141, blue: 0.243, alpha: 1)
    let led = NSColor(srgbRed: 0.400, green: 0.890, blue: 1.000, alpha: 1)
    let coral = NSColor(srgbRed: 1.0, green: 0.616, blue: 0.631, alpha: 1)
    // A dark tile so the robot face reads as the whole icon. The voice-bar
    // mouth now carries the "give your agents a voice" motif the arc crown
    // used to. Mirrors AttacheAppIcon.draw exactly.
    let bgTop = NSColor(srgbRed: 0.086, green: 0.118, blue: 0.180, alpha: 1)
    let bgDeep = NSColor(srgbRed: 0.027, green: 0.043, blue: 0.086, alpha: 1)

    let tile = NSBezierPath(roundedRect: rect(28, 28, 456, 456), xRadius: 112 * s, yRadius: 112 * s)
    NSGradient(colors: [bgTop, bgDeep])?.draw(in: tile, angle: 270)

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()

    // Steel plate, navy screen, LED eyes, coral side bolts.
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

    // Voice-bar mouth: five navy equalizer bars below the screen, a frozen
    // "speaking" pose that replaces the resting smile.
    screenNavy.setFill()
    let barHeights: [CGFloat] = [6.5, 11, 8.5, 13, 7]
    for (index, height) in barHeights.enumerated() {
        let x = 108 + CGFloat(index) * 6
        NSBezierPath(
            roundedRect: mrect(x - 1.8, 133 - height / 2, 3.6, height),
            xRadius: 1.8 * k * s, yRadius: 1.8 * k * s
        ).fill()
    }

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
