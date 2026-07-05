import AppKit

/// Draws the Attaché brand mark: a vivid macOS-blue tile, white broadcast
/// rings, a white audio equalizer, and an "A". This is a fixed brand asset,
/// identical to the baked bundle icon (scripts/generate-app-icon.swift), so the
/// running app's Dock icon matches Finder regardless of the in-app theme.
enum AttacheAppIcon {
    static func image(side: CGFloat = 512, dark: Bool = true, theme: CompanionTheme = .macOS) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        draw(side: side)
        image.unlockFocus()
        return image
    }

    static func draw(side: CGFloat, dark: Bool = true, theme: CompanionTheme = .macOS) {
        let s = side / 512
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: y * s) }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
        }

        // macOS-blue brand palette (mirrors generate-app-icon.swift exactly).
        let tileTop = NSColor(srgbRed: 0.180, green: 0.565, blue: 1.000, alpha: 1)
        let tileMid = NSColor(srgbRed: 0.043, green: 0.420, blue: 0.902, alpha: 1)
        let tileDeep = NSColor(srgbRed: 0.024, green: 0.235, blue: 0.620, alpha: 1)
        let ringColor = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.16)
        let barLo = NSColor(srgbRed: 0.720, green: 0.840, blue: 1.000, alpha: 1)
        let barHi = NSColor(srgbRed: 1.000, green: 1.000, blue: 1.000, alpha: 1)
        let letterColor = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1)

        let tile = NSBezierPath(roundedRect: rect(28, 28, 456, 456), xRadius: 112 * s, yRadius: 112 * s)
        NSGradient(colors: [tileTop, tileMid, tileDeep])?.draw(in: tile, angle: 305)

        NSGraphicsContext.saveGraphicsState()
        tile.addClip()

        ringColor.setStroke()
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
            let bar = NSBezierPath(
                roundedRect: rect(CGFloat(96 + index * 30), 80, 20, height),
                xRadius: 10 * s,
                yRadius: 10 * s
            )
            bar.fill()
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
}
