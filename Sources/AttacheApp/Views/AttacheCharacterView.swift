import AppKit
import AttacheCore
import SwiftUI

/// Maps the Attaché activity contract to pose targets for the Attaché rig: the pure
/// half of the character renderer (unit-tested), consumed by `AttacheCharacterMotor`
/// which layers time on top. Values come from the state table in
/// `design/attache-animation-spec.md`; retune there first, then here.
///
/// The full choreography map (INF-271), everything retunable in one place:
///
/// Continuous phases (this file, `targets(for:)`):
///   sleeping        eyes closed, arcs 0.25, breathe 4.5 s, no blink
///   idle            the logo at rest, blink loop, breathe 3.2 s
///   agentThinking   head tilts toward the active agent, crown shows thinking
///   toolRunning     focused eyes, crown shows the active tool and elapsed time
///   agentResponding eyes widen and arcs ripple inward
///   speaking        mouth on audio.level, sway, arcs ripple outward,
///                   focused session remains visible in the fleet ring
///   paused          held small mouth, arcs 0.5
///   blockedOnUser   worry brows, pale cheeks, amber needs-you mote pulses
///   error           dizzy X eyes, arcs flicker
///
/// One-shot moments (`AttacheCharacterMotor.applyMoment`):
///   celebrate    1.2 s hop with squash and agent-colored confetti
///   cardArrived  0.8 s glance and reaction
///   drowsy       2.5 s eye droop and head nod
///   Moments queue while blocked/speaking/paused own the stage and drop
///   after `AttacheActivityMoment.shelfLife` (8 s).
///
/// Upstream rules the character relies on:
///   dwell        `AttacheActivityDamper` in AttacheCore: ambient phases
///                hold 1.2 s, tool kinds hold 2 s, signal phases instant
///   priority     `AppModel.currentActivitySignals`: exact asks beat soft
///                waits, most recent transition wins within a tier, and the
///                fleet motes always show whose event won
///   agent map    claude = rust, none = green, codex = blue
enum AttacheCharacterChoreography {
    struct Targets: Equatable {
        var pose = AttachePose()
        /// Breathing period in seconds; arousal maps to tempo.
        var breathePeriod: Double = 3.2
        /// Which agent the phase belongs to (0 Claude, 1 other, 2 Codex).
        var activeAgentIndex = 1
        /// The active agent's progress indicator cycles while true.
        var dotsCycling = false
        /// Tool flavor for the procedural vibration layer.
        var toolKind: AttacheToolKind?
        /// Mouth follows the audio level instead of the pose target.
        var mouthTracksAudio = false
        /// Idle-style blinking is allowed (suppressed asleep or dizzy).
        var blinkAllowed = true
        /// The active agent asks urgently for attention.
        var urgentJumps = false
        /// Arc opacity flickers (error).
        var arcFlicker = false
        /// Body sways with speech.
        var sways = false
    }

    /// Stable agent order used for color and transient reaction arrays.
    static func agentIndex(for agent: AttacheAgentIdentity) -> Int {
        switch agent {
        case .claude: return 0
        case .none: return 1
        case .codex: return 2
        }
    }

    /// The session lanes around the head anatomy (INF-280), in design units,
    /// centered on the head after `AttacheCharacterFigure.headAnatomyDrop`. Two
    /// circular tracks (INF-286): ordinary working and quiet motes orbit the
    /// INNER track, close to the character and safely under the crown; the motes
    /// that carry meaning for the user (focused, needs-you, finished) live
    /// on the OUTER track where they stand apart.
    static let ringCenter = CGPoint(x: 120, y: 138)
    static let ringRadii = CGSize(width: 52, height: 52)
    static let outerRingRadii = CGSize(width: 78, height: 78)
    /// The outer track keeps a dead zone under the crown (the totem and arc
    /// span, -128 to -52 degrees) so a pinned mote can never sit on a phase
    /// indicator; drags clamp to the nearest edge.
    static let crownDeadZone = (-2.234, -0.907)
    /// Where the focused mote rests until the user drags it: bottom center,
    /// right in front of the character's gaze.
    static let defaultFocusAngle = Double.pi / 2

    /// A point on the inner orbit track.
    static func ringPoint(angle: Double) -> CGPoint {
        CGPoint(
            x: ringCenter.x + CGFloat(cos(angle)) * ringRadii.width,
            y: ringCenter.y + CGFloat(sin(angle)) * ringRadii.height
        )
    }

    /// A point on the outer track (focused, needs-you, finished).
    static func outerRingPoint(angle: Double) -> CGPoint {
        CGPoint(
            x: ringCenter.x + CGFloat(cos(angle)) * outerRingRadii.width,
            y: ringCenter.y + CGFloat(sin(angle)) * outerRingRadii.height
        )
    }

    /// Clamps an outer-track angle out of the crown dead zone, to the
    /// nearest edge.
    static func clampToOuterTrack(_ angle: Double) -> Double {
        var wrapped = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if wrapped > .pi { wrapped -= 2 * .pi }
        if wrapped < -.pi { wrapped += 2 * .pi }
        let (lower, upper) = crownDeadZone
        guard wrapped > lower, wrapped < upper else { return wrapped }
        return (wrapped - lower) < (upper - wrapped) ? lower : upper
    }

    /// Where an agent's quiet sessions settle: a cluster on the ring's
    /// bottom arc, Claude to the left of the focused rest spot, Codex to
    /// the right, others straight down, spreading outward per slot.
    static func parkAngle(agent: AttacheAgentIdentity, slot: Int) -> Double {
        let side: Double
        switch agent {
        case .claude: side = 1
        case .codex: side = -1
        case .none: side = 0.5
        }
        let base = Double.pi / 2 + side * 0.55
        return base + side * Double(slot) * 0.22
    }

    /// - Parameter isCaptioning: Karaoke captions are on screen for the
    ///   current speaking turn (INF-358 check 1). The user's attention is on
    ///   the caption text, so the speaking phase's ambient flourishes (arc
    ///   glow, ripple, body sway) damp to a minimal, breathing-level tier;
    ///   the mouth still tracks audio since that is the informative signal,
    ///   not ambient motion. Ignored outside `.speaking`.
    static func targets(for activity: AttacheActivityState, isCaptioning: Bool = false) -> Targets {
        var targets = Targets()
        let active = agentIndex(for: activity.activeAgent)
        targets.activeAgentIndex = active

        func spotlight(_ activeBrightness: Double, others: Double, lift: CGFloat = 0) {
            for index in 0..<3 {
                targets.pose.agentSignals[index].brightness = index == active ? activeBrightness : others
            }
            targets.pose.agentSignals[active].lift = lift
        }

        switch activity.phase {
        case .sleeping:
            targets.pose.overhead = .sleeping
            targets.pose.eyeOpenness = 0
            targets.pose.smile = 0.6
            targets.pose.cheekGlow = 0.45
            targets.pose.arcGlow = 0.25
            targets.breathePeriod = 4.5
            targets.blinkAllowed = false
            for index in 0..<3 { targets.pose.agentSignals[index].brightness = 0.55 }

        case .idle:
            targets.pose.overhead = .none
            targets.breathePeriod = 3.2

        case .agentThinking:
            targets.pose.overhead = .thinking
            targets.pose.headTilt = active == 0 ? -6 : (active == 2 ? 6 : 0)
            targets.pose.gaze = CGSize(width: active == 0 ? -2 : (active == 2 ? 2 : 0), height: -1)
            targets.pose.smile = 0.45
            targets.pose.arcGlow = 0.8
            targets.breathePeriod = 2.8
            targets.dotsCycling = true
            spotlight(1, others: 0.45, lift: 8)

        case .toolRunning:
            targets.pose.overhead = .tool
            targets.pose.eyeOpenness = 0.75
            targets.pose.smile = 0.6
            targets.pose.arcGlow = 0.8
            targets.breathePeriod = 2.4
            targets.dotsCycling = true
            targets.toolKind = activity.toolKind ?? .other
            spotlight(1, others: 0.45, lift: 4)

        case .agentResponding:
            targets.pose.overhead = .preparingAudio
            targets.pose.gaze = CGSize(width: 0, height: -1.5)
            targets.pose.smile = 0.8
            targets.pose.arcGlow = 0.85
            targets.pose.arcRipple = -1
            targets.breathePeriod = 2.8
            spotlight(1, others: 0.45, lift: 12)

        case .speaking:
            targets.pose.overhead = .arcs
            targets.mouthTracksAudio = true
            targets.breathePeriod = 2.8
            spotlight(1, others: 0.4)
            if isCaptioning {
                // Breathing-level tier: the caption text owns the user's
                // attention, so the ambient arc/sway flourishes damp down.
                targets.pose.arcGlow = 0.35
                targets.pose.arcRipple = 0.15
                targets.sways = false
            } else {
                targets.pose.arcGlow = 1
                targets.pose.arcRipple = 1
                targets.sways = true
            }

        case .paused:
            targets.pose.overhead = .paused
            targets.pose.eyeOpenness = 0.85
            targets.pose.mouthOpen = 0.18
            targets.pose.arcGlow = 0.5
            for index in 0..<3 { targets.pose.agentSignals[index].brightness = 0.75 }

        case .blockedOnUser:
            targets.pose.overhead = .none
            targets.pose.browWorry = 1
            targets.pose.cheekGlow = 0.2
            targets.pose.smile = 0.3
            targets.pose.arcGlow = 0.15
            targets.urgentJumps = true
            targets.dotsCycling = true
            spotlight(1, others: 0.3, lift: 6)

        case .error:
            targets.pose.overhead = .none
            targets.pose.dizzy = 1
            targets.pose.mouthOpen = 0.3
            targets.pose.headTilt = 4
            targets.pose.arcGlow = 0.4
            targets.arcFlicker = true
            targets.blinkAllowed = false
            spotlight(0.8, others: 0.5, lift: -4)
        }
        return targets
    }
}

/// Which delights are enabled (INF-273). Delights only ever play over the
/// calm phases (idle, sleeping); speaking, blocked, paused, and error always
/// own the stage untouched.
struct CharacterDelights: Equatable {
    var typesAlong = true
    var rareIdles = false
    var hoverReacts = false

    static let none = CharacterDelights(typesAlong: false, rareIdles: false, hoverReacts: false)
}

/// Integrates spring motion, blinking, and the procedural loops between the
/// choreography's pose targets and the drawn frame. Plain fields only (no
/// published state): the surrounding `TimelineView` already redraws every
/// frame, so the motor never needs to invalidate anything itself.
final class AttacheCharacterMotor: ObservableObject {
    private struct Spring {
        var value: Double
        var velocity: Double = 0

        /// Semi-implicit Euler, substepped to 60 Hz minimum: at the idle
        /// cadence (12 fps, dt about 0.083) a single step is unstable for the
        /// snappy and standard responses (the step matrix grows about 1.8x
        /// per frame) and every spring visibly exploded. Substeps keep
        /// dt * omega well inside the stable region at any display rate.
        mutating func step(toward target: Double, dt: Double, response: Double, damping: Double) {
            let omega = 2 * Double.pi / max(0.05, response)
            let substeps = max(1, Int(ceil(dt / (1.0 / 60.0))))
            let h = dt / Double(substeps)
            for _ in 0..<substeps {
                velocity += (-(omega * omega) * (value - target) - 2 * damping * omega * velocity) * h
                value += velocity * h
            }
        }

        mutating func approach(_ target: Double, dt: Double, window: Double = 0.25) {
            value += (target - value) * min(1, dt / window)
            velocity = 0
        }
    }

    // The spec's spring vocabulary.
    private static let standard = (response: 0.35, damping: 0.78)
    private static let snappy = (response: 0.22, damping: 0.70)
    private static let soft = (response: 0.60, damping: 0.90)

    private var eyeOpenness = Spring(value: 1)
    private var browWorry = Spring(value: 0)
    private var dizzy = Spring(value: 0)
    private var smile = Spring(value: 1)
    private var cheekGlow = Spring(value: 0.6)
    private var headTilt = Spring(value: 0)
    private var gazeX = Spring(value: 0)
    private var gazeY = Spring(value: 0)
    private var arcGlow = Spring(value: 1)
    private var arcRipple = Spring(value: 0)
    private var mouthOpen = Spring(value: 0)
    private var reactionLift = [Spring(value: 0), Spring(value: 0), Spring(value: 0)]
    private var reactionBrightness = [Spring(value: 1), Spring(value: 1), Spring(value: 1)]

    private var lastTick: TimeInterval?
    private var nextBlinkAt: TimeInterval = 3
    private var blinkStartedAt: TimeInterval?
    private var doubleBlinkQueued = false
    private var seenMomentIDs: Set<UUID> = []
    private var queuedMoments: [AttacheActivityMoment] = []
    private var activeMoment: (moment: AttacheActivityMoment, startedAt: TimeInterval)?
    private var nextRareIdleAt: TimeInterval?
    private var activeRareIdle: (juggles: Bool, startedAt: TimeInterval)?
    private var clickBouncedAt: TimeInterval?
    /// Rare-idle cadence in seconds; `ATTACHE_CHARACTER_RARE_IDLE_SECONDS` shrinks
    /// it so the reel and QA runs never wait minutes for a moment whose whole
    /// point is rarity.
    private let rareIdleInterval: ClosedRange<Double> = {
        if let raw = ProcessInfo.processInfo.environment["ATTACHE_CHARACTER_RARE_IDLE_SECONDS"]
            ?? ProcessInfo.processInfo.environment["ATTACHE_PET_RARE_IDLE_SECONDS"],
           let seconds = Double(raw), seconds > 0 {
            return seconds...(seconds * 1.5)
        }
        return 180...420
    }()

    /// The hover-reaction click: a quick happy bounce, played over the calm
    /// phases only.
    func noteClick(at date: Date) {
        clickBouncedAt = date.timeIntervalSinceReferenceDate
    }

    func pose(
        at date: Date,
        activity: AttacheActivityState,
        moment: AttacheActivityMoment? = nil,
        delights: CharacterDelights = .none,
        hoverGaze: CGSize? = nil,
        reduceMotion: Bool,
        isCaptioning: Bool = false
    ) -> AttachePose {
        let now = date.timeIntervalSinceReferenceDate
        let dt = min(1.0 / 15.0, max(0, now - (lastTick ?? now)))
        lastTick = now

        if let moment, !seenMomentIDs.contains(moment.id) {
            seenMomentIDs.insert(moment.id)
            queuedMoments.append(moment)
        }

        let targets = AttacheCharacterChoreography.targets(for: activity, isCaptioning: isCaptioning)
        var pose = targets.pose

        func drive(_ spring: inout Spring, toward target: Double, _ params: (response: Double, damping: Double)) -> Double {
            if reduceMotion {
                spring.approach(target, dt: dt)
            } else {
                spring.step(toward: target, dt: dt, response: params.response, damping: params.damping)
            }
            return spring.value
        }

        pose.eyeOpenness = drive(&eyeOpenness, toward: targets.pose.eyeOpenness, Self.standard)
        pose.browWorry = drive(&browWorry, toward: targets.pose.browWorry, Self.standard)
        pose.dizzy = drive(&dizzy, toward: targets.pose.dizzy, Self.standard)
        pose.smile = drive(&smile, toward: targets.pose.smile, Self.standard)
        pose.cheekGlow = drive(&cheekGlow, toward: targets.pose.cheekGlow, Self.soft)
        pose.headTilt = drive(&headTilt, toward: targets.pose.headTilt, Self.standard)
        pose.gaze = CGSize(
            width: drive(&gazeX, toward: targets.pose.gaze.width, Self.standard),
            height: drive(&gazeY, toward: targets.pose.gaze.height, Self.standard)
        )
        pose.arcGlow = drive(&arcGlow, toward: targets.pose.arcGlow, Self.soft)
        pose.arcRipple = drive(&arcRipple, toward: targets.pose.arcRipple, Self.soft)
        pose.overhead = targets.pose.overhead
        pose.overheadPhase = (now / 2.4).truncatingRemainder(dividingBy: 1)
        if targets.pose.overhead != lastOverhead {
            lastOverhead = targets.pose.overhead
            overheadStartedAt = now
        }
        pose.overheadSeconds = Int(now - (overheadStartedAt ?? now))
        for index in 0..<3 {
            pose.agentSignals[index].lift = CGFloat(drive(&reactionLift[index], toward: Double(targets.pose.agentSignals[index].lift), Self.snappy))
            pose.agentSignals[index].brightness = drive(&reactionBrightness[index], toward: targets.pose.agentSignals[index].brightness, Self.soft)
        }

        if targets.mouthTracksAudio {
            let level = Double(activity.audio.level)
            let liveliness = reduceMotion ? 0 : 0.08 * sin(now * 13.7)
            let open = pow(min(1, level * 3.2), 0.8) + liveliness
            pose.mouthOpen = min(1, max(0, open))
            mouthOpen.value = pose.mouthOpen
            mouthOpen.velocity = 0
        } else {
            pose.mouthOpen = drive(&mouthOpen, toward: targets.pose.mouthOpen, Self.standard)
        }

        applyLoops(to: &pose, targets: targets, now: now, reduceMotion: reduceMotion)
        applyDelights(
            to: &pose,
            phase: activity.phase,
            userTyping: activity.userTyping,
            delights: delights,
            hoverGaze: hoverGaze,
            now: now,
            reduceMotion: reduceMotion
        )
        advanceMoment(now: now, date: date, phase: activity.phase)
        if let active = activeMoment {
            applyMoment(active.moment, startedAt: active.startedAt, to: &pose, now: now, reduceMotion: reduceMotion)
        }
        // Sustained, focus-tied compaction: ramp toward full over ~42s while the
        // focused session compacts, then ease back when it clears. Overrides the
        // crown so it is the only thing shown, as agreed.
        let compactionTarget = activity.compactingSince.map {
            min(1, max(0, (now - $0.timeIntervalSinceReferenceDate) / 42))
        } ?? 0
        compactionValue += (compactionTarget - compactionValue) * 0.12
        if compactionValue > 0.02 {
            pose.compaction = compactionValue
            pose.overhead = .compacting
            pose.overheadSeconds = Int(max(0, now - (activity.compactingSince?.timeIntervalSinceReferenceDate ?? now)))
        }
        applyFleetGaze(to: &pose, activity: activity, now: now, reduceMotion: reduceMotion)
        return pose
    }

    /// The stare and the glance (INF-280). With a focused session pinned on
    /// the ring the eyes rest on it; a mote that just turned needs-you or
    /// finished steals a short look (worried brows for a question, a warm
    /// cheek glow for a check) before the gaze returns.
    private func applyFleetGaze(
        to pose: inout AttachePose,
        activity: AttacheActivityState,
        now: TimeInterval,
        reduceMotion: Bool
    ) {
        func gazeTarget(toward point: CGPoint) -> CGSize {
            CGSize(
                width: (point.x - AttacheCharacterChoreography.ringCenter.x)
                    / AttacheCharacterChoreography.ringRadii.width * 3,
                height: (point.y - AttacheCharacterChoreography.ringCenter.y)
                    / AttacheCharacterChoreography.ringRadii.height * 3
            )
        }

        var desired: CGSize?
        if let glance {
            if now < glance.until {
                desired = gazeTarget(toward: glance.target)
                if glance.isGood {
                    pose.cheekGlow = min(1, pose.cheekGlow + 0.25)
                } else {
                    pose.browWorry = max(pose.browWorry, 0.45)
                }
            } else {
                self.glance = nil
            }
        }
        if desired == nil, activity.fleet.contains(where: \.isFocused),
           let position = focusedMotePosition {
            desired = gazeTarget(toward: position)
        }
        guard let desired else {
            fleetGaze = .zero
            return
        }
        if reduceMotion {
            fleetGaze = desired
        } else {
            fleetGaze.width += (desired.width - fleetGaze.width) * 0.3
            fleetGaze.height += (desired.height - fleetGaze.height) * 0.3
        }
        pose.gaze = fleetGaze
    }

    /// The delight layer (INF-273), strictly over the calm phases: signal
    /// phases (speaking, blocked, paused, error) and the working phases skip
    /// it entirely, so delights can never mask what an agent is doing.
    private func applyDelights(
        to pose: inout AttachePose,
        phase: AttacheActivityPhase,
        userTyping: Bool,
        delights: CharacterDelights,
        hoverGaze: CGSize?,
        now: TimeInterval,
        reduceMotion: Bool
    ) {
        guard phase == .idle || phase == .sleeping else {
            activeRareIdle = nil
            return
        }

        if delights.typesAlong, userTyping, !reduceMotion {
            // Head anatomy (INF-280): with no attache to tap, the character types
            // along with a light bounce, eyes dipped toward the keyboard.
            let tap = max(0, sin(now * 2 * .pi * 2.6))
            pose.hop += CGFloat(1.1 * tap)
            pose.gaze.height += 1.6
            if phase == .sleeping {
                pose.eyeOpenness = max(pose.eyeOpenness, 0.55)
            }
        }

        if delights.rareIdles, !reduceMotion {
            if nextRareIdleAt == nil {
                nextRareIdleAt = now + Double.random(in: rareIdleInterval)
            }
            if activeRareIdle == nil, let next = nextRareIdleAt, now >= next {
                activeRareIdle = (juggles: Bool.random(), startedAt: now)
                nextRareIdleAt = now + Double.random(in: rareIdleInterval)
            }
            if let idle = activeRareIdle {
                let t = now - idle.startedAt
                if t >= 3 {
                    activeRareIdle = nil
                } else if idle.juggles {
                    for index in 0..<3 {
                        let wave = max(0, sin(2 * .pi * (t * 1.1) - Double(index) * 0.9))
                        pose.agentSignals[index].lift += CGFloat(6 * wave)
                    }
                    pose.hop += CGFloat(2 * max(0, sin(2 * .pi * t * 1.1)))
                } else {
                    pose.gaze.width += CGFloat(3 * sin(t / 3 * 2 * .pi))
                    pose.headTilt += 5 * sin(t / 3 * 2 * .pi)
                }
            }
        } else {
            activeRareIdle = nil
        }

        if delights.hoverReacts {
            if let hoverGaze {
                pose.gaze.width += hoverGaze.width
                pose.gaze.height += hoverGaze.height
                if phase == .sleeping {
                    pose.eyeOpenness = max(pose.eyeOpenness, 0.3)
                }
            }
            if let bouncedAt = clickBouncedAt {
                let t = now - bouncedAt
                if t < 0.8 {
                    pose.smile = 1
                    pose.cheekGlow = max(pose.cheekGlow, 0.8)
                    if !reduceMotion {
                        pose.hop += CGFloat(8 * sin(min(1, t / 0.8) * .pi))
                    }
                } else {
                    clickBouncedAt = nil
                }
            }
        }
    }

    /// One-shot scheduling (INF-271): moments queue while a signal phase
    /// (blocked, speaking, paused) owns the stage, play one at a time
    /// otherwise, and drop once past their shelf life so a stale celebration
    /// never fires minutes late.
    private func advanceMoment(now: TimeInterval, date: Date, phase: AttacheActivityPhase) {
        if let active = activeMoment, now - active.startedAt >= Self.momentDuration(active.moment.kind) {
            activeMoment = nil
        }
        guard activeMoment == nil else { return }
        queuedMoments.removeAll { date.timeIntervalSince($0.at) > AttacheActivityMoment.shelfLife }
        // Needs-you no longer owns the stage: the character keeps reacting and the
        // question-mark badge carries the reminder, so a moment can play over it.
        let stageIsOwned = phase == .speaking || phase == .paused
        guard !stageIsOwned, !queuedMoments.isEmpty else { return }
        let next = queuedMoments.removeFirst()
        activeMoment = (next, now)
    }

    private static func momentDuration(_ kind: AttacheActivityMoment.Kind) -> TimeInterval {
        switch kind {
        case .celebrate: return 1.2
        case .cardArrived: return 0.8
        case .drowsy: return 2.5
        case .needsYou: return 1.1
        case .errored: return 1.6
        case .configuring: return 2.6
        case .compacting: return 3.0
        case .greet: return 1.2
        case .farewell: return 1.6
        case .permissionAsk: return 2.2
        case .permissionDenied: return 1.3
        }
    }

    private func applyMoment(
        _ moment: AttacheActivityMoment,
        startedAt: TimeInterval,
        to pose: inout AttachePose,
        now: TimeInterval,
        reduceMotion: Bool
    ) {
        let duration = Self.momentDuration(moment.kind)
        let progress = min(1, max(0, (now - startedAt) / duration))
        let agentIndex = AttacheCharacterChoreography.agentIndex(for: moment.agent)
        switch moment.kind {
        case .celebrate:
            pose.cheekGlow = max(pose.cheekGlow, 0.95 * sin(progress * .pi) + 0.6 * (1 - sin(progress * .pi)))
            pose.smile = 1
            pose.agentSignals[agentIndex].pop = progress
            pose.agentSignals[agentIndex].brightness = 1
            if !reduceMotion {
                pose.hop = CGFloat(16 * sin(min(1, progress / 0.7) * .pi))
                pose.squash = -0.4 * sin(min(1, progress / 0.7) * .pi)
                pose.arcRipple = 1
                pose.arcPhase = now * 2.6
            }
        case .cardArrived:
            pose.agentSignals[agentIndex].brightness = 1
            pose.agentSignals[agentIndex].dotPhase = nil
            if !reduceMotion {
                pose.agentSignals[agentIndex].lift += CGFloat(8 * sin(progress * .pi))
                pose.agentSignals[agentIndex].tilt += 6 * sin(progress * .pi * 2)
            }
        case .drowsy:
            pose.eyeOpenness *= 1 - 0.65 * sin(progress * .pi)
            if !reduceMotion {
                pose.headTilt += 4 * sin(progress * .pi)
            }
        case .needsYou:
            // A session just asked for you: a quick startle perk (eyes widen, a
            // small bounce, brief worry), then the character moves on. The lasting
            // reminder is the pinned question-mark badge in the ring.
            let pulse = sin(progress * .pi)
            pose.eyeOpenness = max(pose.eyeOpenness, 1 + 0.18 * pulse)
            pose.browWorry = max(pose.browWorry, 0.5 * pulse)
            if !reduceMotion {
                pose.hop = CGFloat(7 * sin(min(1, progress / 0.4) * .pi))
                pose.arcRipple = 0.5 * pulse
                pose.arcPhase = now * 2.6
            }
        case .errored:
            // A turn died on an API error: eyes cross to dizzy X's, brows worry,
            // and a quick shudder that eases out.
            let pulse = sin(progress * .pi)
            pose.dizzy = max(pose.dizzy, pulse)
            pose.browWorry = max(pose.browWorry, 0.85 * pulse)
            pose.smile = 1 - 0.8 * pulse
            if !reduceMotion {
                pose.headTilt += 5 * sin(now * 22) * (1 - progress) * pulse
            }
        case .configuring:
            // Being set up: eyes roll up, half-lidded, scanning side to side.
            let hold = sin(min(1, progress / 0.25) * .pi / 2)
                * (progress > 0.82 ? (1 - progress) / 0.18 : 1)
            pose.overhead = .configuring
            pose.gaze.height = -3 * hold
            pose.eyeOpenness = 0.35 + 0.12 * (0.5 + 0.5 * sin(now * 9))
            if !reduceMotion {
                pose.gaze.width = 2.4 * sin(now * 3.2) * hold
            }
        case .compacting:
            // Context compaction: the whole head squishes hard, much flatter and
            // wider, then springs back. This one-shot is the preview; the real
            // one holds for the whole (up to ~45s) compaction with the crown pass.
            let squishStrength = sin(progress * .pi)
            pose.compaction = squishStrength
            pose.overhead = .compacting
            pose.hop = -4 * squishStrength
            if !reduceMotion {
                pose.browWorry = max(pose.browWorry, 0.35 * squishStrength)
                pose.eyeOpenness *= 1 - 0.4 * squishStrength
            }
        case .greet:
            // A session appeared: a hand rises beside the face and waves hello.
            pose.eyeOpenness = max(pose.eyeOpenness, 1)
            pose.smile = 1
            let greetRise = sin(min(1, progress / 0.3) * .pi / 2)
            let greetFade = progress > 0.78 ? (1 - progress) / 0.22 : 1
            pose.props = [AttacheProp(
                content: .emoji("👋"),
                position: CGPoint(x: 172, y: 104 - 16 * greetRise),
                size: 34,
                rotation: reduceMotion ? 0 : 20 * sin(now * 9),
                opacity: greetRise * greetFade
            )]
            if !reduceMotion {
                pose.hop = CGFloat(5 * sin(min(1, progress / 0.5) * .pi))
            }
        case .farewell:
            // A session ended: a hand waves goodbye, then lowers as the eyes dim.
            let byeRise = sin(min(1, progress / 0.28) * .pi / 2)
            let byeDrop = progress > 0.62 ? (progress - 0.62) / 0.38 : 0
            let byePresent = byeRise * (1 - byeDrop)
            pose.props = [AttacheProp(
                content: .emoji("👋"),
                position: CGPoint(x: 172, y: 104 - 14 * byePresent + 16 * byeDrop),
                size: 32,
                rotation: reduceMotion ? 0 : 16 * sin(now * 7),
                opacity: byePresent
            )]
            pose.eyeOpenness *= 1 - 0.55 * sin(progress * .pi)
            if !reduceMotion {
                pose.headTilt += 5 * sin(progress * .pi)
            }
        case .permissionAsk:
            // A green flag and a red flag rise beside the face to choose.
            let askRise = sin(min(1, progress / 0.3) * .pi / 2)
            let askFade = progress > 0.82 ? (1 - progress) / 0.18 : 1
            let bob = reduceMotion ? 0 : 3 * sin(now * 4)
            pose.props = [
                AttacheProp(content: .flag(red: false),
                            position: CGPoint(x: 62, y: 98 - 8 * askRise + bob),
                            size: 30, rotation: -10, opacity: askRise * askFade),
                AttacheProp(content: .flag(red: true),
                            position: CGPoint(x: 178, y: 98 - 8 * askRise - bob),
                            size: 30, rotation: 10, opacity: askRise * askFade)
            ]
            pose.browWorry = max(pose.browWorry, 0.3 * askRise)
        case .permissionDenied:
            // A tool was denied: a red flag pops up and shakes "no".
            let denyRise = sin(min(1, progress / 0.25) * .pi / 2)
            let denyFade = progress > 0.7 ? (1 - progress) / 0.3 : 1
            pose.props = [AttacheProp(
                content: .flag(red: true),
                position: CGPoint(x: 172, y: 96 - 10 * denyRise),
                size: 32,
                rotation: reduceMotion ? 8 : 16 * sin(now * 22),
                opacity: denyRise * denyFade
            )]
            pose.browWorry = max(pose.browWorry, 0.6 * denyRise)
            pose.smile = 1 - 0.6 * denyRise
            if !reduceMotion {
                pose.headTilt += 4 * sin(now * 20) * denyRise
            }
        }
    }

    private func applyLoops(to pose: inout AttachePose, targets: AttacheCharacterChoreography.Targets, now: TimeInterval, reduceMotion: Bool) {
        if !reduceMotion {
            pose.breathe = 0.5 + 0.5 * sin(now * 2 * .pi / targets.breathePeriod)
        }

        let blinkAllowed = targets.blinkAllowed && pose.mouthOpen < 0.5 && !reduceMotion
        pose.eyeOpenness *= blinkMultiplier(now: now, allowed: blinkAllowed)

        if pose.arcRipple.magnitude > 0.05, !reduceMotion {
            pose.arcPhase = now * 2.6
        }
        if targets.arcFlicker, !reduceMotion {
            pose.arcGlow *= 0.7 + 0.3 * abs(sin(now * 9) * sin(now * 3.4))
        }
        if targets.sways, !reduceMotion {
            pose.sway = 1.2 * sin(now * 2 * .pi * 0.6)
        }

        let active = targets.activeAgentIndex
        if targets.dotsCycling {
            pose.agentSignals[active].dotPhase = (now / 0.9).truncatingRemainder(dividingBy: 1)
        }

        if targets.urgentJumps, !reduceMotion {
            let cycle = now.truncatingRemainder(dividingBy: 1.6)
            if cycle < 0.45 {
                let jump = sin(cycle / 0.45 * .pi)
                pose.agentSignals[active].lift += CGFloat(8 * jump)
            }
        }

        if let toolKind = targets.toolKind, !reduceMotion {
            switch toolKind {
            case .shell:
                pose.agentSignals[active].jitter = CGFloat(2.5 * sin(now * 2 * .pi * 9))
            case .edit:
                pose.agentSignals[active].dotPhase = (now / 0.35).truncatingRemainder(dividingBy: 1)
                pose.agentSignals[active].jitter = CGFloat(1.2 * sin(now * 2 * .pi * 5))
            case .read:
                pose.agentSignals[active].jitter = CGFloat(3 * sin(now * 2 * .pi * 0.5))
            case .web:
                pose.agentSignals[active].orbit = 1
                pose.agentSignals[active].dotPhase = (now / 1.4).truncatingRemainder(dividingBy: 1)
            case .other:
                pose.agentSignals[active].tilt = 4 * sin(now * 2 * .pi * 1.2)
            }
        }
    }

    // MARK: Fleet motion (INF-275)

    private var fleetPositions: [String: CGPoint] = [:]
    private var fleetOrbitPhases: [String: Double] = [:]
    private var badgePhases: [AttacheAgentIdentity: Double] = [:]
    private var lastShownIDs: Set<String> = []
    private struct FleetTransient {
        var position: CGPoint
        var agent: AttacheAgentIdentity
        var age: TimeInterval = 0
    }
    private var fleetTransients: [FleetTransient] = []
    /// The last frame's motes, in design units, for hover and click
    /// hit-testing in the view.
    private(set) var lastFleetMotes: [AttacheFleetMote] = []
    private var lastFleetTick: TimeInterval?
    /// The focused mote's pinned ring angle (INF-280). It never advances on
    /// its own; the view's drag gesture and focus changes are the only
    /// writers.
    var focusedAngle: Double = AttacheCharacterChoreography.defaultFocusAngle
    /// True while the user is dragging any mote, so the view can raise the
    /// frame rate for a responsive hand feel.
    var draggingFocus = false

    /// Repins a draggable mote at a new lane angle: the focused mote moves
    /// its persistent pin, a glyph mote its frozen spot (INF-281).
    func setDraggedAngle(sessionID: String, angle: Double) {
        let clamped = AttacheCharacterChoreography.clampToOuterTrack(angle)
        if sessionID == lastFocusedID {
            focusedAngle = clamped
        } else {
            fleetOrbitPhases[sessionID] = clamped
        }
    }
    private var lastFocusedID: String?
    private var lastOverhead: AttacheOverhead?
    private var overheadStartedAt: TimeInterval?
    /// Eased compaction 0-1, so the squish ramps up smoothly and springs back.
    private var compactionValue: Double = 0
    /// Where the focused mote sat last frame, for the continuous stare.
    private(set) var focusedMotePosition: CGPoint?
    /// A short look at a mote whose state just demanded eyes: gaze target,
    /// deadline, and whether it was good news (check) or a question.
    private var glance: (target: CGPoint, until: TimeInterval, isGood: Bool)?
    private var lastFleetStates: [String: AttacheFleetSession.State] = [:]
    private var fleetGaze = CGSize.zero

    /// A stable starting angle per session so mote layouts never shuffle.
    private static func seedPhase(_ id: String) -> Double {
        Double(abs(id.hashValue % 628)) / 100.0
    }

    /// Computes this frame's fleet motes on the session ring (INF-280):
    /// working motes orbit the character, quiet motes settle into their agent's
    /// bottom-arc cluster, needs-you and finished motes freeze in place with
    /// their glyphs, the focused mote sits pinned at `focusedAngle`, and
    /// badge membership changes animate. Call after `pose(at:...)` each
    /// frame.
    func fleet(activity: AttacheActivityState, reduceMotion: Bool, notificationsOnly: Bool = false) -> [AttacheFleetMote] {
        let now = lastTick ?? Date().timeIntervalSinceReferenceDate
        let dt = min(1.0 / 15.0, max(0, now - (lastFleetTick ?? now)))
        lastFleetTick = now

        // The desktop mini attache is a calm notification indicator
        // (INF-291): it keeps only the focused session and the motes that
        // ping (needs-you, finished), dropping the orbiting working and
        // quiet motes and their badges.
        let sourceFleet = notificationsOnly
            ? activity.fleet.filter { $0.isFocused || $0.state == .blocked || $0.state == .finished }
            : activity.fleet
        let layout = AttacheFleetLayout.compute(fleet: sourceFleet)
        var motes: [AttacheFleetMote] = []
        var shownIDs: Set<String> = []
        var badgeCenters: [AttacheAgentIdentity: CGPoint] = [:]
        let ringCenterY = AttacheCharacterChoreography.ringCenter.y

        func ease(_ id: String, toward target: CGPoint, spawnAt: CGPoint, rate: Double = 5) -> CGPoint {
            var position = fleetPositions[id] ?? spawnAt
            if reduceMotion {
                position = target
            } else {
                let blend = min(1, dt * rate)
                position.x += (target.x - position.x) * blend
                position.y += (target.y - position.y) * blend
            }
            fleetPositions[id] = position
            return position
        }

        func ripples(for session: AttacheFleetSession) -> [Double] {
            guard session.activeSubAgents > 0, !reduceMotion else { return [] }
            // Unbounded on purpose (INF-286): a huge sub-agent swarm may
            // read as a blur, and that blur IS the signal. The numeral
            // carries the exact count.
            let period = max(0.05, 1.4 / (Double(session.activeSubAgents)).squareRoot())
            return [0, 0.5].map { offset in
                (now / period + offset).truncatingRemainder(dividingBy: 1)
            }
        }

        func frozenAngle(_ id: String) -> Double {
            let angle = fleetOrbitPhases[id] ?? Self.seedPhase(id)
            fleetOrbitPhases[id] = angle
            return angle
        }

        // The focused session is pinned, whatever its state. A focus change
        // pins the new mote where it currently sits and lets the old one
        // rejoin the ring from the pin, so nothing ever teleports.
        let focused = activity.fleet.first(where: \.isFocused)
        if let focused {
            if lastFocusedID != focused.id {
                if let previous = lastFocusedID {
                    fleetOrbitPhases[previous] = focusedAngle
                }
                focusedAngle = AttacheCharacterChoreography.clampToOuterTrack(fleetOrbitPhases[focused.id] ?? focusedAngle)
                lastFocusedID = focused.id
            }
            fleetOrbitPhases[focused.id] = focusedAngle
        } else {
            lastFocusedID = nil
            focusedMotePosition = nil
        }

        // Glances (INF-280): a mote that just flipped to needs-you or
        // finished draws a quick look and an expression before the eyes
        // return to the focused stare.
        var states: [String: AttacheFleetSession.State] = [:]
        for session in activity.fleet { states[session.id] = session.state }

        for agent in AttacheAgentIdentity.allCases {
            guard let group = layout.groups[agent] else { continue }

            var badgeCenter: CGPoint?
            if group.orbitingBadgeCount > 0 {
                var phase = badgePhases[agent] ?? Self.seedPhase(agent.rawValue)
                if !reduceMotion { phase += dt * 0.5 }
                badgePhases[agent] = phase
                badgeCenter = AttacheCharacterChoreography.ringPoint(angle: phase)
                badgeCenters[agent] = badgeCenter
            }

            for session in group.orbiting where !session.isFocused {
                shownIDs.insert(session.id)
                var phase = fleetOrbitPhases[session.id] ?? Self.seedPhase(session.id)
                if !reduceMotion { phase += dt * 0.55 }
                fleetOrbitPhases[session.id] = phase
                let target = AttacheCharacterChoreography.ringPoint(angle: phase)
                let position = ease(session.id, toward: target, spawnAt: badgeCenter ?? target)
                let subs = session.activeSubAgents
                motes.append(AttacheFleetMote(
                    position: position,
                    radius: subs > 0 ? 5 : 3.6,
                    fill: .agent(agent),
                    count: subs > 0 ? subs : nil,
                    ripples: ripples(for: session),
                    sessionID: session.id,
                    title: subs > 0 ? "\(session.title) · \(subs) sub-agents" : session.title,
                    behind: position.y < ringCenterY - 0.5
                ))
            }

            for (index, session) in group.parked.enumerated() where !session.isFocused {
                shownIDs.insert(session.id)
                let target = AttacheCharacterChoreography.ringPoint(
                    angle: AttacheCharacterChoreography.parkAngle(agent: agent, slot: index)
                )
                let position = ease(session.id, toward: target, spawnAt: badgeCenter ?? target)
                motes.append(AttacheFleetMote(
                    position: position,
                    radius: 3.4,
                    fill: .agent(agent),
                    opacity: 0.4,
                    sessionID: session.id,
                    title: session.title
                ))
            }
            if group.parkedBadgeCount > 0 {
                let slot = group.parked.filter { !$0.isFocused }.count
                motes.append(AttacheFleetMote(
                    position: AttacheCharacterChoreography.ringPoint(
                        angle: AttacheCharacterChoreography.parkAngle(agent: agent, slot: slot)
                    ),
                    radius: 7,
                    fill: .agent(agent),
                    opacity: 0.4,
                    count: group.parkedBadgeCount,
                    title: "\(group.parkedBadgeCount) quiet"
                ))
            }

            // Needs-you and finished motes step onto the inner lane, close
            // to the face, always in front: notifications, not traffic.
            for session in group.blocked where !session.isFocused {
                shownIDs.insert(session.id)
                let angle = AttacheCharacterChoreography.clampToOuterTrack(frozenAngle(session.id))
                let target = AttacheCharacterChoreography.outerRingPoint(angle: angle)
                let position = ease(session.id, toward: target, spawnAt: target)
                let pulse = reduceMotion ? 0 : 0.4 * sin(2 * .pi * now / 1.6)
                if lastFleetStates[session.id] != .blocked {
                    glance = (position, now + 0.9, false)
                }
                motes.append(AttacheFleetMote(
                    position: position,
                    radius: 4.8 + CGFloat(pulse),
                    fill: .blocked,
                    sessionID: session.id,
                    title: session.title,
                    glyph: .question,
                    draggable: true
                ))
            }

            for session in group.finished where !session.isFocused {
                shownIDs.insert(session.id)
                let angle = AttacheCharacterChoreography.clampToOuterTrack(frozenAngle(session.id))
                let target = AttacheCharacterChoreography.outerRingPoint(angle: angle)
                let position = ease(session.id, toward: target, spawnAt: target)
                if lastFleetStates[session.id] != .finished {
                    glance = (position, now + 0.9, true)
                }
                motes.append(AttacheFleetMote(
                    position: position,
                    radius: 4.6,
                    fill: .agent(agent),
                    opacity: 0.95,
                    sessionID: session.id,
                    title: session.title,
                    glyph: .check,
                    draggable: true
                ))
            }

            if let badgeCenter, group.orbitingBadgeCount > 0 {
                motes.append(AttacheFleetMote(
                    position: badgeCenter,
                    radius: group.orbitingBadgeCount > 99 ? 9 : 7.5,
                    fill: .agent(agent),
                    count: group.orbitingBadgeCount,
                    ripples: [],
                    title: "\(group.orbitingBadgeCount) working",
                    behind: badgeCenter.y < ringCenterY - 0.5
                ))
            }
        }

        if let focused {
            shownIDs.insert(focused.id)
            let target = AttacheCharacterChoreography.outerRingPoint(angle: focusedAngle)
            let position = ease(focused.id, toward: target, spawnAt: target, rate: draggingFocus ? 16 : 7)
            focusedMotePosition = position
            let glyph: AttacheFleetMote.Glyph
            switch focused.state {
            case .blocked: glyph = .question
            case .finished: glyph = .check
            case .working, .quiet: glyph = .none
            }
            let focusedSubs = glyph == .none ? focused.activeSubAgents : 0
            motes.append(AttacheFleetMote(
                position: position,
                radius: 5.2,
                fill: .focused,
                opacity: focused.state == .quiet ? 0.85 : 1,
                ring: true,
                count: focusedSubs > 0 ? focusedSubs : nil,
                ripples: ripples(for: focused),
                sessionID: focused.id,
                title: focusedSubs > 0 ? "\(focused.title) · \(focusedSubs) sub-agents" : focused.title,
                behind: position.y < ringCenterY - 0.5,
                glyph: glyph,
                draggable: true
            ))
        }
        lastFleetStates = states

        // A session that just merged into a badge flies from its last spot
        // into the badge as a short-lived transient.
        if !reduceMotion {
            let merged = lastShownIDs.subtracting(shownIDs)
            for id in merged {
                guard let last = fleetPositions[id],
                      let session = activity.fleet.first(where: { $0.id == id }),
                      session.state == .working,
                      badgeCenters[session.agent] != nil else { continue }
                fleetTransients.append(FleetTransient(position: last, agent: session.agent))
            }
            var alive: [FleetTransient] = []
            for var transient in fleetTransients {
                guard let target = badgeCenters[transient.agent] else { continue }
                transient.age += dt
                let rate = min(1, dt * 7)
                transient.position.x += (target.x - transient.position.x) * rate
                transient.position.y += (target.y - transient.position.y) * rate
                let dx = transient.position.x - target.x
                let dy = transient.position.y - target.y
                if transient.age < 1.2, dx * dx + dy * dy > 16 {
                    motes.append(AttacheFleetMote(
                        position: transient.position,
                        radius: 3.2,
                        fill: .agent(transient.agent),
                        opacity: 0.8
                    ))
                    alive.append(transient)
                }
            }
            fleetTransients = alive
        } else {
            fleetTransients.removeAll()
        }

        for id in fleetPositions.keys where !shownIDs.contains(id) {
            fleetPositions.removeValue(forKey: id)
            fleetOrbitPhases.removeValue(forKey: id)
        }
        lastShownIDs = shownIDs
        lastFleetMotes = motes
        return motes
    }

    private func blinkMultiplier(now: TimeInterval, allowed: Bool) -> Double {
        guard allowed else {
            blinkStartedAt = nil
            if now > nextBlinkAt { scheduleBlink(after: now) }
            return 1
        }
        if blinkStartedAt == nil, now >= nextBlinkAt {
            blinkStartedAt = now
            doubleBlinkQueued = Double.random(in: 0..<1) < 0.15
        }
        guard let start = blinkStartedAt else { return 1 }
        let t = now - start
        if t < 0.12 { return 1 - t / 0.12 }
        if t < 0.21 { return 0 }
        if t < 0.35 { return (t - 0.21) / 0.14 }
        blinkStartedAt = nil
        if doubleBlinkQueued {
            doubleBlinkQueued = false
            nextBlinkAt = now + 0.25
        } else {
            scheduleBlink(after: now)
        }
        return 1
    }

    private func scheduleBlink(after now: TimeInterval) {
        nextBlinkAt = now + Double.random(in: 4...7)
    }
}

/// The character renderer (INF-270): Attaché animated by its activity contract.
/// Consumes `AttacheActivityState` only; the caller injects fresh audio via
/// `with(audio:)`. The animation clock pauses whenever the host window loses
/// visibility and drops to 12 fps for the calm phases, keeping the idle character
/// under the 2 percent CPU budget.
struct AttacheCharacterView: View {
    var activity: AttacheActivityState
    var moment: AttacheActivityMoment?
    var theme: AttacheTheme
    var brightnessLevel: Int
    var delights: CharacterDelights = .none
    /// The shiny easter egg: golden arcs on the 1-in-20 profiles (INF-273).
    var shiny = false
    /// The character in the middle of the ring (INF-283).
    var character: AttacheCharacter = .robot
    /// Replaces the illustrated face with Echo's voice bars while preserving
    /// this view's shared fleet and reaction machinery.
    var rendersEchoBars = false
    /// A real full-screen Echo presentation can grow beyond the ordinary
    /// character-sized ceiling without switching renderers.
    var immersive = false
    /// The desktop mini attache keeps only focus/needs-you/finished motes
    /// (a calm notification indicator), dropping the orbiting fleet (INF-291).
    var fleetNotificationsOnly = false
    /// Fleet interactivity (INF-275): click a mote to focus its session,
    /// click a badge to open the session switcher.
    var onFleetFocus: ((String) -> Void)?
    var onFleetSwitch: (() -> Void)?
    /// The session id of the fleet mote under the cursor changed (INF-375),
    /// nil when none is. The parent keys a per-mote right-click context menu
    /// off this. Purely additive: it rides the existing hover hit-test and
    /// never alters click, drag, or hover behavior of the motes.
    var onHoveredMoteChange: ((String?) -> Void)?
    /// The focused mote's persisted ring angle and its writeback when the
    /// user finishes dragging it (INF-280).
    var focusAngle: Double = AttacheCharacterChoreography.defaultFocusAngle
    var onFocusAngleChanged: ((Double) -> Void)?
    /// Incognito identity (INF-356): a visor-band overlay drawn above the
    /// crown whenever the active conversation is private. This is a pure
    /// sibling overlay layer composited on top of `AttacheCharacterFigure`,
    /// never a change to its drawing code, so the geometry-locked rig
    /// (INF-269) is untouched: `--render-character-poses`, which instantiates
    /// `AttacheCharacterFigure` directly, never sees this view at all.
    var isPrivate = false
    /// Karaoke captions are on screen for the current speaking turn
    /// (INF-358 check 1): the choreography damps its ambient flourishes.
    var isCaptioning = false
    /// An app overlay (command palette, inbox, history, character switcher,
    /// shortcuts) is open above this view (INF-358 check 2): the character
    /// holds its current pose instead of continuing to animate under the
    /// dimmed overlay.
    var overlayVisible = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var motor = AttacheCharacterMotor()
    @State private var windowVisible = true
    @State private var hoverGaze: CGSize?
    @State private var hoveredMote: (title: String, at: CGPoint)?
    @State private var hoveredMoteSessionID: String?
    @State private var draggedMote: (id: String, isFocused: Bool)?

    private static let headroom: CGFloat = 28

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                TimelineView(.animation(
                    minimumInterval: frameInterval,
                    paused: AttacheCharacterAnimationGate.isPaused(windowVisible: windowVisible, overlayVisible: overlayVisible)
                )) { context in
                    AttacheCharacterFigure(
                        pose: motor.pose(
                            at: context.date,
                            activity: activity,
                            moment: moment,
                            delights: delights,
                            hoverGaze: hoverGaze,
                            reduceMotion: reduceMotion,
                            isCaptioning: isCaptioning
                        ),
                        arcColor: arcColor,
                        headroom: Self.headroom,
                        anatomy: .head,
                        character: character,
                        rendersEchoBars: rendersEchoBars,
                        fleetMotes: motor.fleet(activity: activity, reduceMotion: reduceMotion, notificationsOnly: fleetNotificationsOnly),
                        accentColor: colorScheme == .dark
                            ? .white
                            : Color(red: 0.10, green: 0.11, blue: 0.14),
                        accentIsLight: colorScheme == .dark
                    )
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    if delights.hoverReacts {
                        hoverGaze = CGSize(
                            width: (location.x / max(1, proxy.size.width) - 0.5) * 6,
                            height: (location.y / max(1, proxy.size.height) - 0.5) * 6
                        )
                    }
                    let hit = fleetMote(at: location, in: proxy.size)
                    hoveredMote = hit.map { ($0.title, moteViewPosition($0, in: proxy.size)) }
                    updateHoveredMoteSession(hit?.sessionID)
                case .ended:
                    hoverGaze = nil
                    hoveredMote = nil
                    updateHoveredMoteSession(nil)
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                if let mote = fleetMote(at: value.location, in: proxy.size) {
                    if let sessionID = mote.sessionID {
                        onFleetFocus?(sessionID)
                    } else if mote.count != nil {
                        onFleetSwitch?()
                    }
                    return
                }
                guard delights.hoverReacts,
                      activity.phase == .idle || activity.phase == .sleeping else { return }
                motor.noteClick(at: Date())
            })
            .simultaneousGesture(DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if draggedMote == nil {
                        guard let mote = fleetMote(at: value.startLocation, in: proxy.size),
                              mote.draggable, let sessionID = mote.sessionID else { return }
                        draggedMote = (sessionID, mote.fill == .focused)
                        motor.draggingFocus = true
                    }
                    guard let draggedMote else { return }
                    motor.setDraggedAngle(
                        sessionID: draggedMote.id,
                        angle: ringAngle(at: value.location, in: proxy.size)
                    )
                }
                .onEnded { _ in
                    guard let ended = draggedMote else { return }
                    draggedMote = nil
                    motor.draggingFocus = false
                    if ended.isFocused {
                        onFocusAngleChanged?(motor.focusedAngle)
                    }
                })
            .onAppear { motor.focusedAngle = focusAngle }
            .overlay(alignment: .topLeading) {
                if let hoveredMote, !hoveredMote.title.isEmpty {
                    Text(hoveredMote.title)
                        .typoCaption(.medium)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.primary.opacity(0.15)))
                        .position(
                            x: min(max(70, hoveredMote.at.x), proxy.size.width - 70),
                            y: max(14, hoveredMote.at.y - 22)
                        )
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                // Accessibility only (INF-375): the fleet motes are Canvas-drawn
                // and carry no AX of their own, so mirror each mote's session
                // title into the accessibility tree here. This layer never
                // hit-tests, so pointer click, drag, and hover on the motes are
                // untouched. Positions track the last computed mote frame.
                Group {
                    ForEach(motor.lastFleetMotes.indices, id: \.self) { index in
                        let mote = motor.lastFleetMotes[index]
                        if mote.sessionID != nil, !mote.title.isEmpty {
                            Color.clear
                                .frame(width: 12, height: 12)
                                .position(moteViewPosition(mote, in: proxy.size))
                                .accessibilityElement()
                                .accessibilityLabel(mote.title)
                                .accessibilityHint("Watched session. Right-click for actions.")
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .padding(36)
        .frame(
            maxWidth: immersive ? 1_160 : 620,
            maxHeight: immersive ? 1_160 : 660
        )
        .background(HostWindowVisibilityObserver { visible in
            if windowVisible != visible { windowVisible = visible }
        })
        .allowsHitTesting(delights.hoverReacts || !activity.fleet.isEmpty)
    }

    private func updateHoveredMoteSession(_ id: String?) {
        guard id != hoveredMoteSessionID else { return }
        hoveredMoteSessionID = id
        onHoveredMoteChange?(id)
    }

    private func moteViewPosition(_ mote: AttacheFleetMote, in size: CGSize) -> CGPoint {
        let (s, ox, oy) = AttacheCharacterFigure.designTransform(size: size, headroom: Self.headroom)
        return CGPoint(x: ox + mote.position.x * s, y: oy + mote.position.y * s)
    }

    /// The ring angle under a view-space point, for dragging the focused
    /// mote along the path.
    private func ringAngle(at location: CGPoint, in size: CGSize) -> Double {
        let (s, ox, oy) = AttacheCharacterFigure.designTransform(size: size, headroom: Self.headroom)
        let dx = ((location.x - ox) / s - AttacheCharacterChoreography.ringCenter.x)
            / AttacheCharacterChoreography.ringRadii.width
        let dy = ((location.y - oy) / s - AttacheCharacterChoreography.ringCenter.y)
            / AttacheCharacterChoreography.ringRadii.height
        return atan2(dy, dx)
    }

    private func fleetMote(at location: CGPoint, in size: CGSize) -> AttacheFleetMote? {
        let (s, _, _) = AttacheCharacterFigure.designTransform(size: size, headroom: Self.headroom)
        var best: (mote: AttacheFleetMote, distance: CGFloat)?
        for mote in motor.lastFleetMotes where mote.sessionID != nil || mote.count != nil {
            let position = moteViewPosition(mote, in: size)
            let dx = position.x - location.x, dy = position.y - location.y
            let distance = (dx * dx + dy * dy).squareRoot()
            let reach = max(13, mote.radius * s + 7)
            if distance <= reach, distance < (best?.distance ?? .infinity) {
                best = (mote, distance)
            }
        }
        return best?.mote
    }

    private var arcColor: Color {
        let base = theme.energyColor(1.0, opacity: 0.96, brightnessLevel: brightnessLevel, darkScheme: colorScheme == .dark)
        guard shiny else { return base }
        return base.blended(with: Color(red: 1.0, green: 0.78, blue: 0.35), fraction: 0.55)
    }

    private var frameInterval: Double {
        if draggedMote != nil { return 1.0 / 40.0 }
        let fleetIsMoving = activity.fleet.contains { $0.state != .quiet }
        switch activity.phase {
        case .sleeping, .idle, .paused:
            return fleetIsMoving ? 1.0 / 30.0 : 1.0 / 12.0
        default:
            return 1.0 / 40.0
        }
    }
}

/// Pure gating (INF-358 check 2): whether the character's animation clock
/// should pause and hold its current pose. True when the host window is
/// occluded (the existing CPU-budget gate) OR an app overlay (command
/// palette, inbox, history, character switcher, keyboard shortcuts) is open
/// above it, so the character never keeps animating unseen under a dimmed
/// overlay.
enum AttacheCharacterAnimationGate {
    static func isPaused(windowVisible: Bool, overlayVisible: Bool) -> Bool {
        !windowVisible || overlayVisible
    }
}

private extension Color {
    /// Component-wise blend in sRGB, enough for the shiny tint.
    func blended(with other: Color, fraction: Double) -> Color {
        let lhs = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let rhs = NSColor(other).usingColorSpace(.sRGB) ?? .white
        let t = min(1, max(0, fraction))
        return Color(
            .sRGB,
            red: Double(lhs.redComponent) * (1 - t) + Double(rhs.redComponent) * t,
            green: Double(lhs.greenComponent) * (1 - t) + Double(rhs.greenComponent) * t,
            blue: Double(lhs.blueComponent) * (1 - t) + Double(rhs.blueComponent) * t,
            opacity: 0.96
        )
    }
}

/// Reports whether the hosting window is actually visible (not occluded, not
/// hidden), so the character's animation clock can stop burning CPU behind other
/// windows or on hidden apps.
private struct HostWindowVisibilityObserver: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            guard let window else { return }
            report(window)
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                self?.report(window)
            }
        }

        private func report(_ window: NSWindow) {
            let visible = window.occlusionState.contains(.visible)
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(visible)
            }
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
