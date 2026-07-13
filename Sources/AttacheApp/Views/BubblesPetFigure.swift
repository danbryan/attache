import SwiftUI

/// One agent bubble's pose within the figure.
struct BubblesBubblePose: Equatable {
    /// Units the bubble rises off its resting spot (negative droops).
    var lift: CGFloat = 0
    /// Small horizontal jitter, for shell shakes and wobbles.
    var jitter: CGFloat = 0
    /// Rotation in degrees around the bubble's center.
    var tilt: Double = 0
    /// 1 lit, dimmer marks the bubble inactive; hue never changes.
    var brightness: Double = 1
    /// Typing-dot sweep phase in 0-1; nil freezes the dots solid.
    var dotPhase: Double?
    /// 0-1: dots leave the bubble and orbit it (web tool flavor).
    var orbit: Double = 0
    /// Confetti burst progress 0-1 (celebrate one-shot).
    var pop: Double = 0
}

/// A complete pose over the locked Bubbles geometry: every field is a small
/// deformation of `design/attache-logo.svg`'s anatomy, so `.neutral` renders
/// the canonical mark exactly (verified pixel-for-pixel by
/// `Attache --render-poses`). The animation spec that motivates each
/// parameter is `design/pet-animation-spec.md`.
struct BubblesPose: Equatable {
    /// Breathing cycle contribution 0-1 (scales the figure 1.000-1.015).
    var breathe: Double = 0
    /// Head and face rotation in degrees (positive tilts right).
    var headTilt: Double = 0
    /// 1 = the mark's happy arcs, 0 = closed flat lines.
    var eyeOpenness: Double = 1
    /// Eye and mouth glance offset in design units (clamped to about 3).
    var gaze: CGSize = .zero
    /// Worry brows fade in and the eye arcs flatten.
    var browWorry: Double = 0
    /// Eyes crossfade to dizzy X strokes.
    var dizzy: Double = 0
    /// Smile morphs toward a round open mouth; speech maps audio level here.
    var mouthOpen: Double = 0
    /// Mouth width and curve depth; 1 is the canonical smile.
    var smile: Double = 1
    /// Cheek opacity; the mark's resting value is 0.6.
    var cheekGlow: Double = 0.6
    /// Vertical body offset in units (celebrate hop).
    var hop: CGFloat = 0
    /// Squash-and-stretch: +1 landing squash, -1 rising stretch.
    var squash: Double = 0
    /// Whole-figure rock in degrees while speaking.
    var sway: Double = 0
    /// Arc opacity multiplier over the mark's 1.0/0.62/0.30.
    var arcGlow: Double = 1
    /// Arc radius ripple amount: positive outward, negative inward.
    var arcRipple: Double = 0
    /// Phase for the arc ripple wave.
    var arcPhase: Double = 0
    /// Left (Claude, rust), center (everything else, blue), right (Codex,
    /// green); see the spec's anatomy notes for why the order is load-bearing.
    var bubbles: [BubblesBubblePose] = [.init(), .init(), .init()]

    static let neutral = BubblesPose()

    /// Clamps every field to its sane range before drawing, so a misbehaving
    /// caller (a diverged spring, a bad simulator value) can distort a frame
    /// but never draw eyes across the whole canvas or rotate the head off its
    /// neck. Neutral values pass through untouched, keeping the mark
    /// pixel-identity check honest.
    func sanitized() -> BubblesPose {
        func limit(_ value: Double, _ range: ClosedRange<Double>) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : range.lowerBound
        }
        var pose = self
        pose.breathe = limit(pose.breathe, 0...1)
        pose.headTilt = limit(pose.headTilt, -30...30)
        pose.eyeOpenness = limit(pose.eyeOpenness, -0.2...1.2)
        pose.gaze = CGSize(
            width: CGFloat(limit(Double(pose.gaze.width), -3...3)),
            height: CGFloat(limit(Double(pose.gaze.height), -3...3))
        )
        pose.browWorry = limit(pose.browWorry, 0...1)
        pose.dizzy = limit(pose.dizzy, 0...1)
        pose.mouthOpen = limit(pose.mouthOpen, 0...1)
        pose.smile = limit(pose.smile, 0...1.2)
        pose.cheekGlow = limit(pose.cheekGlow, 0...1)
        pose.hop = CGFloat(limit(Double(pose.hop), -12...26))
        pose.squash = limit(pose.squash, -1...1)
        pose.sway = limit(pose.sway, -10...10)
        pose.arcGlow = limit(pose.arcGlow, 0...1)
        pose.arcRipple = limit(pose.arcRipple, -1.5...1.5)
        pose.arcPhase = pose.arcPhase.isFinite ? pose.arcPhase : 0
        pose.bubbles = pose.bubbles.map { bubble in
            var next = bubble
            next.lift = CGFloat(limit(Double(bubble.lift), -12...26))
            next.jitter = CGFloat(limit(Double(bubble.jitter), -8...8))
            next.tilt = limit(bubble.tilt, -20...20)
            next.brightness = limit(bubble.brightness, 0...1)
            next.dotPhase = bubble.dotPhase.map { limit($0, 0...1) }
            next.orbit = limit(bubble.orbit, 0...1)
            next.pop = limit(bubble.pop, 0...1)
            return next
        }
        return pose
    }
}

/// Draws one `BubblesPose` from the same 240-unit geometry as
/// `AttacheMascotMark` (design box padded to 252 so the outer voice arc never
/// clips). `headroom` adds design units above the box so hop poses have room;
/// with `headroom == 0` and `.neutral` the output is the canonical mark.
/// This view is a pure function of its pose: animation lives in the caller
/// (INF-270's pet renderer springs pose fields; this file never reads state).
/// Which anatomy the figure draws (INF-280). `.full` is the canonical mark:
/// arcs, limbs, head, and the three typing bubbles; it stays pixel-locked to
/// `AttacheMascotMark` and serves the logo, icon, and brand assets. `.head`
/// is the live companion: face and compact arcs only, with the session ring
/// drawn around it, so a bring-your-own pet only ever replaces the head.
enum BubblesPetAnatomy {
    case full
    case head
}

struct BubblesPetFigure: View {
    var pose: BubblesPose = .neutral
    var arcColor: Color = Color(red: 10 / 255, green: 132 / 255, blue: 1)
    var bodyColor: Color = Color(red: 242 / 255, green: 242 / 255, blue: 245 / 255)
    var headroom: CGFloat = 0
    var anatomy: BubblesPetAnatomy = .full
    /// Fleet motes (INF-275), pre-positioned in design units by the motor.
    var fleetMotes: [BubblesFleetMote] = []
    /// Theme signature color for the focused session's mote.
    var accentColor: Color = Color(red: 10 / 255, green: 132 / 255, blue: 1)

    static let blockedMoteColor = Color(red: 1.0, green: 0.69, blue: 0.125)
    /// How far the head layer drops in `.head` anatomy so the composition
    /// (compact arcs, head, ring) centers in the design box.
    static let headAnatomyDrop: CGFloat = 26

    /// The design-to-view mapping every renderer of the mark shares, exposed
    /// so hover and click hit-testing agree exactly with the drawing.
    static func designTransform(size: CGSize, headroom: CGFloat) -> (s: CGFloat, ox: CGFloat, oy: CGFloat) {
        let boxHeight = 252 + headroom
        let s = min(size.width / 252, size.height / boxHeight)
        let ox = (size.width - 252 * s) / 2 + 6 * s
        let oy = (size.height - boxHeight * s) / 2 + (12 + headroom) * s
        return (s, ox, oy)
    }

    var body: some View {
        Canvas { context, size in
            let pose = self.pose.sanitized()
            let (s, ox, oy) = Self.designTransform(size: size, headroom: headroom)
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }

            var figure = context
            let anchor = anatomy == .head ? p(120, 171) : p(120, 209)
            figure.translateBy(x: anchor.x, y: anchor.y)
            figure.rotate(by: .degrees(pose.sway))
            let breatheScale = 1 + 0.015 * pose.breathe
            let squashUp = max(0, pose.squash)
            let stretchUp = max(0, -pose.squash)
            figure.scaleBy(
                x: breatheScale * (1 + 0.05 * squashUp - 0.03 * stretchUp),
                y: breatheScale * (1 - 0.06 * squashUp + 0.05 * stretchUp)
            )
            figure.translateBy(x: -anchor.x, y: -anchor.y - pose.hop * s)

            switch anatomy {
            case .full:
                drawArcs(in: figure, pose: pose, p: p, s: s)
                drawLimbs(in: figure, pose: pose, p: p, s: s)
                drawHead(in: figure, pose: pose, p: p, s: s)
                drawFleet(in: figure, p: p, s: s, behind: true)
                drawBubbles(in: figure, pose: pose, p: p, s: s)
                drawFleet(in: figure, p: p, s: s, behind: false)
            case .head:
                // The ring's far half passes behind the pet; the mote layer
                // stays untranslated so its design coordinates match the
                // choreography's ring (already centered on the dropped head).
                drawFleet(in: figure, p: p, s: s, behind: true)
                var headLayer = figure
                headLayer.translateBy(x: 0, y: Self.headAnatomyDrop * s)
                drawArcs(in: headLayer, pose: pose, p: p, s: s)
                drawHead(in: headLayer, pose: pose, p: p, s: s)
                drawHeadConfetti(in: headLayer, pose: pose, p: p, s: s)
                drawFleet(in: figure, p: p, s: s, behind: false)
            }
        }
    }

    /// Harness hues (INF-280 research): Claude keeps the mark's rust, which
    /// IS the official Claude brand color #D97757. Codex takes the mark's
    /// blue; its official mark is monochrome, so there is no brand color to
    /// borrow. Green stays reserved for a future open-source harness.
    private func moteColor(_ fill: BubblesFleetMote.Fill) -> Color {
        switch fill {
        case .agent(.claude):
            return AttacheMascotMark.bubbleColors[0]
        case .agent(.codex):
            return AttacheMascotMark.bubbleColors[1]
        case .agent(.none):
            return AttacheMascotMark.bubbleColors[2]
        case .blocked:
            return Self.blockedMoteColor
        case .focused:
            return accentColor
        }
    }

    private func drawFleet(in context: GraphicsContext, p: (CGFloat, CGFloat) -> CGPoint, s: CGFloat, behind: Bool) {
        for mote in fleetMotes where mote.behind == behind {
            let center = p(mote.position.x, mote.position.y)
            let color = moteColor(mote.fill)
            for ripple in mote.ripples {
                let radius = (mote.radius + 3 + 13 * ripple) * s
                var ring = Path()
                ring.addEllipse(in: CGRect(
                    x: center.x - radius, y: center.y - radius,
                    width: radius * 2, height: radius * 2
                ))
                context.stroke(
                    ring,
                    with: .color(color.opacity((1 - ripple) * 0.55 * mote.opacity)),
                    style: StrokeStyle(lineWidth: 1.3 * s)
                )
            }
            let r = mote.radius * s
            let body = Path(ellipseIn: CGRect(
                x: center.x - r, y: center.y - r, width: r * 2, height: r * 2
            ))
            context.fill(body, with: .color(color.opacity(mote.opacity)))
            if mote.ring {
                let ringRadius = r + 2.6 * s
                var halo = Path()
                halo.addEllipse(in: CGRect(
                    x: center.x - ringRadius, y: center.y - ringRadius,
                    width: ringRadius * 2, height: ringRadius * 2
                ))
                context.stroke(
                    halo,
                    with: .color(Color.white.opacity(0.9 * mote.opacity)),
                    style: StrokeStyle(lineWidth: 1.2 * s)
                )
            }
            if let count = mote.count {
                let text = Text("\(min(count, 999))")
                    .font(.system(size: 8.5 * s, weight: .bold, design: .rounded))
                    .foregroundColor(Color(red: 0.02, green: 0.04, blue: 0.09))
                context.draw(context.resolve(text), at: center)
            }
            switch mote.glyph {
            case .none:
                break
            case .question:
                let glyph = Text("?")
                    .font(.system(size: mote.radius * 1.5 * s, weight: .heavy, design: .rounded))
                    .foregroundColor(Color(red: 0.02, green: 0.04, blue: 0.09).opacity(mote.opacity))
                context.draw(context.resolve(glyph), at: center)
            case .check:
                var check = Path()
                let u = mote.radius * s
                check.move(to: CGPoint(x: center.x - u * 0.5, y: center.y + u * 0.05))
                check.addLine(to: CGPoint(x: center.x - u * 0.12, y: center.y + u * 0.42))
                check.addLine(to: CGPoint(x: center.x + u * 0.55, y: center.y - u * 0.38))
                context.stroke(
                    check,
                    with: .color(Color.white.opacity(0.95 * mote.opacity)),
                    style: StrokeStyle(lineWidth: max(1.4, u * 0.24), lineCap: .round, lineJoin: .round)
                )
            }
        }
    }

    /// Celebrate confetti for `.head` anatomy: with no bubbles to burst
    /// from, the pop rings the head instead. Driven by the same
    /// `pose.bubbles[i].pop` one-shots the full anatomy uses.
    private func drawHeadConfetti(in context: GraphicsContext, pose: BubblesPose, p: (CGFloat, CGFloat) -> CGPoint, s: CGFloat) {
        let progress = pose.bubbles.map(\.pop).max() ?? 0
        guard progress > 0.01 else { return }
        for d in 0..<10 {
            let angle = -Double.pi / 2 + Double(d) * (2 * .pi / 10)
            let radius = (40 + 34 * progress) * s
            let center = p(120, 112)
            let dotCenter = CGPoint(
                x: center.x + CGFloat(cos(angle)) * radius,
                y: center.y + CGFloat(sin(angle)) * radius * 0.85
            )
            let size = 5 * (1 - progress * 0.5) * s
            let confetti = Path(ellipseIn: CGRect(
                x: dotCenter.x - size / 2, y: dotCenter.y - size / 2, width: size, height: size
            ))
            context.fill(
                confetti,
                with: .color(AttacheMascotMark.bubbleColors[d % 3].opacity(1 - progress))
            )
        }
    }

    private func drawArcs(in context: GraphicsContext, pose: BubblesPose, p: (CGFloat, CGFloat) -> CGPoint, s: CGFloat) {
        // The head anatomy tightens the voice arcs (INF-280 feedback: the
        // full-size arcs claim too much of the surface once the ring is the
        // main show); the mark keeps its canonical 40/66/90.
        let arcSpecs: [(radius: CGFloat, width: CGFloat, opacity: Double)] = anatomy == .head
            ? [(34, 8, 1.0), (46, 8, 0.62), (58, 8, 0.30)]
            : [(40, 9, 1.0), (66, 9, 0.62), (90, 9, 0.30)]
        for (index, spec) in arcSpecs.enumerated() {
            let ripple = CGFloat(4 * pose.arcRipple * sin(pose.arcPhase - Double(index) * 1.1))
            var arc = Path()
            arc.addArc(
                center: p(120, 89),
                radius: (spec.radius + ripple) * s,
                startAngle: .degrees(-132),
                endAngle: .degrees(-48),
                clockwise: false
            )
            context.stroke(
                arc,
                with: .color(arcColor.opacity(spec.opacity * pose.arcGlow)),
                style: StrokeStyle(lineWidth: spec.width * s, lineCap: .round)
            )
        }
    }

    private func drawLimbs(in context: GraphicsContext, pose: BubblesPose, p: (CGFloat, CGFloat) -> CGPoint, s: CGFloat) {
        var limbs = Path()
        limbs.move(to: p(102, 140))
        limbs.addCurve(to: p(70, 160), control1: p(90, 150), control2: p(80, 155))
        limbs.move(to: p(120, 145))
        limbs.addLine(to: p(120, 170))
        limbs.move(to: p(138, 140))
        limbs.addCurve(to: p(170, 160), control1: p(150, 150), control2: p(160, 155))
        context.stroke(limbs, with: .color(bodyColor), style: StrokeStyle(lineWidth: 7 * s, lineCap: .round))
    }

    private func drawHead(in context: GraphicsContext, pose: BubblesPose, p: (CGFloat, CGFloat) -> CGPoint, s: CGFloat) {
        var head = context
        let pivot = p(120, 112)
        head.translateBy(x: pivot.x, y: pivot.y)
        head.rotate(by: .degrees(pose.headTilt))
        head.translateBy(x: -pivot.x, y: -pivot.y)

        let skull = Path(ellipseIn: CGRect(
            x: p(87, 79).x, y: p(87, 79).y, width: 66 * s, height: 66 * s
        ))
        head.fill(skull, with: .color(AttacheMascotMark.headColor))

        var face = head
        let gx = max(-3, min(3, pose.gaze.width))
        let gy = max(-3, min(3, pose.gaze.height))
        face.translateBy(x: gx * s, y: gy * s)

        let openness = pose.eyeOpenness * (1 - 0.4 * pose.browWorry)
        let eyeAlpha = 1 - pose.dizzy
        if eyeAlpha > 0.01 {
            var eyes = Path()
            // Fully open is the mark's happy arc (control 10 above the lash
            // line); fully closed curves gently DOWN (4 below) so sleep reads
            // peaceful instead of deadpan.
            let controlY = 111 - 14 * openness
            eyes.move(to: p(97, 107))
            eyes.addQuadCurve(to: p(113, 107), control: p(105, controlY))
            eyes.move(to: p(127, 107))
            eyes.addQuadCurve(to: p(143, 107), control: p(135, controlY))
            face.stroke(
                eyes,
                with: .color(AttacheMascotMark.faceColor.opacity(eyeAlpha)),
                style: StrokeStyle(lineWidth: 5 * s, lineCap: .round)
            )
        }
        if pose.dizzy > 0.01 {
            var crosses = Path()
            for centerX in [105.0, 135.0] {
                crosses.move(to: p(centerX - 6, 100))
                crosses.addLine(to: p(centerX + 6, 111))
                crosses.move(to: p(centerX + 6, 100))
                crosses.addLine(to: p(centerX - 6, 111))
            }
            face.stroke(
                crosses,
                with: .color(AttacheMascotMark.faceColor.opacity(pose.dizzy)),
                style: StrokeStyle(lineWidth: 4 * s, lineCap: .round)
            )
        }
        if pose.browWorry > 0.01 {
            var brows = Path()
            brows.move(to: p(95, 101))
            brows.addLine(to: p(111, 96))
            brows.move(to: p(129, 96))
            brows.addLine(to: p(145, 101))
            face.stroke(
                brows,
                with: .color(AttacheMascotMark.faceColor.opacity(pose.browWorry)),
                style: StrokeStyle(lineWidth: 4 * s, lineCap: .round)
            )
        }

        for cx in [95.0, 145.0] {
            let cheek = Path(ellipseIn: CGRect(
                x: p(cx - 6, 113).x, y: p(cx - 6, 113).y, width: 12 * s, height: 12 * s
            ))
            head.fill(cheek, with: .color(AttacheMascotMark.cheekColor.opacity(pose.cheekGlow)))
        }

        // The two mouth shapes swap at a hard threshold instead of
        // crossfading: overlapped translucent fills read as a gray plate, and
        // in motion the flip doubles as the mouth closing between words. At
        // `mouthOpen == 0` this is the mark's exact smile path.
        if pose.mouthOpen < 0.15 {
            let halfWidth = 12 * pose.smile
            let depth = 15 * pose.smile
            var mouth = Path()
            mouth.move(to: p(120 - halfWidth, 119))
            mouth.addCurve(
                to: p(120 + halfWidth, 119),
                control1: p(120 - halfWidth * 0.75, 119 + depth),
                control2: p(120 + halfWidth * 0.75, 119 + depth)
            )
            mouth.closeSubpath()
            face.fill(mouth, with: .color(AttacheMascotMark.faceColor))
        } else {
            let rx = 9 * (0.5 + 0.5 * pose.mouthOpen)
            let ry = 3 + 11 * pose.mouthOpen
            let center = p(120, 122 + 4 * pose.mouthOpen)
            let open = Path(ellipseIn: CGRect(
                x: center.x - rx * s, y: center.y - ry * s, width: rx * 2 * s, height: ry * 2 * s
            ))
            face.fill(open, with: .color(AttacheMascotMark.faceColor))
        }
    }

    private func drawBubbles(in context: GraphicsContext, pose: BubblesPose, p: (CGFloat, CGFloat) -> CGPoint, s: CGFloat) {
        let bubbles: [(x: CGFloat, y: CGFloat, tail: [(CGFloat, CGFloat)])] = [
            (36, 168, [(62, 168), (68, 160), (54, 168)]),
            (100, 182, [(120, 182), (120, 173), (111, 182)]),
            (164, 168, [(178, 168), (172, 160), (186, 168)]),
        ]
        for (index, bubble) in bubbles.enumerated() {
            let bubblePose = index < pose.bubbles.count ? pose.bubbles[index] : BubblesBubblePose()
            let tint = AttacheMascotMark.bubbleColors[index].opacity(bubblePose.brightness)
            let center = p(bubble.x + 20, bubble.y + 13.5)

            var ctx = context
            ctx.translateBy(x: bubblePose.jitter * s, y: -bubblePose.lift * s)
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: .degrees(bubblePose.tilt))
            ctx.translateBy(x: -center.x, y: -center.y)

            let body = Path(
                roundedRect: CGRect(x: p(bubble.x, bubble.y).x, y: p(bubble.x, bubble.y).y, width: 40 * s, height: 27 * s),
                cornerRadius: 12 * s
            )
            ctx.fill(body, with: .color(tint))
            var tail = Path()
            tail.move(to: p(bubble.tail[0].0, bubble.tail[0].1))
            tail.addLine(to: p(bubble.tail[1].0, bubble.tail[1].1))
            tail.addLine(to: p(bubble.tail[2].0, bubble.tail[2].1))
            tail.closeSubpath()
            ctx.fill(tail, with: .color(tint))

            if bubblePose.orbit > 0.01 {
                for d in 0..<3 {
                    let angle = (bubblePose.dotPhase ?? 0) * 2 * .pi + Double(d) * 2 * .pi / 3
                    let dotCenter = CGPoint(
                        x: center.x + CGFloat(cos(angle)) * 26 * s * bubblePose.orbit,
                        y: center.y + CGFloat(sin(angle)) * 15 * s * bubblePose.orbit
                    )
                    let dot = Path(ellipseIn: CGRect(
                        x: dotCenter.x - 3 * s, y: dotCenter.y - 3 * s, width: 6 * s, height: 6 * s
                    ))
                    ctx.fill(dot, with: .color(AttacheMascotMark.headColor.opacity(bubblePose.brightness)))
                }
            } else {
                for d in 0..<3 {
                    let dotAlpha: Double
                    if let phase = bubblePose.dotPhase {
                        dotAlpha = 0.35 + 0.65 * max(0, sin(phase * 2 * .pi - Double(d) * 0.9))
                    } else {
                        dotAlpha = 1
                    }
                    let dot = Path(ellipseIn: CGRect(
                        x: p(bubble.x + 9 + CGFloat(d) * 9, bubble.y + 10.5).x,
                        y: p(bubble.x + 9 + CGFloat(d) * 9, bubble.y + 10.5).y,
                        width: 6 * s, height: 6 * s
                    ))
                    ctx.fill(dot, with: .color(AttacheMascotMark.headColor.opacity(dotAlpha * bubblePose.brightness)))
                }
            }

            if bubblePose.pop > 0.01 {
                let progress = bubblePose.pop
                for d in 0..<6 {
                    let angle = -Double.pi * 5 / 6 + Double(d) * (2 * Double.pi / 3) / 5
                    let radius = (10 + 30 * progress) * s
                    let dotCenter = CGPoint(
                        x: center.x + CGFloat(cos(angle)) * radius,
                        y: center.y - 13 * s + CGFloat(sin(angle)) * radius
                    )
                    let size = 5 * (1 - progress * 0.5) * s
                    let confetti = Path(ellipseIn: CGRect(
                        x: dotCenter.x - size / 2, y: dotCenter.y - size / 2, width: size, height: size
                    ))
                    context.fill(confetti, with: .color(AttacheMascotMark.bubbleColors[index].opacity(1 - progress)))
                }
            }
        }
    }
}
