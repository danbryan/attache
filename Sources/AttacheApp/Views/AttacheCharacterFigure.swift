import AttacheCore
import SwiftUI

/// One agent's transient reaction pose. Fleet motes carry persistent session
/// state; this small channel only drives momentary motion and celebration.
struct AgentSignalPose: Equatable {
    /// Units the reaction rises off its resting spot (negative droops).
    var lift: CGFloat = 0
    /// Small horizontal jitter, for shell shakes and wobbles.
    var jitter: CGFloat = 0
    /// Rotation in degrees around the reaction's center.
    var tilt: Double = 0
    /// 1 lit, dimmer marks the reaction inactive; hue never changes.
    var brightness: Double = 1
    /// Typing-dot sweep phase in 0-1; nil freezes the dots solid.
    var dotPhase: Double?
    /// 0-1: dots orbit the reaction (web tool flavor).
    var orbit: Double = 0
    /// Confetti burst progress 0-1 (celebrate one-shot).
    var pop: Double = 0
}

/// A complete pose over the locked Attache geometry: every field is a small
/// deformation of `design/attache-logo.svg`'s anatomy, so `.neutral` renders
/// the canonical mark exactly (verified pixel-for-pixel by
/// `Attache --render-character-poses`). The animation spec that motivates each
/// parameter is `design/attache-animation-spec.md`.
/// What floats above the head in `.head` anatomy (INF-284): the voice arcs
/// only while audio is the story; otherwise a small phase totem. `.full`
/// anatomy ignores this and always draws the mark's arcs.
enum AttacheOverhead: Equatable {
    case none
    case arcs
    case thinking
    case tool
    case preparingAudio
    case paused
    case sleeping
    case compacting
    case configuring
    case swarm
}

/// An emoji or small drawn prop rendered beside the character during a moment (a
/// waving hand, a permission flag). Character-agnostic: it sits at a design
/// coordinate around any character, so the brain reads it as the character's own gesture
/// even though the character has no arms. Populated by `applyMoment`.
struct AttacheProp: Equatable {
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

struct AttachePose: Equatable {
    /// Breathing cycle contribution 0-1 (scales the figure 1.000-1.015).
    var breathe: Double = 0
    /// The overhead indicator for `.head` anatomy (INF-284).
    var overhead: AttacheOverhead = .arcs
    /// A 0-1 sawtooth clock for overhead glyph animation, motor-driven.
    var overheadPhase: Double = 0
    /// Whole seconds spent in the current overhead state, for the
    /// preparing-audio elapsed counter (INF-285).
    var overheadSeconds: Int = 0
    /// A count for the overhead symbol (the swarm's live sub-agent count).
    var overheadCount: Int = 0
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
    var agentSignals: [AgentSignalPose] = [.init(), .init(), .init()]
    /// Emoji / flag props drawn beside the character for the current moment.
    var props: [AttacheProp] = []
    /// The real analyzed per-band audio energy for the current frame
    /// (`VisualizerRenderState.bars`), threaded in by the motor so the mouth
    /// equalizer and Echo's voice bars draw the actual spoken spectrum instead
    /// of a synthetic profile. Empty when no audio is playing, so `.neutral`
    /// (and every silent frame) stays the resting geometry: the mouths render
    /// their flat rest shape and Echo its static resting arch.
    var audioBars: [Float] = []

    static let neutral = AttachePose()

    /// Clamps every field to its sane range before drawing, so a misbehaving
    /// caller (a diverged spring, a bad simulator value) can distort a frame
    /// but never draw eyes across the whole canvas or rotate the head off its
    /// neck. Neutral values pass through untouched, keeping the mark
    /// pixel-identity check honest.
    func sanitized() -> AttachePose {
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
        pose.agentSignals = pose.agentSignals.map { reaction in
            var next = reaction
            next.lift = CGFloat(limit(Double(reaction.lift), -12...26))
            next.jitter = CGFloat(limit(Double(reaction.jitter), -8...8))
            next.tilt = limit(reaction.tilt, -20...20)
            next.brightness = limit(reaction.brightness, 0...1)
            next.dotPhase = reaction.dotPhase.map { limit($0, 0...1) }
            next.orbit = limit(reaction.orbit, 0...1)
            next.pop = limit(reaction.pop, 0...1)
            return next
        }
        return pose
    }
}

/// Draws one `AttachePose` from the same 240-unit geometry as
/// `AttacheMascotMark` (design box padded to 252 so the outer voice arc never
/// clips). `headroom` adds design units above the box so hop poses have room;
/// with `headroom == 0` and `.neutral` the output is the canonical mark.
/// This view is a pure function of its pose: animation lives in the caller
/// (INF-270's character renderer springs pose fields; this file never reads state).
/// Which anatomy the figure draws. `.full` is the canonical mark: robot head
/// and three voice arcs. `.head` is the live character with its activity crown
/// and session ring, so a custom character only replaces the center artwork.
enum AttacheCharacterAnatomy {
    case full
    case head
}

/// The character in the middle of the ring (INF-283). Every character is a
/// renderer over the same `AttachePose`: it must express eyes (openness,
/// gaze, dizzy crosses, worried brows), the mouth (smile plus the open
/// lip-sync shape), cheek glow, and head tilt; breathing, hops, squash, and
/// sway arrive through the shared figure transform. The mark and all brand
/// surfaces always use `.robot`.
enum AttacheCharacter: String, CaseIterable, Identifiable, Codable {
    /// The robot, Attaché: the default attache and the brand face
    /// The raw value stays `robot` so saved preferences survive.
    case robot
    case cowboy
    /// A user-supplied image presence (the "bring your own presence" atlas,
    /// docs/byo-presence.md). Mounts uploaded artwork into the same rig; which
    /// package it draws is resolved from the personality's `customPresenceRef`.
    case customAtlas

    var id: String { rawValue }

    /// Only the built-in illustrated characters are offered in the picker's
    /// fixed list; the custom presence is added dynamically when a package
    /// exists, so it is excluded here to keep `allCases`-driven UI stable.
    static var builtIns: [AttacheCharacter] { [.robot, .cowboy] }

    var title: String {
        switch self {
        case .robot: return "Attaché"
        case .cowboy: return "Colt"
        case .customAtlas: return "Custom"
        }
    }

    /// A face emoji standing in for each character where the rig can't
    /// render (voicemail avatars, the promo video).
    var avatarEmoji: String {
        switch self {
        case .robot: return "🤖"
        case .cowboy: return "🤠"
        case .customAtlas: return "🙂"
        }
    }
}

struct AttacheCharacterFigure: View {
    var pose: AttachePose = .neutral
    var arcColor: Color = Color(red: 10 / 255, green: 132 / 255, blue: 1)
    var bodyColor: Color = Color(red: 242 / 255, green: 242 / 255, blue: 245 / 255)
    var headroom: CGFloat = 0
    var anatomy: AttacheCharacterAnatomy = .full
    /// Live attache character; only consulted by `.head` anatomy.
    var character: AttacheCharacter = .robot
    /// Resolved artwork for `.customAtlas`. When nil (e.g. a dangling
    /// reference), `.customAtlas` falls back to the robot face.
    var customArtwork: AtlasArtwork?
    /// Echo is not a third illustrated character. It replaces the center face
    /// with voice bars while keeping the same crown, fleet, props, and motion
    /// contract as Attaché and Colt.
    var rendersEchoBars = false
    /// Fleet motes (INF-275), pre-positioned in design units by the motor.
    var fleetMotes: [AttacheFleetMote] = []
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
                // The brand figure is the robot head under its voice arcs.
                drawArcs(in: figure, pose: pose, p: p, s: s)
                drawHead(in: figure, pose: pose, p: p, s: s)
            case .head:
                // The ring's far half passes behind the character; the mote layer
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
    private func moteColor(_ fill: AttacheFleetMote.Fill) -> Color {
        switch fill {
        case .agent(.claude):
            return AttacheMascotMark.agentColors[0]
        case .agent(.codex):
            return AttacheMascotMark.agentColors[1]
        case .agent(.none):
            return AttacheMascotMark.agentColors[2]
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

    /// Celebrate confetti for `.head` anatomy: with no attache to burst
    /// from, the pop rings the head instead. Driven by the same
    /// `pose.agentSignals[i].pop` one-shots the full anatomy uses.
    /// Emoji / flag props beside the character (a waving hand, permission flags). They
    /// read as the character's own gesture without the character needing arms, and work for
    /// any character.
    private func drawProps(in context: GraphicsContext, pose: AttachePose, p: (CGFloat, CGFloat) -> CGPoint, s: CGFloat) {
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

    private func drawHeadConfetti(in context: GraphicsContext, pose: AttachePose, p: (CGFloat, CGFloat) -> CGPoint, s: CGFloat) {
        let progress = pose.agentSignals.map(\.pop).max() ?? 0
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
                with: .color(AttacheMascotMark.agentColors[d % 3].opacity(1 - progress))
            )
        }
    }

    /// The crown for `.head` anatomy (INF-284): voice arcs only while audio
    /// is the story, otherwise a small phase totem. Everything here stays
    /// inside the reserved crown zone above the circular ring's apex
    /// (INF-285), so orbit traffic never touches an indicator.
    private func drawOverhead(in context: GraphicsContext, pose: AttachePose, p: (CGFloat, CGFloat) -> CGPoint, s: CGFloat) {
        let ink = arcColor
        let crown = p(120, 22)
        switch pose.overhead {
        case .none:
            break
        case .arcs:
            drawArcs(in: context, pose: pose, p: p, s: s)
        case .thinking:
            // A compact brain indicator (INF-285): two trail dots rise from
            // the head into a pink lobed shape
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
        case .compacting:
            // Two arrows pressing together; the gap closes as compaction deepens.
            let gap = (9 - 6 * min(1, max(0, pose.compaction))) * s
            let w = 7 * s, tip = 4 * s
            var top = Path()
            top.move(to: CGPoint(x: crown.x - w, y: crown.y - gap - tip))
            top.addLine(to: CGPoint(x: crown.x, y: crown.y - gap + tip))
            top.addLine(to: CGPoint(x: crown.x + w, y: crown.y - gap - tip))
            var bottom = Path()
            bottom.move(to: CGPoint(x: crown.x - w, y: crown.y + gap + tip))
            bottom.addLine(to: CGPoint(x: crown.x, y: crown.y + gap - tip))
            bottom.addLine(to: CGPoint(x: crown.x + w, y: crown.y + gap + tip))
            for arrow in [top, bottom] {
                context.stroke(arrow, with: .color(ink.opacity(0.85)),
                               style: StrokeStyle(lineWidth: 3 * s, lineCap: .round, lineJoin: .round))
            }
        case .configuring:
            // A loading spinner sweeping around: being set up.
            let start = pose.overheadPhase * 360
            var spinner = Path()
            spinner.addArc(center: crown, radius: 7 * s,
                           startAngle: .degrees(start), endAngle: .degrees(start + 260), clockwise: false)
            context.stroke(spinner, with: .color(ink.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 3 * s, lineCap: .round))
        case .swarm:
            // Sub-agent sprites fanned above the head, plus a live count.
            let count = max(1, pose.overheadCount)
            let shown = min(5, count)
            for i in 0..<shown {
                let t = shown == 1 ? 0.5 : Double(i) / Double(shown - 1)
                let angle = (t - 0.5) * 30.0
                let drift = 3 + 3 * (0.5 + 0.5 * sin((pose.overheadPhase + Double(i) * 0.2) * 2 * .pi))
                let rad = 9 + drift
                let dx = rad * sin(angle * .pi / 180)
                let dy = -rad * cos(angle * .pi / 180)
                let dotCenter = CGPoint(x: crown.x + CGFloat(dx) * s, y: crown.y + CGFloat(dy) * s)
                let r = 2.6 * s
                let dot = Path(ellipseIn: CGRect(x: dotCenter.x - r, y: dotCenter.y - r, width: r * 2, height: r * 2))
                context.fill(dot, with: .color(ink.opacity(0.85)))
            }
            let label = Text("×\(min(count, 999))")
                .font(.system(size: 7.5 * s, weight: .bold, design: .rounded))
                .foregroundColor(ink.opacity(0.85))
            context.draw(context.resolve(label), at: CGPoint(x: crown.x + 20 * s, y: crown.y))
        }
    }

    private func drawArcs(in context: GraphicsContext, pose: AttachePose, p: (CGFloat, CGFloat) -> CGPoint, s: CGFloat) {
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

    private func drawHead(in context: GraphicsContext, pose: AttachePose, p: (CGFloat, CGFloat) -> CGPoint, s: CGFloat) {
        var head = context
        let pivot = p(120, 112)
        head.translateBy(x: pivot.x, y: pivot.y)
        head.rotate(by: .degrees(pose.headTilt))
        head.translateBy(x: -pivot.x, y: -pivot.y)

        if rendersEchoBars {
            drawEchoBars(in: head, pose: pose, p: p, s: s)
        } else {
            switch character {
            case .robot:
                drawRobotFace(in: head, pose: pose, p: p, s: s)
            case .cowboy:
                drawCowboyFace(in: head, pose: pose, p: p, s: s)
            case .customAtlas:
                if let artwork = customArtwork {
                    drawCustomAtlasFace(in: head, pose: pose, p: p, s: s, artwork: artwork)
                } else {
                    drawRobotFace(in: head, pose: pose, p: p, s: s)
                }
            }
        }
    }

    /// Draws a custom-artwork presence (bring your own presence). Maps the
    /// pose's face fields to the nearest atlas frame and paints that bitmap over
    /// the 252-unit design box. The outer figure already supplies breathing,
    /// sway, hop, and tilt, and the crown and fleet ring draw around this, so
    /// only the face bitmap is painted here; the frame's transparency keeps the
    /// crown and motes visible. Gaze is normalized from the pose's ±3 units.
    /// Tier 0 (neutral only) always resolves to neutral. See docs/byo-presence.md.
    private func drawCustomAtlasFace(
        in head: GraphicsContext,
        pose: AttachePose,
        p: (CGFloat, CGFloat) -> CGPoint,
        s: CGFloat,
        artwork: AtlasArtwork
    ) {
        let state = AtlasFaceState(
            gazeX: Double(pose.gaze.width / 3),
            gazeY: Double(pose.gaze.height / 3),
            eyeOpenness: Double(pose.eyeOpenness),
            mouthOpen: Double(pose.mouthOpen),
            browWorry: Double(pose.browWorry),
            dizzy: Double(pose.dizzy)
        )
        guard let cg = artwork.image(for: state) else {
            drawRobotFace(in: head, pose: pose, p: p, s: s)
            return
        }
        // The frame is a full 252 canvas, but the robot head occupies only the
        // center of the design box, so draw the canvas scaled down to that
        // footprint and centered on the head region. `canvasSpan` is the design
        // width the whole frame spans (smaller = smaller head); `centerY` places
        // it under the arcs with the fleet ring below. Tuned to match the robot
        // head's size and spacing; these three constants are the placement dial.
        let canvasSpan: CGFloat = 110
        let centerX: CGFloat = 120
        let centerY: CGFloat = 94
        let topLeft = p(centerX - canvasSpan / 2, centerY - canvasSpan / 2)
        let rect = CGRect(x: topLeft.x, y: topLeft.y, width: canvasSpan * s, height: canvasSpan * s)
        head.draw(Image(decorative: cg, scale: 1, orientation: .up), in: rect)

        // A still photo can't move its own eyes, so overdraw procedural eyes at
        // the baked anchors: continuous gaze, blink, and error, fully driven by
        // the pose. This is the "replace the eyes with something we can fully
        // animate" path from docs/byo-presence.md.
        if let eyes = artwork.manifest.eyes {
            drawProceduralEyes(
                in: head, eyes: eyes, pose: pose, p: p, s: s,
                canvasSpan: canvasSpan, centerX: centerX, centerY: centerY
            )
        }
    }

    private func drawProceduralEyes(
        in head: GraphicsContext,
        eyes: AttacheCharacterManifest.EyeAnchors,
        pose: AttachePose,
        p: (CGFloat, CGFloat) -> CGPoint,
        s: CGFloat,
        canvasSpan: CGFloat,
        centerX: CGFloat,
        centerY: CGFloat
    ) {
        // Brighten and lift the sampled iris a little so it reads at this size.
        let c0 = eyes.irisColor.count >= 3 ? eyes.irisColor : [0.30, 0.36, 0.30]
        let iris = Color(
            red: min(1, c0[0] * 1.7 + 0.10),
            green: min(1, c0[1] * 1.8 + 0.14),
            blue: min(1, c0[2] * 1.7 + 0.12)
        )
        func viewPoint(_ nx: Double, _ ny: Double) -> CGPoint {
            let dx = (centerX - canvasSpan / 2) + CGFloat(nx) * canvasSpan
            let dy = (centerY - canvasSpan / 2) + CGFloat(ny) * canvasSpan
            return p(dx, dy)
        }
        let gazeX = max(-1, min(1, pose.gaze.width / 3))
        let gazeY = max(-1, min(1, pose.gaze.height / 3))
        let openness = max(0, min(1.2, pose.eyeOpenness))
        let dizzy = max(0, min(1, pose.dizzy))

        for eye in [eyes.left, eyes.right] {
            // Anchors are ground-truth eye centers; size the synthetic eye a bit
            // larger than the detected opening so it fully covers the real eye.
            let center = viewPoint(eye.x, eye.y + 0.004)
            let ew = CGFloat(eye.w) * canvasSpan * s * 1.42
            let eh = CGFloat(eye.h) * canvasSpan * s * 2.7
            drawOneEye(
                in: head, center: center, ew: ew, eh: eh, iris: iris,
                gazeX: gazeX, gazeY: gazeY, openness: openness, dizzy: dizzy
            )
        }
    }

    private func drawOneEye(
        in ctx: GraphicsContext,
        center c: CGPoint,
        ew: CGFloat,
        eh: CGFloat,
        iris irisColor: Color,
        gazeX: CGFloat,
        gazeY: CGFloat,
        openness: CGFloat,
        dizzy: CGFloat
    ) {
        // Aperture: full when open, a thin slit when closed (blink).
        let apertureH = max(eh * 0.10, eh * min(1, openness))
        let apertureRect = CGRect(x: c.x - ew / 2, y: c.y - apertureH / 2, width: ew, height: apertureH)
        let aperture = Path(ellipseIn: apertureRect)

        if dizzy < 0.5 {
            var eyeCtx = ctx
            eyeCtx.clip(to: aperture)
            // sclera
            eyeCtx.fill(aperture, with: .color(Color(red: 0.96, green: 0.95, blue: 0.93)))
            // iris, offset by gaze and clamped inside the eye
            let irisR = eh * 0.55
            let maxX = max(0, ew / 2 - irisR * 0.65)
            // Eyes move mostly horizontally; keep vertical travel small so
            // looking up/down doesn't expose a bug-eyed band of sclera.
            let maxY = eh * 0.15
            let ic = CGPoint(x: c.x + gazeX * maxX, y: c.y + gazeY * maxY)
            eyeCtx.fill(
                Path(ellipseIn: CGRect(x: ic.x - irisR, y: ic.y - irisR, width: irisR * 2, height: irisR * 2)),
                with: .color(irisColor)
            )
            // iris rim + pupil + highlight
            eyeCtx.stroke(
                Path(ellipseIn: CGRect(x: ic.x - irisR, y: ic.y - irisR, width: irisR * 2, height: irisR * 2)),
                with: .color(.black.opacity(0.35)), lineWidth: max(0.5, eh * 0.05)
            )
            let pr = irisR * 0.46
            eyeCtx.fill(
                Path(ellipseIn: CGRect(x: ic.x - pr, y: ic.y - pr, width: pr * 2, height: pr * 2)),
                with: .color(Color(red: 0.06, green: 0.05, blue: 0.07))
            )
            let hr = max(0.8, pr * 0.5)
            eyeCtx.fill(
                Path(ellipseIn: CGRect(x: ic.x - pr * 0.4 - hr / 2, y: ic.y - pr * 0.5 - hr / 2, width: hr, height: hr)),
                with: .color(.white.opacity(0.92))
            )
        }

        // Upper lash line hugging the aperture top, so the eye sits in a lid.
        if openness > 0.08 {
            var lash = Path()
            lash.move(to: CGPoint(x: c.x - ew / 2, y: c.y - apertureH / 2))
            lash.addQuadCurve(
                to: CGPoint(x: c.x + ew / 2, y: c.y - apertureH / 2),
                control: CGPoint(x: c.x, y: c.y - apertureH / 2 - eh * 0.10)
            )
            ctx.stroke(lash, with: .color(Color(red: 0.16, green: 0.12, blue: 0.12).opacity(0.85)), lineWidth: max(0.8, eh * 0.10))
        }

        // Lower lid: a soft shadow seats the eye in its socket instead of
        // floating on the skin.
        if openness > 0.2 {
            var lid = Path()
            lid.move(to: CGPoint(x: c.x - ew / 2, y: c.y + apertureH / 2))
            lid.addQuadCurve(
                to: CGPoint(x: c.x + ew / 2, y: c.y + apertureH / 2),
                control: CGPoint(x: c.x, y: c.y + apertureH / 2 + eh * 0.06)
            )
            ctx.stroke(lid, with: .color(Color(red: 0.30, green: 0.20, blue: 0.18).opacity(0.35)), lineWidth: max(0.6, eh * 0.06))
        }

        // Error: crossed-out eyes.
        if dizzy > 0.5 {
            var x1 = Path()
            x1.move(to: CGPoint(x: c.x - ew * 0.32, y: c.y - eh * 0.32))
            x1.addLine(to: CGPoint(x: c.x + ew * 0.32, y: c.y + eh * 0.32))
            var x2 = Path()
            x2.move(to: CGPoint(x: c.x + ew * 0.32, y: c.y - eh * 0.32))
            x2.addLine(to: CGPoint(x: c.x - ew * 0.32, y: c.y + eh * 0.32))
            let w = max(1.4, eh * 0.22)
            ctx.stroke(x1, with: .color(.black.opacity(0.9)), lineWidth: w)
            ctx.stroke(x2, with: .color(.black.opacity(0.9)), lineWidth: w)
        }
    }

    /// The compact Echo presence draws the SAME real mirrored equalizer as the
    /// full-screen surface (`EchoformRendererView.drawBars`), scaled into the
    /// character-sized head region: the analyzed per-band spectrum
    /// (`pose.audioBars`) folded through `EchoEqualizerBars` into mirrored bar
    /// heights, identical in behavior to full screen, just fewer bars so it
    /// reads at this size. When no audio is playing the bars settle into the
    /// deterministic resting arch (`EchoEqualizerBars.restingProfile`), and a
    /// playing-but-silent frame flattens them from the real all-zero spectrum,
    /// so Echo never invents motion at rest.
    private static let echoBarCount = 21

    private func drawEchoBars(
        in head: GraphicsContext,
        pose: AttachePose,
        p: (CGFloat, CGFloat) -> CGPoint,
        s: CGFloat
    ) {
        let count = Self.echoBarCount
        let heights = pose.audioBars.isEmpty
            ? EchoEqualizerBars.restingProfile(count: count)
            : EchoEqualizerBars.barHeights(from: pose.audioBars, count: count)
        let energy = min(1, max(0, pose.mouthOpen))
        let errorFlicker = pose.dizzy > 0.01
            ? 0.45 + 0.55 * abs(sin(pose.overheadPhase * 8 * .pi))
            : 1
        let worryCompression = 1 - pose.browWorry * 0.38
        let center = p(120, 112)

        let halo = Path(ellipseIn: CGRect(
            x: center.x - 48 * s,
            y: center.y - 48 * s,
            width: 96 * s,
            height: 96 * s
        ))
        head.fill(halo, with: .color(arcColor.opacity(0.05 + 0.10 * energy)))

        let spacing = 96.0 / Double(count)
        let width = CGFloat(spacing * 0.68) * s
        for (index, band) in heights.enumerated() {
            let normalizedHeight = band * worryCompression
            let height = max(4, 78 * normalizedHeight) * s
            let x = center.x + CGFloat(Double(index) - Double(count - 1) / 2) * CGFloat(spacing) * s
            let bar = Path(
                roundedRect: CGRect(
                    x: x - width / 2,
                    y: center.y - height / 2,
                    width: width,
                    height: height
                ),
                cornerRadius: width / 2
            )
            head.fill(
                bar,
                with: .color(arcColor.opacity((0.42 + 0.5 * band) * errorFlicker))
            )
        }
    }

    /// Volt (INF-283): a squared-off robot head. Eyes are LED bars whose
    /// height is `eyeOpenness`, the mouth is an equalizer that dances with
    /// `mouthOpen`, worry tilts the LEDs, dizzy crosses them out, and the
    /// antenna bulb carries the cheek glow.
    private func drawRobotFace(in head: GraphicsContext, pose: AttachePose, p: (CGFloat, CGFloat) -> CGPoint, s: CGFloat) {
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
        let glowOpacity = min(1, max(0, pose.cheekGlow / 0.6))
        head.fill(bulb, with: .color(AttacheMascotMark.cheekColor.opacity(glowOpacity)))

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

        for boltX in [90.5, 141.5] {
            let bolt = Path(ellipseIn: CGRect(
                x: p(boltX, 117).x, y: p(boltX, 117).y, width: 4 * s, height: 4 * s
            ))
            head.fill(bolt, with: .color(AttacheMascotMark.cheekColor.opacity(glowOpacity)))
        }

        if pose.mouthOpen < 0.15 {
            let halfWidth = (6 + 4.8 * pose.smile) * s
            let mouth = Path(
                roundedRect: CGRect(
                    x: p(120, 131).x - halfWidth, y: p(120, 131).y,
                    width: halfWidth * 2, height: 3.5 * s
                ),
                cornerRadius: 1.75 * s
            )
            face.fill(mouth, with: .color(screen))
        } else {
            // The refined mouth equalizer draws the REAL analyzed spectrum
            // (`pose.audioBars`) folded through the shared `EchoEqualizerBars`
            // mapping, at a legible mouth-sized band count (7 mirrored bars).
            // `pose.mouthOpen` stays the overall loudness envelope so the mouth
            // still opens and closes; the per-band shape is the actual audio.
            // With no spectrum available (a paused frame) the bars fall back to
            // a fixed symmetric rest shape, deterministic and clock-free. This
            // branch is only reached above the neutral threshold, so the locked
            // neutral pose (mouthOpen 0) is untouched.
            //
            // Seven bars keep the current centered footprint: left edges run
            // 108 to 135.6 (spacing 4.6, width 3.1, rounded caps), so the mouth
            // stays centered on the steel plate and never overflows it.
            let bands = EchoCharacterMouth.bandShapes(from: pose.audioBars)
            let barWidth = 3.1 * s
            let barCorner = 1.55 * s
            func barRect(_ bar: Int) -> CGRect {
                let x = 108.0 + Double(bar) * 4.6
                let height = (3 + 12 * pose.mouthOpen * bands[bar]) * s
                return CGRect(
                    x: p(CGFloat(x), 134).x, y: p(CGFloat(x), 134).y - height / 2,
                    width: barWidth, height: height
                )
            }

            // Faint brand under-glow behind the dark bars, so the mouth reads as
            // lit from within rather than neon. The glow is a FIXED brand accent
            // (`EchoCharacterMouth.brandGlow`), deliberately NOT the LED/eye
            // color and NOT derived from any pose or eye input, so a future
            // custom face never couples the mouth glow to the eyes. It is part
            // of the audio-content rendering, not decorative clock motion, so it
            // stays under Reduce Motion. Louder bars glow a touch more.
            face.drawLayer { glow in
                glow.addFilter(.blur(radius: 2.5 * s))
                for bar in 0..<EchoCharacterMouth.bandCount {
                    let level = bands[bar]
                    let rect = Path(roundedRect: barRect(bar), cornerRadius: barCorner)
                    glow.fill(
                        rect,
                        with: .color(EchoCharacterMouth.brandGlow.opacity(0.35 + 0.15 * level))
                    )
                }
            }

            for bar in 0..<EchoCharacterMouth.bandCount {
                let slot = Path(roundedRect: barRect(bar), cornerRadius: barCorner)
                face.fill(slot, with: .color(screen))
            }
        }
    }

    /// Colt (INF-288, mustache INF-291; robot unification 2026-07-17): the same
    /// robot head as Attaché (steel plate, LED eyes, equalizer mouth that reacts
    /// to `mouthOpen`) wearing the cowboy kit. The mustache droops below the
    /// upper lip so the animated mouth stays visible and speaks; the bandana
    /// sits at the collar and the hat, drawn last, covers where the antenna
    /// would be. Everything is in the `head` layer, so the hat tilts with
    /// `headTilt`.
    private func drawCowboyFace(in head: GraphicsContext, pose: AttachePose, p: (CGFloat, CGFloat) -> CGPoint, s: CGFloat) {
        let hatBrown = Color(red: 0.45, green: 0.31, blue: 0.19)
        let hatBand = Color(red: 0.30, green: 0.20, blue: 0.12)
        let bandanaRed = Color(red: 0.82, green: 0.24, blue: 0.24)
        let stache = Color(red: 0.34, green: 0.22, blue: 0.13)

        // The full robot head, including the animated LED-equalizer mouth.
        drawRobotFace(in: head, pose: pose, p: p, s: s)

        // Neckerchief at the collar: a red band across the bottom of the face
        // plate with a knot dropping below the chin.
        let kerchief = Path(
            roundedRect: CGRect(x: p(99, 141).x, y: p(99, 141).y, width: 42 * s, height: 9 * s),
            cornerRadius: 3 * s
        )
        head.fill(kerchief, with: .color(bandanaRed))
        var knot = Path()
        knot.move(to: p(113, 148))
        knot.addLine(to: p(127, 148))
        knot.addLine(to: p(120, 158))
        knot.closeSubpath()
        head.fill(knot, with: .color(bandanaRed))

        // Droopy handlebar mustache: two halves that start at the center of the
        // upper lip (y 128) and fall downward beside the mouth, leaving the
        // equalizer bars (x 106...134, growing down from y 134) clear.
        for mirror in [1.0, -1.0] {
            let mx: (CGFloat) -> CGFloat = { 120 + CGFloat(mirror) * ($0 - 120) }
            var half = Path()
            half.move(to: p(120, 129.5))
            half.addCurve(
                to: p(mx(107), 129),
                control1: p(mx(116.5), 127),
                control2: p(mx(111), 126.8)
            )
            half.addCurve(
                to: p(mx(103), 138),
                control1: p(mx(104), 130.7),
                control2: p(mx(102.6), 134.4)
            )
            half.addCurve(
                to: p(120, 131.8),
                control1: p(mx(107.4), 133.2),
                control2: p(mx(113.4), 131.3)
            )
            half.closeSubpath()
            head.fill(half, with: .color(stache))
        }

        // The hat, last, so its brim covers the forehead and antenna.
        let brim = Path(ellipseIn: CGRect(
            x: p(75, 77).x, y: p(75, 77).y, width: 90 * s, height: 14 * s
        ))
        head.fill(brim, with: .color(hatBrown))
        let crown = Path(
            roundedRect: CGRect(x: p(100, 55).x, y: p(100, 55).y, width: 40 * s, height: 28 * s),
            cornerRadius: 11 * s
        )
        head.fill(crown, with: .color(hatBrown))
        let band = Path(
            roundedRect: CGRect(x: p(100, 74).x, y: p(100, 74).y, width: 40 * s, height: 6 * s),
            cornerRadius: 2 * s
        )
        head.fill(band, with: .color(hatBand))
    }

}
