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
// packaged icon and the running app's Dock icon stay identical: the Bubbles
// mascot (design/attache-logo.svg) on the macOS-blue tile.
func drawIcon(side: CGFloat) {
    let s = side / 512
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
    }
    let k: CGFloat = 1.5
    let ox: CGFloat = (512 - 240 * k) / 2
    let oy: CGFloat = (512 - 240 * k) / 2
    func m(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: (ox + x * k) * s, y: (512 - oy - y * k) * s)
    }
    func mrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: (ox + x * k) * s, y: (512 - oy - (y + h) * k) * s, width: w * k * s, height: h * k * s)
    }
    func quad(_ path: NSBezierPath, from p0: NSPoint, control cp: NSPoint, to p2: NSPoint) {
        let c1 = NSPoint(x: p0.x + 2.0 / 3.0 * (cp.x - p0.x), y: p0.y + 2.0 / 3.0 * (cp.y - p0.y))
        let c2 = NSPoint(x: p2.x + 2.0 / 3.0 * (cp.x - p2.x), y: p2.y + 2.0 / 3.0 * (cp.y - p2.y))
        path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
    }

    let tileTop = NSColor(srgbRed: 0.180, green: 0.565, blue: 1.000, alpha: 1)
    let tileMid = NSColor(srgbRed: 0.043, green: 0.420, blue: 0.902, alpha: 1)
    let tileDeep = NSColor(srgbRed: 0.024, green: 0.235, blue: 0.620, alpha: 1)
    let ringColor = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.14)
    let white = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1)
    let cream = NSColor(srgbRed: 1.0, green: 0.965, blue: 0.894, alpha: 1)
    let navy = NSColor(srgbRed: 0.063, green: 0.141, blue: 0.243, alpha: 1)
    let cheek = NSColor(srgbRed: 1.0, green: 0.616, blue: 0.631, alpha: 0.6)
    let bubbleOrange = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
    let bubbleCream = cream
    let bubbleGreen = NSColor(srgbRed: 0.063, green: 0.639, blue: 0.498, alpha: 1)

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

    let arcSpecs: [(radius: CGFloat, alpha: CGFloat)] = [(40, 1.0), (66, 0.62), (90, 0.34)]
    for spec in arcSpecs {
        white.withAlphaComponent(spec.alpha).setStroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: m(120, 89), radius: spec.radius * k * s, startAngle: 48, endAngle: 132)
        arc.lineWidth = 9 * k * s
        arc.lineCapStyle = .round
        arc.stroke()
    }

    white.setStroke()
    let limbs = NSBezierPath()
    limbs.lineWidth = 7 * k * s
    limbs.lineCapStyle = .round
    limbs.move(to: m(102, 140))
    limbs.curve(to: m(70, 160), controlPoint1: m(90, 150), controlPoint2: m(80, 155))
    limbs.move(to: m(120, 145))
    limbs.line(to: m(120, 170))
    limbs.move(to: m(138, 140))
    limbs.curve(to: m(170, 160), controlPoint1: m(150, 150), controlPoint2: m(160, 155))
    limbs.stroke()

    cream.setFill()
    NSBezierPath(ovalIn: mrect(87, 79, 66, 66)).fill()

    navy.setStroke()
    let eyes = NSBezierPath()
    eyes.lineWidth = 5 * k * s
    eyes.lineCapStyle = .round
    eyes.move(to: m(97, 107))
    quad(eyes, from: m(97, 107), control: m(105, 97), to: m(113, 107))
    eyes.move(to: m(127, 107))
    quad(eyes, from: m(127, 107), control: m(135, 97), to: m(143, 107))
    eyes.stroke()

    cheek.setFill()
    NSBezierPath(ovalIn: mrect(89, 113, 12, 12)).fill()
    NSBezierPath(ovalIn: mrect(139, 113, 12, 12)).fill()

    navy.setFill()
    let mouth = NSBezierPath()
    mouth.move(to: m(108, 119))
    mouth.curve(to: m(132, 119), controlPoint1: m(111, 134), controlPoint2: m(129, 134))
    mouth.close()
    mouth.fill()

    let bubbles: [(x: CGFloat, y: CGFloat, tail: [(CGFloat, CGFloat)], color: NSColor, dot: NSColor)] = [
        (36, 168, [(62, 168), (68, 160), (54, 168)], bubbleOrange, cream),
        (100, 182, [(120, 182), (120, 173), (111, 182)], bubbleCream, tileMid),
        (164, 168, [(178, 168), (172, 160), (186, 168)], bubbleGreen, cream),
    ]
    for bubble in bubbles {
        bubble.color.setFill()
        NSBezierPath(roundedRect: mrect(bubble.x, bubble.y, 40, 27), xRadius: 12 * k * s, yRadius: 12 * k * s).fill()
        let tail = NSBezierPath()
        tail.move(to: m(bubble.tail[0].0, bubble.tail[0].1))
        tail.line(to: m(bubble.tail[1].0, bubble.tail[1].1))
        tail.line(to: m(bubble.tail[2].0, bubble.tail[2].1))
        tail.close()
        tail.fill()
        bubble.dot.setFill()
        for d in 0..<3 {
            NSBezierPath(ovalIn: mrect(bubble.x + 9 + CGFloat(d) * 9, bubble.y + 10.5, 6, 6)).fill()
        }
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
