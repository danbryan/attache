import SwiftUI

/// The Attaché mascot (the "Bubbles" mark, `design/attache-logo.svg`, locked
/// 2026-07-11): a hub speaking above its head, three typing agents at hand
/// and foot. Drawn from the same 240-unit geometry as the canonical SVG so
/// the in-app mark, the Dock icon, and the promo video never drift.
///
/// `monochrome` renders the whole mark in a single color (solid silhouette,
/// no face) for template contexts like the menu bar.
struct AttacheMascotMark: View {
    var arcColor: Color = Color(red: 10 / 255, green: 132 / 255, blue: 1)
    var bodyColor: Color = Color(red: 242 / 255, green: 242 / 255, blue: 245 / 255)
    var monochrome: Color?
    var glow: Color = .clear
    var glowStrength: Double = 0

    // Shared with BubblesPetFigure so the animated pet and the static mark
    // can never drift apart on brand colors.
    static let headColor = Color(red: 1, green: 246 / 255, blue: 228 / 255)
    static let faceColor = Color(red: 16 / 255, green: 36 / 255, blue: 62 / 255)
    static let cheekColor = Color(red: 1, green: 157 / 255, blue: 161 / 255)
    static let bubbleColors: [Color] = [
        Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255),
        Color(red: 10 / 255, green: 132 / 255, blue: 1),
        Color(red: 16 / 255, green: 163 / 255, blue: 127 / 255),
    ]

    var body: some View {
        Canvas { context, size in
            // The design box is 240 units, but the outermost voice arc's
            // stroke crests ~6 units above y=0 (radius 90 from center y=89),
            // so the drawable box is padded to 252 to keep it from clipping.
            let s = min(size.width, size.height) / 252
            let ox = (size.width - 252 * s) / 2 + 6 * s
            let oy = (size.height - 252 * s) / 2 + 12 * s
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }

            let arcTint = monochrome ?? arcColor
            let bodyTint = monochrome ?? bodyColor
            let headTint = monochrome ?? Self.headColor

            // Voice arcs above the head (shared center, matching the SVG's
            // three chords). SwiftUI angles are y-down: -90° is straight up.
            let arcSpecs: [(radius: CGFloat, width: CGFloat, opacity: Double)] = [
                (40, 9, 1.0), (66, 9, 0.62), (90, 9, 0.30),
            ]
            for spec in arcSpecs {
                var arc = Path()
                arc.addArc(
                    center: p(120, 89),
                    radius: spec.radius * s,
                    startAngle: .degrees(-132),
                    endAngle: .degrees(-48),
                    clockwise: false
                )
                context.stroke(
                    arc,
                    with: .color(arcTint.opacity(monochrome == nil ? spec.opacity : max(0.45, spec.opacity))),
                    style: StrokeStyle(lineWidth: spec.width * s, lineCap: .round)
                )
            }

            // Limbs, ending short of the bubbles so the agents read as
            // separate things it holds, not parts of the body.
            var limbs = Path()
            limbs.move(to: p(102, 140))
            limbs.addCurve(to: p(70, 160), control1: p(90, 150), control2: p(80, 155))
            limbs.move(to: p(120, 145))
            limbs.addLine(to: p(120, 170))
            limbs.move(to: p(138, 140))
            limbs.addCurve(to: p(170, 160), control1: p(150, 150), control2: p(160, 155))
            context.stroke(limbs, with: .color(bodyTint), style: StrokeStyle(lineWidth: 7 * s, lineCap: .round))

            // Head.
            let head = Path(ellipseIn: CGRect(x: ox + 87 * s, y: oy + 79 * s, width: 66 * s, height: 66 * s))
            context.fill(head, with: .color(headTint))

            // Face (skipped in monochrome; a template mark needs a solid
            // silhouette, not a knocked-out face).
            if monochrome == nil {
                var eyes = Path()
                eyes.move(to: p(97, 107))
                eyes.addQuadCurve(to: p(113, 107), control: p(105, 97))
                eyes.move(to: p(127, 107))
                eyes.addQuadCurve(to: p(143, 107), control: p(135, 97))
                context.stroke(eyes, with: .color(Self.faceColor), style: StrokeStyle(lineWidth: 5 * s, lineCap: .round))

                for cx in [95.0, 145.0] {
                    let cheek = Path(ellipseIn: CGRect(x: ox + (cx - 6) * s, y: oy + 113 * s, width: 12 * s, height: 12 * s))
                    context.fill(cheek, with: .color(Self.cheekColor.opacity(0.6)))
                }

                var mouth = Path()
                mouth.move(to: p(108, 119))
                mouth.addCurve(to: p(132, 119), control1: p(111, 134), control2: p(129, 134))
                mouth.closeSubpath()
                context.fill(mouth, with: .color(Self.faceColor))
            }

            // The three agent bubbles, typing.
            let bubbles: [(x: CGFloat, y: CGFloat, tail: [CGPoint])] = [
                (36, 168, [p(62, 168), p(68, 160), p(54, 168)]),
                (100, 182, [p(120, 182), p(120, 173), p(111, 182)]),
                (164, 168, [p(178, 168), p(172, 160), p(186, 168)]),
            ]
            for (index, bubble) in bubbles.enumerated() {
                let tint = monochrome ?? Self.bubbleColors[index]
                let body = Path(
                    roundedRect: CGRect(x: ox + bubble.x * s, y: oy + bubble.y * s, width: 40 * s, height: 27 * s),
                    cornerRadius: 12 * s
                )
                context.fill(body, with: .color(tint))
                var tail = Path()
                tail.move(to: bubble.tail[0])
                tail.addLine(to: bubble.tail[1])
                tail.addLine(to: bubble.tail[2])
                tail.closeSubpath()
                context.fill(tail, with: .color(tint))
                if monochrome == nil {
                    for d in 0..<3 {
                        let dot = Path(ellipseIn: CGRect(
                            x: ox + (bubble.x + 9 + CGFloat(d) * 9) * s,
                            y: oy + (bubble.y + 10.5) * s,
                            width: 6 * s, height: 6 * s
                        ))
                        context.fill(dot, with: .color(Self.headColor))
                    }
                }
            }
        }
        .shadow(color: glow.opacity(0.55 * glowStrength), radius: 18)
        .shadow(color: glow.opacity(0.30 * glowStrength), radius: 42)
    }
}
