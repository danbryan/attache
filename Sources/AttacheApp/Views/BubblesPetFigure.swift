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
/// What floats above the head in `.head` anatomy (INF-284): the voice arcs
/// only while audio is the story; otherwise a small phase totem. `.full`
/// anatomy ignores this and always draws the mark's arcs.
enum BubblesOverhead: Equatable {
    case none
    case arcs
    case thinking
    case tool
    case preparingAudio
    case paused
    case sleeping
}

/// An emoji or small drawn prop rendered beside the pet during a moment (a
/// waving hand, a permission flag). Character-agnostic: it sits at a design
/// coordinate around any pet, so the brain reads it as the pet's own gesture
/// even though the pet has no arms. Populated by `applyMoment`.
struct BubblesProp: Equatable {
    enum Content: Equatable {
        case emoji(String)
        case flag(red: Bool)
    }
    var content: Content
    /// Position in the pose's design units (the head sits around 120, 112).
    var position: CGPoint
    /// Emoji point size / flag height, in design units.
    var size: CGFloat = 24
    var rotation: Double = 0
    var opacity: Double = 1
}

struct BubblesPose: Equatable {
    /// Breathing cycle contribution 0-1 (scales the figure 1.000-1.015).
    var breathe: Double = 0
    /// The overhead indicator for `.head` anatomy (INF-284).
    var overhead: BubblesOverhead = .arcs
    /// A 0-1 sawtooth clock for overhead glyph animation, motor-driven.
    var overheadPhase: Double = 0
    /// Whole seconds spent in the current overhead state, for the
    /// preparing-audio elapsed counter (INF-285).
    var overheadSeconds: Int = 0
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
    /// Compaction squish 0-1: a strong, dedicated flatten-and-widen for context
    /// compaction (up to ~55% shorter, ~38% wider), separate from the subtle
    /// celebrate squash.
    var compaction: Double = 0
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
    /// Emoji / flag props drawn beside the pet for the current moment.
    var props: [BubblesProp] = []

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
        pose.overheadPhase = limit(pose.overheadPhase, 0...1)
        pose.overheadSeconds = max(0, pose.overheadSeconds)
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

/// The character in the middle of the ring (INF-283). Every character is a
/// renderer over the same `BubblesPose`: it must express eyes (openness,
/// gaze, dizzy crosses, worried brows), the mouth (smile plus the open
/// lip-sync shape), cheek glow, and head tilt; breathing, hops, squash, and
/// sway arrive through the shared figure transform. The mark and all brand
/// surfaces always use `.bubbles`.
enum BubblesPetCharacter: String, CaseIterable, Identifiable {
    /// The robot, Attaché: the default companion and the brand face
    /// (INF-291, retired the Bubbles mascot). The rawValue stays "robot"
    /// so saved preferences survive; a saved "bubbles" no longer resolves
    /// and falls back to the default.
    case robot
    case cowboy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .robot: return "Attaché"
        case .cowboy: return "Colt"
        }
    }

    /// A face emoji standing in for each character where the rig can't
    /// render (voicemail avatars, the promo video).
    var avatarEmoji: String {
        switch self {
        case .robot: return "🤖"
        case .cowboy: return "🤠"
        }
    }
}

struct BubblesPetFigure: View {
    var pose: BubblesPose = .neutral
    var arcColor: Color = Color(red: 10 / 255, green: 132 / 255, blue: 1)
    var bodyColor: Color = Color(red: 242 / 255, green: 242 / 255, blue: 245 / 255)
    var headroom: CGFloat = 0
    var anatomy: BubblesPetAnatomy = .full
    /// Live companion character; only consulted by `.head` anatomy.
    var character: BubblesPetCharacter = .robot
    /// Fleet motes (INF-275), pre-positioned in design units by the motor.
    var fleetMotes: [BubblesFleetMote] = []
    /// The focused session's mote fill (INF-281): white on dark, near-black
    /// on light, so it never collides with a harness hue. Codex owns blue.
    var accentColor: Color = .white
    /// True when `accentColor` is light, so glyphs drawn on the focused
    /// mote can flip to a dark stroke.
    var accentIsLight = true

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
            let compaction = min(1, max(0, pose.compaction))
            figure.scaleBy(
                x: breatheScale * (1 + 0.05 * squashUp - 0.03 * stretchUp + 0.38 * compaction),
                y: breatheScale * (1 - 0.06 * squashUp + 0.05 * stretchUp - 0.55 * compaction)
            )
            figure.translateBy(x: -anchor.x, y: -anchor.y - pose.hop * s)

            switch anatomy {
            case .full:
                // The brand figure is now the robot head under its voice arcs
                // (INF-291); the limbs and typing bubbles retired with the
                // Bubbles mascot.
                drawArcs(in: figure, pose: pose, p: p, s: s)
                drawHead(in: figure, pose: pose, p: p, s: s)
            case .head:
                // The ring's far half passes behind the pet; the mote layer
                // stays untranslated so its design coordinates match the
                // choreography's ring (already centered on the dropped head).
                drawFleet(in: figure, p: p, s: s, behind: true)
                var headLayer = figure
                headLayer.translateBy(x: 0, y: Self.headAnatomyDrop * s)
                drawOverhead(in: headLayer, pose: pose, p: p, s: s)
                drawHead(in: headLayer, pose: pose, p: p, s: s)
                drawHeadConfetti(in: headLayer, pose: pose, p: p, s: s)
                drawProps(in: headLayer, pose: pose, p: p, s: s)
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
                    with: .color(color.opacity(0.55 * mote.opacity)),
                    style: StrokeStyle(lineWidth: 1.2 * s)
                )
            }
            let darkInk = Color(red: 0.02, green: 0.04, blue: 0.09)
            let onFocused = mote.fill == .focused
            if let count = mote.count {
                let ink = onFocused && !accentIsLight ? Color.white : darkInk
                let text = Text("\(min(count, 999))")
                    .font(.system(size: min(8.5, mote.radius * 1.35) * s, weight: .bold, design: .rounded))
                    .foregroundColor(ink)
                context.draw(context.resolve(text), at: center)
            }
            switch mote.glyph {
            case .none:
                break
            case .question:
                let ink = onFocused && !accentIsLight ? Color.white : darkInk
                let glyph = Text("?")
                    .font(.system(size: mote.radius * 1.5 * s, weight: .heavy, design: .rounded))
                    .foregroundColor(ink.opacity(mote.opacity))
                context.draw(context.resolve(glyph), at: center)
            case .check:
                let ink = onFocused && accentIsLight ? darkInk : Color.white
                var check = Path()
                let u = mote.radius * s
                check.move(to: CGPoint(x: center.x - u * 0.5, y: center.y + u * 0.05))
                check.addLine(to: CGPoint(x: center.x - u * 0.12, y: center.y + u * 0.42))
                check.addLine(to: CGPoint(x: center.x + u * 0.55, y: center.y - u * 0.38))
                context.stroke(
                    check,
                    with: .color(ink.opacity(0.95 * mote.opacity)),
                    style: StrokeStyle(lineWidth: max(1.4, u * 0.24), lineCap: .round, lineJoin: .round)
                )
            }
        }
    }

    /// Celebrate confetti for `.head` anatomy: with no bubbles to burst
    /// from, the pop rings the head instead. Driven by the same
    /// `pose.bubbles[i].pop` one-shots the full anatomy uses.
    /// Emoji / flag props beside the pet (a waving hand, permission flags). They
    /// read as the pet's own gesture without the pet needing arms, and work for
    /// any character.
    private func drawProps(in context: GraphicsContext, pose: BubblesPose, p: (CGFloat, CGFloat) -> CGPoint, s: CGFloat) {
        for prop in pose.props where prop.opacity > 0.01 {
            let center = p(prop.position.x, prop.position.y)
            var layer = context
            layer.opacity = min(1, max(0, prop.opacity))
            layer.translateBy(x: center.x, y: center.y)
            layer.rotate(by: .degrees(prop.rotation))
            switch prop.content {
            case .emoji(let emoji):
                let text = Text(emoji).font(.system(size: max(1, prop.size) * s))
                layer.draw(layer.resolve(text), at: .zero)
            case .flag(let red):
                let h = max(1, prop.size) * s
                let pole = Path { path in
                    path.move(to: CGPoint(x: -h * 0.34, y: -h * 0.62))
                    path.addLine(to: CGPoint(x: -h * 0.34, y: h * 0.62))
                }
                layer.stroke(pole, with: .color(Color(white: 0.82)),
                             style: StrokeStyle(lineWidth: 2.4 * s, lineCap: .round))
                let cloth = Path { path in
                    path.move(to: CGPoint(x: -h * 0.34, y: -h * 0.62))
                    path.addLine(to: CGPoint(x: h * 0.52, y: -h * 0.42))
                    path.addLine(to: CGPoint(x: -h * 0.34, y: -h * 0.12))
                    path.closeSubpath()
                }
                let color = red
                    ? Color(red: 0.91, green: 0.24, blue: 0.24)
                    : Color(red: 0.20, green: 0.78, blue: 0.36)
                layer.fill(cloth, with: .color(color))
            }
        }
    }

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

    /// The crown for `.head` anatomy (INF-284): voice arcs only while audio
    /// is the story, otherwise a small phase totem. Everything here stays
    /// inside the reserved crown zone above the circular ring's apex
    /// (INF-285), so orbit traffic never touches an indicator.
    private func drawOverhead(in context: GraphicsContext, pose: BubblesPose, p: (CGFloat, CGFloat) -> CGPoint, s: CGFloat) {
        let ink = arcColor
        let crown = p(120, 22)
        switch pose.overhead {
        case .none:
            break
        case .arcs:
            drawArcs(in: context, pose: pose, p: p, s: s)
        case .thinking:
            // A thought bubble whose cloud is a brain (Dan's pick, INF-285):
            // two trail dots rising from the head into a pink lobed blob
            // with a center groove, gently swelling as it "thinks".
            let brainPink = Color(red: 238 / 255, green: 154 / 255, blue: 166 / 255)
            let swell = 1 + 0.06 * sin(pose.overheadPhase * 2 * .pi)
            for (index, trail) in [(x: 106.0, y: 46.0, r: 2.2), (x: 111.0, y: 38.0, r: 3.2)].enumerated() {
                let alpha = 0.5 + 0.5 * max(0, sin((pose.overheadPhase + Double(index) * 0.3) * 2 * .pi))
                let dot = Path(ellipseIn: CGRect(
                    x: p(trail.x, trail.y).x - trail.r * s, y: p(trail.x, trail.y).y - trail.r * s,
                    width: trail.r * 2 * s, height: trail.r * 2 * s
                ))
                context.fill(dot, with: .color(brainPink.opacity(alpha)))
            }
            let lobes: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
                (117, 24, 7.5), (125, 21, 8), (132, 25, 6.5), (121, 28, 7), (129, 29, 6),
            ]
            for lobe in lobes {
                let radius = lobe.r * swell * s
                let blob = Path(ellipseIn: CGRect(
                    x: p(lobe.x, lobe.y).x - radius, y: p(lobe.x, lobe.y).y - radius,
                    width: radius * 2, height: radius * 2
                ))
                context.fill(blob, with: .color(brainPink))
            }
            var groove = Path()
            groove.move(to: p(124.5, 14))
            groove.addQuadCurve(to: p(124.5, 33), control: p(121, 24))
            context.stroke(
                groove,
                with: .color(Color(red: 0.75, green: 0.35, blue: 0.44).opacity(0.75)),
                style: StrokeStyle(lineWidth: 1.6 * s, lineCap: .round)
            )
        case .tool:
            // A slowly turning gear.
            var gear = context
            gear.translateBy(x: crown.x, y: crown.y)
            gear.rotate(by: .degrees(pose.overheadPhase * 360))
            for tooth in 0..<8 {
                var tick = gear
                tick.rotate(by: .degrees(Double(tooth) * 45))
                let toothPath = Path(
                    roundedRect: CGRect(x: -1.6 * s, y: -9.5 * s, width: 3.2 * s, height: 4 * s),
                    cornerRadius: 1.2 * s
                )
                tick.fill(toothPath, with: .color(ink.opacity(0.85)))
            }
            let wheel = Path(ellipseIn: CGRect(
                x: crown.x - 4.6 * s, y: crown.y - 4.6 * s, width: 9.2 * s, height: 9.2 * s
            ))
            context.stroke(wheel, with: .color(ink.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 3.6 * s))
            let toolSeconds = Text("\(min(pose.overheadSeconds, 999))s")
                .font(.system(size: 7 * s, weight: .bold, design: .rounded))
                .foregroundColor(ink.opacity(0.8))
            context.draw(context.resolve(toolSeconds), at: CGPoint(x: crown.x + 17 * s, y: crown.y))
        case .preparingAudio:
            // The reply is streaming in: a clock with the elapsed count
            // inside it, so waiting on the agent reads as time passing
            // (INF-286).
            let face = Path(ellipseIn: CGRect(
                x: crown.x - 10 * s, y: crown.y - 10 * s, width: 20 * s, height: 20 * s
            ))
            context.stroke(face, with: .color(ink.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 1.8 * s))
            let stem = Path(
                roundedRect: CGRect(x: crown.x - 1.6 * s, y: crown.y - 13.5 * s, width: 3.2 * s, height: 3 * s),
                cornerRadius: 1.2 * s
            )
            context.fill(stem, with: .color(ink.opacity(0.85)))
            let markerAngle = pose.overheadPhase * 2 * .pi - .pi / 2
            let marker = Path(ellipseIn: CGRect(
                x: crown.x + CGFloat(cos(markerAngle)) * 7.6 * s - 1.4 * s,
                y: crown.y + CGFloat(sin(markerAngle)) * 7.6 * s - 1.4 * s,
                width: 2.8 * s, height: 2.8 * s
            ))
            context.fill(marker, with: .color(ink))
            let seconds = Text("\(min(pose.overheadSeconds, 999))")
                .font(.system(size: 8 * s, weight: .bold, design: .rounded))
                .foregroundColor(ink.opacity(0.95))
            context.draw(context.resolve(seconds), at: crown)
        case .paused:
            for offset in [-4.5, 4.5] {
                let bar = Path(
                    roundedRect: CGRect(
                        x: crown.x + CGFloat(offset - 2) * s, y: crown.y - 8 * s,
                        width: 4 * s, height: 16 * s
                    ),
                    cornerRadius: 2 * s
                )
                context.fill(bar, with: .color(ink.opacity(0.8)))
            }
        case .sleeping:
            // Three z's centered over the head, pulsing in sequence.
            for (index, z) in [(x: 104.0, size: 6.5), (x: 120.0, size: 10.0), (x: 136.0, size: 6.5)].enumerated() {
                let pulse = 0.3 + 0.7 * max(0, sin((pose.overheadPhase + Double(index) * 0.33) * 2 * .pi))
                let glyph = Text("z")
                    .font(.system(size: z.size * s, weight: .bold, design: .rounded))
                    .foregroundColor(ink.opacity(pulse))
                context.draw(context.resolve(glyph), at: p(CGFloat(z.x), 24))
            }
        }
    }

    private func drawArcs(in context: GraphicsContext, pose: BubblesPose, p: (CGFloat, CGFloat) -> CGPoint, s: CGFloat) {
        // The head anatomy tightens and raises the voice arcs into the crown
        // zone inside the circular ring's apex (INF-285), so orbit traffic
        // never touches them even while speech ripples them; the mark keeps
        // its canonical 40/66/90 at the canonical center.
        let arcSpecs: [(radius: CGFloat, width: CGFloat, opacity: Double)] = anatomy == .head
            ? [(24, 7, 1.0), (33, 7, 0.62), (42, 7, 0.30)]
            : [(40, 9, 1.0), (66, 9, 0.62), (90, 9, 0.30)]
        let arcCenter = anatomy == .head ? p(120, 30) : p(120, 89)
        for (index, spec) in arcSpecs.enumerated() {
            let ripple = CGFloat(4 * pose.arcRipple * sin(pose.arcPhase - Double(index) * 1.1))
            var arc = Path()
            arc.addArc(
                center: arcCenter,
                radius: (spec.radius + ripple) * s,
                startAngle: .degrees(anatomy == .head ? -128 : -132),
                endAngle: .degrees(anatomy == .head ? -52 : -48),
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

        switch character {
        case .robot:
            drawRobotFace(in: head, pose: pose, p: p, s: s)
        case .cowboy:
            drawCowboyFace(in: head, pose: pose, p: p, s: s)
        }
    }

    private func drawBubblesFace(in head: GraphicsContext, pose: BubblesPose, p: (CGFloat, CGFloat) -> CGPoint, s: CGFloat) {
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

    /// Volt (INF-283): a squared-off robot head. Eyes are LED bars whose
    /// height is `eyeOpenness`, the mouth is an equalizer that dances with
    /// `mouthOpen`, worry tilts the LEDs, dizzy crosses them out, and the
    /// antenna bulb carries the cheek glow.
    private func drawRobotFace(in head: GraphicsContext, pose: BubblesPose, p: (CGFloat, CGFloat) -> CGPoint, s: CGFloat) {
        let steel = Color(red: 199 / 255, green: 208 / 255, blue: 220 / 255)
        let screen = AttacheMascotMark.faceColor
        let led = Color(red: 102 / 255, green: 227 / 255, blue: 1)

        var antenna = Path()
        antenna.move(to: p(120, 82))
        antenna.addLine(to: p(120, 73))
        head.stroke(antenna, with: .color(steel), style: StrokeStyle(lineWidth: 3 * s, lineCap: .round))
        let bulb = Path(ellipseIn: CGRect(
            x: p(116.5, 66).x, y: p(116.5, 66).y, width: 7 * s, height: 7 * s
        ))
        head.fill(bulb, with: .color(AttacheMascotMark.cheekColor.opacity(0.35 + 0.65 * pose.cheekGlow)))

        let plate = Path(
            roundedRect: CGRect(x: p(88, 82).x, y: p(88, 82).y, width: 64 * s, height: 60 * s),
            cornerRadius: 14 * s
        )
        head.fill(plate, with: .color(steel))
        let glass = Path(
            roundedRect: CGRect(x: p(94, 92).x, y: p(94, 92).y, width: 52 * s, height: 34 * s),
            cornerRadius: 8 * s
        )
        head.fill(glass, with: .color(screen))

        var face = head
        let gx = max(-3, min(3, pose.gaze.width))
        let gy = max(-3, min(3, pose.gaze.height))
        face.translateBy(x: gx * s, y: gy * s)

        let eyeAlpha = 1 - pose.dizzy
        let openness = pose.eyeOpenness * (1 - 0.4 * pose.browWorry)
        if eyeAlpha > 0.01 {
            for (index, eyeX) in [99.0, 127.0].enumerated() {
                let height = max(2.5, 11 * openness)
                var eye = face
                let center = p(eyeX + 7, 106)
                let worryTilt = pose.browWorry * 14 * (index == 0 ? 1 : -1)
                eye.translateBy(x: center.x, y: center.y)
                eye.rotate(by: .degrees(worryTilt))
                eye.translateBy(x: -center.x, y: -center.y)
                let bar = Path(
                    roundedRect: CGRect(
                        x: p(eyeX, 106).x, y: center.y - height / 2 * s,
                        width: 14 * s, height: height * s
                    ),
                    cornerRadius: 2.5 * s
                )
                eye.fill(bar, with: .color(led.opacity(eyeAlpha)))
            }
        }
        if pose.dizzy > 0.01 {
            var crosses = Path()
            for centerX in [106.0, 134.0] {
                crosses.move(to: p(centerX - 5, 101))
                crosses.addLine(to: p(centerX + 5, 111))
                crosses.move(to: p(centerX + 5, 101))
                crosses.addLine(to: p(centerX - 5, 111))
            }
            face.stroke(
                crosses,
                with: .color(led.opacity(pose.dizzy)),
                style: StrokeStyle(lineWidth: 3.5 * s, lineCap: .round)
            )
        }

        for boltX in [92.5, 143.5] {
            let bolt = Path(ellipseIn: CGRect(
                x: p(boltX, 119).x, y: p(boltX, 119).y, width: 4 * s, height: 4 * s
            ))
            head.fill(bolt, with: .color(AttacheMascotMark.cheekColor.opacity(pose.cheekGlow)))
        }

        if pose.mouthOpen < 0.15 {
            let halfWidth = (4 + 8 * pose.smile) * s
            let mouth = Path(
                roundedRect: CGRect(
                    x: p(120, 132.5).x - halfWidth, y: p(120, 132.5).y,
                    width: halfWidth * 2, height: 3.5 * s
                ),
                cornerRadius: 1.75 * s
            )
            face.fill(mouth, with: .color(screen))
        } else {
            for bar in 0..<5 {
                let x = 108.0 + Double(bar) * 6
                let wave = 0.55 + 0.45 * sin(Double(bar) * 2.1 + pose.mouthOpen * 9)
                let height = (3 + 10 * pose.mouthOpen * wave) * s
                let slot = Path(
                    roundedRect: CGRect(
                        x: p(CGFloat(x), 134).x, y: p(CGFloat(x), 134).y - height / 2,
                        width: 4 * s, height: height
                    ),
                    cornerRadius: 2 * s
                )
                face.fill(slot, with: .color(screen))
            }
        }
    }

    /// Colt (INF-288, mustache INF-291): a cowboy. Expressive round eyes with
    /// pupils that ride the gaze, a brown ten-gallon hat as the signature
    /// silhouette, a handlebar mustache, and a red neckerchief. Everything is
    /// drawn in the `head` layer, so the hat tilts with `headTilt`.
    private func drawCowboyFace(in head: GraphicsContext, pose: BubblesPose, p: (CGFloat, CGFloat) -> CGPoint, s: CGFloat) {
        let cream = AttacheMascotMark.headColor
        let ink = AttacheMascotMark.faceColor
        let hatBrown = Color(red: 0.45, green: 0.31, blue: 0.19)
        let hatBand = Color(red: 0.30, green: 0.20, blue: 0.12)
        let bandanaRed = Color(red: 0.82, green: 0.24, blue: 0.24)
        let stache = Color(red: 0.34, green: 0.22, blue: 0.13)

        let skull = Path(ellipseIn: CGRect(
            x: p(87, 79).x, y: p(87, 79).y, width: 66 * s, height: 66 * s
        ))
        head.fill(skull, with: .color(cream))

        let gx = max(-3, min(3, pose.gaze.width))
        let gy = max(-3, min(3, pose.gaze.height))
        let eyeAlpha = 1 - pose.dizzy
        let openness = pose.eyeOpenness * (1 - 0.35 * pose.browWorry)
        for eyeX in [106.0, 134.0] {
            let center = p(CGFloat(eyeX), 106)
            if eyeAlpha > 0.01, openness > 0.12 {
                let white = Path(ellipseIn: CGRect(
                    x: center.x - 7 * s, y: center.y - 7 * s * openness,
                    width: 14 * s, height: 14 * s * openness
                ))
                head.fill(white, with: .color(.white.opacity(eyeAlpha)))
                let pupil = Path(ellipseIn: CGRect(
                    x: center.x - 3.4 * s + gx * 1.6 * s,
                    y: center.y - 3.4 * s * openness + gy * 1.4 * s,
                    width: 6.8 * s, height: 6.8 * s * openness
                ))
                head.fill(pupil, with: .color(ink.opacity(eyeAlpha)))
            } else if eyeAlpha > 0.01 {
                var lid = Path()
                lid.move(to: CGPoint(x: center.x - 7 * s, y: center.y))
                lid.addQuadCurve(
                    to: CGPoint(x: center.x + 7 * s, y: center.y),
                    control: CGPoint(x: center.x, y: center.y + 5 * s)
                )
                head.stroke(lid, with: .color(ink.opacity(eyeAlpha)),
                            style: StrokeStyle(lineWidth: 4 * s, lineCap: .round))
            }
            if pose.dizzy > 0.01 {
                var cross = Path()
                cross.move(to: CGPoint(x: center.x - 5 * s, y: center.y - 5 * s))
                cross.addLine(to: CGPoint(x: center.x + 5 * s, y: center.y + 5 * s))
                cross.move(to: CGPoint(x: center.x + 5 * s, y: center.y - 5 * s))
                cross.addLine(to: CGPoint(x: center.x - 5 * s, y: center.y + 5 * s))
                head.stroke(cross, with: .color(ink.opacity(pose.dizzy)),
                            style: StrokeStyle(lineWidth: 3.5 * s, lineCap: .round))
            }
        }
        if pose.browWorry > 0.01 {
            var brows = Path()
            brows.move(to: p(98, 97))
            brows.addLine(to: p(113, 93))
            brows.move(to: p(127, 93))
            brows.addLine(to: p(142, 97))
            head.stroke(brows, with: .color(ink.opacity(pose.browWorry)),
                        style: StrokeStyle(lineWidth: 4 * s, lineCap: .round))
        }

        // Mouth: the same smile / open-mouth swap the mark uses.
        if pose.mouthOpen < 0.15 {
            let halfWidth = 11 * pose.smile
            let depth = 13 * pose.smile
            var mouth = Path()
            mouth.move(to: p(120 - halfWidth, 121))
            mouth.addCurve(
                to: p(120 + halfWidth, 121),
                control1: p(120 - halfWidth * 0.75, 121 + depth),
                control2: p(120 + halfWidth * 0.75, 121 + depth)
            )
            mouth.closeSubpath()
            head.fill(mouth, with: .color(ink))
        } else {
            let rx = 8 * (0.5 + 0.5 * pose.mouthOpen)
            let ry = 3 + 9 * pose.mouthOpen
            let mouthCenter = p(120, 123 + 3 * pose.mouthOpen)
            let open = Path(ellipseIn: CGRect(
                x: mouthCenter.x - rx * s, y: mouthCenter.y - ry * s,
                width: rx * 2 * s, height: ry * 2 * s
            ))
            head.fill(open, with: .color(ink))
        }

        // Handlebar mustache above the mouth: thin curled tips, thick center.
        var mustache = Path()
        mustache.move(to: p(104, 114))
        mustache.addCurve(to: p(120, 116), control1: p(109, 111), control2: p(114, 114))
        mustache.addCurve(to: p(136, 114), control1: p(126, 114), control2: p(131, 111))
        mustache.addCurve(to: p(120, 120), control1: p(132, 120), control2: p(126, 119))
        mustache.addCurve(to: p(104, 114), control1: p(114, 119), control2: p(108, 120))
        mustache.closeSubpath()
        head.fill(mustache, with: .color(stache))

        // Neckerchief at the collar: a red band across the bottom of the
        // face with a knot dropping below the chin.
        let kerchief = Path(
            roundedRect: CGRect(x: p(99, 137).x, y: p(99, 137).y, width: 42 * s, height: 9 * s),
            cornerRadius: 3 * s
        )
        head.fill(kerchief, with: .color(bandanaRed))
        var knot = Path()
        knot.move(to: p(114, 143))
        knot.addLine(to: p(126, 143))
        knot.addLine(to: p(120, 152))
        knot.closeSubpath()
        head.fill(knot, with: .color(bandanaRed))

        // The hat, last, so its brim covers the forehead.
        let brim = Path(ellipseIn: CGRect(
            x: p(78, 77).x, y: p(78, 77).y, width: 84 * s, height: 13 * s
        ))
        head.fill(brim, with: .color(hatBrown))
        let crown = Path(
            roundedRect: CGRect(x: p(101, 55).x, y: p(101, 55).y, width: 38 * s, height: 27 * s),
            cornerRadius: 11 * s
        )
        head.fill(crown, with: .color(hatBrown))
        let band = Path(
            roundedRect: CGRect(x: p(101, 73).x, y: p(101, 73).y, width: 38 * s, height: 6 * s),
            cornerRadius: 2 * s
        )
        head.fill(band, with: .color(hatBand))
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
