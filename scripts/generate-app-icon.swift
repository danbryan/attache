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
// packaged icon and the running app's Dock icon stay identical.
func drawIcon(side: CGFloat) {
    let s = side / 512
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: y * s) }
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
    }

    // macOS-blue brand: vivid blue tile, white broadcast rings, white equalizer, white "A".
    let tileTop = NSColor(srgbRed: 0.180, green: 0.565, blue: 1.000, alpha: 1)
    let tileMid = NSColor(srgbRed: 0.043, green: 0.420, blue: 0.902, alpha: 1)
    let tileDeep = NSColor(srgbRed: 0.024, green: 0.235, blue: 0.620, alpha: 1)
    let ring = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.16)
    let barLo = NSColor(srgbRed: 0.720, green: 0.840, blue: 1.000, alpha: 1)
    let barHi = NSColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 1)
    let letterColor = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1)

    let tile = NSBezierPath(roundedRect: rect(28, 28, 456, 456), xRadius: 112 * s, yRadius: 112 * s)
    NSGradient(colors: [tileTop, tileMid, tileDeep])?.draw(in: tile, angle: 305)

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()

    ring.setStroke()
    for radius in [118.0, 165.0, 212.0] as [CGFloat] {
        let circle = NSBezierPath(ovalIn: rect(256 - radius, 280 - radius, radius * 2, radius * 2))
        circle.lineWidth = 5 * s
        circle.stroke()
    }

    let heights: [CGFloat] = [34, 64, 104, 120, 80, 120, 80, 120, 104, 64, 34]
    for (index, height) in heights.enumerated() {
        let t = CGFloat(index) / CGFloat(heights.count - 1)
        NSColor(
            srgbRed: barLo.redComponent + (barHi.redComponent - barLo.redComponent) * t,
            green: barLo.greenComponent + (barHi.greenComponent - barLo.greenComponent) * t,
            blue: barLo.blueComponent + (barHi.blueComponent - barLo.blueComponent) * t,
            alpha: 1
        ).setFill()
        NSBezierPath(
            roundedRect: rect(CGFloat(96 + index * 30), 80, 20, height),
            xRadius: 10 * s,
            yRadius: 10 * s
        ).fill()
    }

    letterColor.setStroke()
    let letter = NSBezierPath()
    letter.lineWidth = 30 * s
    letter.lineCapStyle = .round
    letter.lineJoinStyle = .round
    letter.move(to: point(256, 400)); letter.line(to: point(190, 212))
    letter.move(to: point(256, 400)); letter.line(to: point(322, 212))
    letter.move(to: point(210, 264)); letter.line(to: point(302, 264))
    letter.stroke()

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
