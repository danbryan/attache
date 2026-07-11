import AppKit

/// Draws the Attaché app icon: the Bubbles mascot (design/attache-logo.svg,
/// locked 2026-07-11) on a vivid macOS-blue tile with faint broadcast rings.
/// This is a fixed brand asset, identical to the baked bundle icon
/// (scripts/generate-app-icon.swift), so the running app's Dock icon matches
/// Finder regardless of the in-app theme.
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
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
        }
        // The mascot uses the SVG's 240-unit, y-down design box, scaled 1.5x
        // and centered on the 512 tile. `m` flips into AppKit's y-up space.
        let k: CGFloat = 1.5
        let ox: CGFloat = (512 - 240 * k) / 2
        let oy: CGFloat = (512 - 240 * k) / 2
        func m(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: (ox + x * k) * s, y: (512 - oy - y * k) * s)
        }
        func mrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: (ox + x * k) * s, y: (512 - oy - (y + h) * k) * s, width: w * k * s, height: h * k * s)
        }
        // Quadratic-to-cubic control points for NSBezierPath (cubic only).
        func quad(_ path: NSBezierPath, from p0: NSPoint, control cp: NSPoint, to p2: NSPoint) {
            let c1 = NSPoint(x: p0.x + 2.0 / 3.0 * (cp.x - p0.x), y: p0.y + 2.0 / 3.0 * (cp.y - p0.y))
            let c2 = NSPoint(x: p2.x + 2.0 / 3.0 * (cp.x - p2.x), y: p2.y + 2.0 / 3.0 * (cp.y - p2.y))
            path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
        }

        // macOS-blue brand palette (mirrors generate-app-icon.swift exactly).
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

        // Voice arcs above the head. AppKit is y-up, so the SVG's upward arcs
        // sweep 48°..132° counterclockwise around the shared center.
        let arcSpecs: [(radius: CGFloat, alpha: CGFloat)] = [(40, 1.0), (66, 0.62), (90, 0.34)]
        for spec in arcSpecs {
            white.withAlphaComponent(spec.alpha).setStroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: m(120, 89), radius: spec.radius * k * s, startAngle: 48, endAngle: 132)
            arc.lineWidth = 9 * k * s
            arc.lineCapStyle = .round
            arc.stroke()
        }

        // Limbs.
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

        // Head and face.
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

        // The three agent bubbles. The middle one goes cream (its SVG blue
        // would vanish on the blue tile); dots invert to stay visible.
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
}
