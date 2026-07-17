import SwiftUI

/// The Attaché mark: the robot broadcasting under its voice arcs. Drawn from the same
/// 240-unit robot geometry as the character's head and the app icon, so the in-app
/// mark, the Dock icon, and the promo video never drift.
///
/// `monochrome` renders a solid robot silhouette (no screen detail) for
/// template contexts like the menu bar.
struct AttacheMascotMark: View {
    var arcColor: Color = Color(red: 10 / 255, green: 132 / 255, blue: 1)
    var bodyColor: Color = Color(red: 242 / 255, green: 242 / 255, blue: 245 / 255)
    var monochrome: Color?
    var glow: Color = .clear
    var glowStrength: Double = 0
    /// Menu-bar variant: drop the voice arcs and antenna and frame tightly on
    /// the head so it fills a small status-bar glyph instead of shrinking to a
    /// speck under its arcs. Default false keeps the canonical mark (arcs and
    /// all) byte-identical, so the geometry lock against the character rig
    /// (INF-269) is unaffected.
    var headOnly: Bool = false

    // Shared with AttacheCharacterFigure so the animated character and the static mark
    // can never drift apart on brand colors. `agentColors` are the fleet
    // hues: Claude rust, Codex blue, and other green.
    static let headColor = Color(red: 1, green: 246 / 255, blue: 228 / 255)
    static let faceColor = Color(red: 16 / 255, green: 36 / 255, blue: 62 / 255)
    static let cheekColor = Color(red: 1, green: 157 / 255, blue: 161 / 255)
    static let steelColor = Color(red: 199 / 255, green: 208 / 255, blue: 220 / 255)
    static let ledColor = Color(red: 102 / 255, green: 227 / 255, blue: 1)
    static let agentColors: [Color] = [
        Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255),
        Color(red: 10 / 255, green: 132 / 255, blue: 1),
        Color(red: 16 / 255, green: 163 / 255, blue: 127 / 255),
    ]

    var body: some View {
        Canvas { context, size in
            // Canonical mark frames a 252-unit box (head + crowning arcs). The
            // menu-bar variant frames a 76-unit square centered on the head so
            // the face fills the glyph.
            let box: CGFloat = headOnly ? 76 : 252
            let s = min(size.width, size.height) / box
            let ox: CGFloat = headOnly
                ? (size.width - box * s) / 2 - 82 * s
                : (size.width - 252 * s) / 2 + 6 * s
            let oy: CGFloat = headOnly
                ? (size.height - box * s) / 2 - 74 * s
                : (size.height - 252 * s) / 2 + 12 * s
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
            func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
                Path(roundedRect: CGRect(x: p(x, y).x, y: p(x, y).y, width: w * s, height: h * s), cornerRadius: r * s)
            }

            let arcTint = monochrome ?? arcColor
            let steelTint = monochrome ?? Self.steelColor
            let coral = monochrome ?? Self.cheekColor

            // Menu-bar glyph: a robot-face silhouette with the eyes and a
            // voice-bar mouth punched out (even-odd), so it reads as a robot
            // even as a small tinted template. No arcs, no antenna.
            if headOnly {
                var face = rrect(88, 82, 64, 60, 14)
                face.addPath(rrect(99, 100.5, 14, 11, 2.5))
                face.addPath(rrect(127, 100.5, 14, 11, 2.5))
                let barHeights: [CGFloat] = [6.5, 11, 8.5, 13, 7]
                for (index, height) in barHeights.enumerated() {
                    let x = 108 + CGFloat(index) * 6
                    face.addPath(rrect(x - 1.8, 133 - height / 2, 3.6, height, 1.8))
                }
                context.fill(face, with: .color(monochrome ?? Self.steelColor), style: FillStyle(eoFill: true))
                return
            }

            // Voice arcs above the head. SwiftUI angles are y-down.
            let arcSpecs: [(radius: CGFloat, width: CGFloat, opacity: Double)] = [
                (40, 9, 1.0), (66, 9, 0.62), (90, 9, 0.30),
            ]
            for spec in arcSpecs {
                var arc = Path()
                arc.addArc(center: p(120, 89), radius: spec.radius * s,
                           startAngle: .degrees(-132), endAngle: .degrees(-48), clockwise: false)
                context.stroke(arc, with: .color(arcTint.opacity(monochrome == nil ? spec.opacity : max(0.45, spec.opacity))),
                               style: StrokeStyle(lineWidth: spec.width * s, lineCap: .round))
            }

            // Antenna and bulb.
            var antenna = Path()
            antenna.move(to: p(120, 82))
            antenna.addLine(to: p(120, 73))
            context.stroke(antenna, with: .color(steelTint), style: StrokeStyle(lineWidth: 3 * s, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: p(116.5, 66).x, y: p(116.5, 66).y, width: 7 * s, height: 7 * s)), with: .color(coral))

            // Steel plate head.
            context.fill(rrect(88, 82, 64, 60, 14), with: .color(steelTint))

            if monochrome == nil {
                // Navy screen, LED eyes, bolts, resting mouth.
                context.fill(rrect(94, 92, 52, 34, 8), with: .color(Self.faceColor))
                context.fill(rrect(99, 100.5, 14, 11, 2.5), with: .color(Self.ledColor))
                context.fill(rrect(127, 100.5, 14, 11, 2.5), with: .color(Self.ledColor))
                context.fill(Path(ellipseIn: CGRect(x: p(90.5, 117).x, y: p(90.5, 117).y, width: 4 * s, height: 4 * s)), with: .color(Self.cheekColor))
                context.fill(Path(ellipseIn: CGRect(x: p(141.5, 117).x, y: p(141.5, 117).y, width: 4 * s, height: 4 * s)), with: .color(Self.cheekColor))
                context.fill(rrect(109.2, 131, 21.6, 3.5, 1.75), with: .color(Self.faceColor))
            }
        }
        .shadow(color: glow.opacity(0.55 * glowStrength), radius: 18)
        .shadow(color: glow.opacity(0.30 * glowStrength), radius: 42)
    }
}
