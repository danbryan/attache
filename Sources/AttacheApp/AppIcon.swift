import AppKit

/// Draws the Attaché app icon: Volt, the default attache character
/// (INF-286, original in-house artwork), on the vivid macOS-blue tile with
/// faint broadcast rings and the voice-arc crown. This is a fixed brand
/// asset, identical to the baked bundle icon
/// (scripts/generate-app-icon.swift), so the running app's Dock icon matches
/// Finder regardless of the in-app theme or the user's chosen character.
enum AttacheAppIcon {
    static func image(side: CGFloat = 512, dark: Bool = true, theme: AttacheTheme = .macOS) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        draw(side: side)
        image.unlockFocus()
        return image
    }

    static func draw(side: CGFloat, dark: Bool = true, theme: AttacheTheme = .macOS) {
        let s = side / 512
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
        }
        // Volt uses the character renderer's 240-unit, y-down design coordinates,
        // scaled up and centered on the 512 tile. `m` flips into AppKit's
        // y-up space.
        // The face is scaled up to fill the tile (INF: 2026-07-17 icon refresh);
        // the head, not a plaque, is the icon. Centered on the plate's midpoint.
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
        // used to.
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
}
