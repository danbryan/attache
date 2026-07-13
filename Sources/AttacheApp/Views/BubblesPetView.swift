import AppKit
import AttacheCore
import SwiftUI

/// Maps the companion contract to pose targets for the Bubbles rig: the pure
/// half of the pet renderer (unit-tested), consumed by `BubblesPetMotor`
/// which layers time on top. Values come from the state table in
/// `design/pet-animation-spec.md`; retune there first, then here.
///
/// The full choreography map (INF-271), everything retunable in one place:
///
/// Continuous phases (this file, `targets(for:)`):
///   sleeping        eyes closed, arcs 0.25, breathe 4.5 s, no blink
///   idle            the logo at rest, blink loop, breathe 3.2 s
///   agentThinking   head tilts toward the agent's bubble, bubble lifts 8,
///                   dots cycle, others dim 0.45
///   toolRunning     focused eyes, bubble lifts 4 and vibrates per toolKind
///                   (shell 9 Hz shake, edit scribble, read slow scan,
///                   web dot orbit, other wobble)
///   agentResponding bubble springs 12 toward the head, arcs ripple inward
///   speaking        mouth on audio.level, sway, arcs ripple outward,
///                   speaker's bubble lit, others 0.4
///   paused          held small mouth, arcs 0.5
///   blockedOnUser   worry brows, pale cheeks, arcs stopped at 0.15, bubble
///                   jumps 14 every 1.6 s
///   error           dizzy X eyes, arcs flicker, bubble droops
///
/// One-shot moments (`BubblesPetMotor.applyMoment`):
///   celebrate    1.2 s hop with squash, confetti pop from the agent bubble
///   cardArrived  0.8 s bubble bounce and wiggle, brightness to full
///   drowsy       2.5 s eye droop and head nod
///   Moments queue while blocked/speaking/paused own the stage and drop
///   after `CompanionActivityMoment.shelfLife` (8 s).
///
/// Upstream rules the pet relies on:
///   dwell        `CompanionActivityDamper` in AttacheCore: ambient phases
///                hold 1.2 s, tool kinds hold 2 s, signal phases instant
///   priority     `AppModel.currentActivitySignals`: exact asks beat soft
///                waits, most recent transition wins within a tier, and the
///                bubble always shows whose event won
///   bubble map   claude = left rust, none = center blue, codex = right green
enum BubblesPetChoreography {
    struct Targets: Equatable {
        var pose = BubblesPose()
        /// Breathing period in seconds; arousal maps to tempo.
        var breathePeriod: Double = 3.2
        /// Which bubble the phase belongs to (0 Claude, 1 center, 2 Codex).
        var activeBubble = 1
        /// The active bubble's typing dots cycle while true.
        var dotsCycling = false
        /// Tool flavor for the procedural vibration layer.
        var toolKind: CompanionToolKind?
        /// Mouth follows the audio level instead of the pose target.
        var mouthTracksAudio = false
        /// Idle-style blinking is allowed (suppressed asleep or dizzy).
        var blinkAllowed = true
        /// The active bubble jumps urgently (blockedOnUser).
        var urgentJumps = false
        /// Arc opacity flickers (error).
        var arcFlicker = false
        /// Body sways with speech.
        var sways = false
    }

    /// Left rust bubble is Claude, right green bubble is Codex, center blue
    /// is everything else; see the spec's anatomy notes.
    static func bubbleIndex(for agent: CompanionAgentIdentity) -> Int {
        switch agent {
        case .claude: return 0
        case .none: return 1
        case .codex: return 2
        }
    }

    /// Bubble anchor geometry in design units, for the full-anatomy mark:
    /// center of each bubble body plus its top and bottom edges.
    static let bubbleCenters: [CGPoint] = [
        CGPoint(x: 56, y: 181.5), CGPoint(x: 120, y: 195.5), CGPoint(x: 184, y: 181.5),
    ]
    static let bubbleTops: [CGFloat] = [168, 182, 168]
    static let bubbleBottoms: [CGFloat] = [195, 209, 195]

    /// The session ring around the head anatomy (INF-280), in design units.
    /// The center matches the head after `BubblesPetFigure.headAnatomyDrop`.
    /// A true circle (INF-285): the crown zone (totems and speaking arcs)
    /// lives entirely inside the ring's apex, so orbit traffic never touches
    /// a phase indicator.
    static let ringCenter = CGPoint(x: 120, y: 138)
    static let ringRadii = CGSize(width: 76, height: 76)
    /// The inner lane for needs-you and finished motes: hugging the face so
    /// the glyph reads like a notification on the pet, clearly out of the
    /// orbit traffic (INF-281).
    static let innerRingRadii = CGSize(width: 48, height: 48)
    /// Where the focused mote rests until the user drags it: bottom center,
    /// right in front of the pet's gaze.
    static let defaultFocusAngle = Double.pi / 2

    /// A point on the session ring.
    static func ringPoint(angle: Double) -> CGPoint {
        CGPoint(
            x: ringCenter.x + CGFloat(cos(angle)) * ringRadii.width,
            y: ringCenter.y + CGFloat(sin(angle)) * ringRadii.height
        )
    }

    /// A point on the inner glyph lane.
    static func innerRingPoint(angle: Double) -> CGPoint {
        CGPoint(
            x: ringCenter.x + CGFloat(cos(angle)) * innerRingRadii.width,
            y: ringCenter.y + CGFloat(sin(angle)) * innerRingRadii.height
        )
    }

    /// Where an agent's quiet sessions settle: a cluster on the ring's
    /// bottom arc, Claude to the left of the focused rest spot, Codex to
    /// the right, others straight down, spreading outward per slot.
    static func parkAngle(agent: CompanionAgentIdentity, slot: Int) -> Double {
        let side: Double
        switch agent {
        case .claude: side = 1
        case .codex: side = -1
        case .none: side = 0.5
        }
        let base = Double.pi / 2 + side * 0.55
        return base + side * Double(slot) * 0.22
    }

    static func targets(for activity: CompanionActivityState) -> Targets {
        var targets = Targets()
        let active = bubbleIndex(for: activity.activeAgent)
        targets.activeBubble = active

        func spotlight(_ activeBrightness: Double, others: Double, lift: CGFloat = 0) {
            for index in 0..<3 {
                targets.pose.bubbles[index].brightness = index == active ? activeBrightness : others
            }
            targets.pose.bubbles[active].lift = lift
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
            for index in 0..<3 { targets.pose.bubbles[index].brightness = 0.55 }

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
            targets.pose.arcGlow = 1
            targets.pose.arcRipple = 1
            targets.mouthTracksAudio = true
            targets.sways = true
            targets.breathePeriod = 2.8
            spotlight(1, others: 0.4)

        case .paused:
            targets.pose.overhead = .paused
            targets.pose.eyeOpenness = 0.85
            targets.pose.mouthOpen = 0.18
            targets.pose.arcGlow = 0.5
            for index in 0..<3 { targets.pose.bubbles[index].brightness = 0.75 }

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
struct PetDelights: Equatable {
    var typesAlong = true
    var rareIdles = false
    var hoverReacts = false

    static let none = PetDelights(typesAlong: false, rareIdles: false, hoverReacts: false)
}

/// Integrates spring motion, blinking, and the procedural loops between the
/// choreography's pose targets and the drawn frame. Plain fields only (no
/// published state): the surrounding `TimelineView` already redraws every
/// frame, so the motor never needs to invalidate anything itself.
final class BubblesPetMotor: ObservableObject {
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
    private var bubbleLift = [Spring(value: 0), Spring(value: 0), Spring(value: 0)]
    private var bubbleBrightness = [Spring(value: 1), Spring(value: 1), Spring(value: 1)]

    private var lastTick: TimeInterval?
    private var nextBlinkAt: TimeInterval = 3
    private var blinkStartedAt: TimeInterval?
    private var doubleBlinkQueued = false
    private var seenMomentIDs: Set<UUID> = []
    private var queuedMoments: [CompanionActivityMoment] = []
    private var activeMoment: (moment: CompanionActivityMoment, startedAt: TimeInterval)?
    private var nextRareIdleAt: TimeInterval?
    private var activeRareIdle: (juggles: Bool, startedAt: TimeInterval)?
    private var clickBouncedAt: TimeInterval?
    /// Rare-idle cadence in seconds; `ATTACHE_PET_RARE_IDLE_SECONDS` shrinks
    /// it so the reel and QA runs never wait minutes for a moment whose whole
    /// point is rarity.
    private let rareIdleInterval: ClosedRange<Double> = {
        if let raw = ProcessInfo.processInfo.environment["ATTACHE_PET_RARE_IDLE_SECONDS"],
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
        activity: CompanionActivityState,
        moment: CompanionActivityMoment? = nil,
        delights: PetDelights = .none,
        hoverGaze: CGSize? = nil,
        reduceMotion: Bool
    ) -> BubblesPose {
        let now = date.timeIntervalSinceReferenceDate
        let dt = min(1.0 / 15.0, max(0, now - (lastTick ?? now)))
        lastTick = now

        if let moment, !seenMomentIDs.contains(moment.id) {
            seenMomentIDs.insert(moment.id)
            queuedMoments.append(moment)
        }

        let targets = BubblesPetChoreography.targets(for: activity)
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
            pose.bubbles[index].lift = CGFloat(drive(&bubbleLift[index], toward: Double(targets.pose.bubbles[index].lift), Self.snappy))
            pose.bubbles[index].brightness = drive(&bubbleBrightness[index], toward: targets.pose.bubbles[index].brightness, Self.soft)
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
        applyFleetGaze(to: &pose, activity: activity, now: now, reduceMotion: reduceMotion)
        return pose
    }

    /// The stare and the glance (INF-280). With a focused session pinned on
    /// the ring the eyes rest on it; a mote that just turned needs-you or
    /// finished steals a short look (worried brows for a question, a warm
    /// cheek glow for a check) before the gaze returns.
    private func applyFleetGaze(
        to pose: inout BubblesPose,
        activity: CompanionActivityState,
        now: TimeInterval,
        reduceMotion: Bool
    ) {
        func gazeTarget(toward point: CGPoint) -> CGSize {
            CGSize(
                width: (point.x - BubblesPetChoreography.ringCenter.x)
                    / BubblesPetChoreography.ringRadii.width * 3,
                height: (point.y - BubblesPetChoreography.ringCenter.y)
                    / BubblesPetChoreography.ringRadii.height * 3
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
        to pose: inout BubblesPose,
        phase: CompanionActivityPhase,
        userTyping: Bool,
        delights: PetDelights,
        hoverGaze: CGSize?,
        now: TimeInterval,
        reduceMotion: Bool
    ) {
        guard phase == .idle || phase == .sleeping else {
            activeRareIdle = nil
            return
        }

        if delights.typesAlong, userTyping, !reduceMotion {
            // Head anatomy (INF-280): with no bubbles to tap, the pet types
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
                        pose.bubbles[index].lift += CGFloat(6 * wave)
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
    private func advanceMoment(now: TimeInterval, date: Date, phase: CompanionActivityPhase) {
        if let active = activeMoment, now - active.startedAt >= Self.momentDuration(active.moment.kind) {
            activeMoment = nil
        }
        guard activeMoment == nil else { return }
        queuedMoments.removeAll { date.timeIntervalSince($0.at) > CompanionActivityMoment.shelfLife }
        let stageIsOwned = phase == .blockedOnUser || phase == .speaking || phase == .paused
        guard !stageIsOwned, !queuedMoments.isEmpty else { return }
        let next = queuedMoments.removeFirst()
        activeMoment = (next, now)
    }

    private static func momentDuration(_ kind: CompanionActivityMoment.Kind) -> TimeInterval {
        switch kind {
        case .celebrate: return 1.2
        case .cardArrived: return 0.8
        case .drowsy: return 2.5
        }
    }

    private func applyMoment(
        _ moment: CompanionActivityMoment,
        startedAt: TimeInterval,
        to pose: inout BubblesPose,
        now: TimeInterval,
        reduceMotion: Bool
    ) {
        let duration = Self.momentDuration(moment.kind)
        let progress = min(1, max(0, (now - startedAt) / duration))
        let bubble = BubblesPetChoreography.bubbleIndex(for: moment.agent)
        switch moment.kind {
        case .celebrate:
            pose.cheekGlow = max(pose.cheekGlow, 0.95 * sin(progress * .pi) + 0.6 * (1 - sin(progress * .pi)))
            pose.smile = 1
            pose.bubbles[bubble].pop = progress
            pose.bubbles[bubble].brightness = 1
            if !reduceMotion {
                pose.hop = CGFloat(16 * sin(min(1, progress / 0.7) * .pi))
                pose.squash = -0.4 * sin(min(1, progress / 0.7) * .pi)
                pose.arcRipple = 1
                pose.arcPhase = now * 2.6
            }
        case .cardArrived:
            pose.bubbles[bubble].brightness = 1
            pose.bubbles[bubble].dotPhase = nil
            if !reduceMotion {
                pose.bubbles[bubble].lift += CGFloat(8 * sin(progress * .pi))
                pose.bubbles[bubble].tilt += 6 * sin(progress * .pi * 2)
            }
        case .drowsy:
            pose.eyeOpenness *= 1 - 0.65 * sin(progress * .pi)
            if !reduceMotion {
                pose.headTilt += 4 * sin(progress * .pi)
            }
        }
    }

    private func applyLoops(to pose: inout BubblesPose, targets: BubblesPetChoreography.Targets, now: TimeInterval, reduceMotion: Bool) {
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

        let active = targets.activeBubble
        if targets.dotsCycling {
            pose.bubbles[active].dotPhase = (now / 0.9).truncatingRemainder(dividingBy: 1)
        }

        if targets.urgentJumps, !reduceMotion {
            let cycle = now.truncatingRemainder(dividingBy: 1.6)
            if cycle < 0.45 {
                let jump = sin(cycle / 0.45 * .pi)
                pose.bubbles[active].lift += CGFloat(8 * jump)
            }
        }

        if let toolKind = targets.toolKind, !reduceMotion {
            switch toolKind {
            case .shell:
                pose.bubbles[active].jitter = CGFloat(2.5 * sin(now * 2 * .pi * 9))
            case .edit:
                pose.bubbles[active].dotPhase = (now / 0.35).truncatingRemainder(dividingBy: 1)
                pose.bubbles[active].jitter = CGFloat(1.2 * sin(now * 2 * .pi * 5))
            case .read:
                pose.bubbles[active].jitter = CGFloat(3 * sin(now * 2 * .pi * 0.5))
            case .web:
                pose.bubbles[active].orbit = 1
                pose.bubbles[active].dotPhase = (now / 1.4).truncatingRemainder(dividingBy: 1)
            case .other:
                pose.bubbles[active].tilt = 4 * sin(now * 2 * .pi * 1.2)
            }
        }
    }

    // MARK: Fleet motion (INF-275)

    private var fleetPositions: [String: CGPoint] = [:]
    private var fleetOrbitPhases: [String: Double] = [:]
    private var badgePhases: [CompanionAgentIdentity: Double] = [:]
    private var lastShownIDs: Set<String> = []
    private struct FleetTransient {
        var position: CGPoint
        var agent: CompanionAgentIdentity
        var age: TimeInterval = 0
    }
    private var fleetTransients: [FleetTransient] = []
    /// The last frame's motes, in design units, for hover and click
    /// hit-testing in the view.
    private(set) var lastFleetMotes: [BubblesFleetMote] = []
    private var lastFleetTick: TimeInterval?
    /// The focused mote's pinned ring angle (INF-280). It never advances on
    /// its own; the view's drag gesture and focus changes are the only
    /// writers.
    var focusedAngle: Double = BubblesPetChoreography.defaultFocusAngle
    /// True while the user is dragging any mote, so the view can raise the
    /// frame rate for a responsive hand feel.
    var draggingFocus = false

    /// Repins a draggable mote at a new lane angle: the focused mote moves
    /// its persistent pin, a glyph mote its frozen spot (INF-281).
    func setDraggedAngle(sessionID: String, angle: Double) {
        if sessionID == lastFocusedID {
            focusedAngle = angle
        } else {
            fleetOrbitPhases[sessionID] = angle
        }
    }
    private var lastFocusedID: String?
    private var lastOverhead: BubblesOverhead?
    private var overheadStartedAt: TimeInterval?
    /// Where the focused mote sat last frame, for the continuous stare.
    private(set) var focusedMotePosition: CGPoint?
    /// A short look at a mote whose state just demanded eyes: gaze target,
    /// deadline, and whether it was good news (check) or a question.
    private var glance: (target: CGPoint, until: TimeInterval, isGood: Bool)?
    private var lastFleetStates: [String: CompanionFleetSession.State] = [:]
    private var fleetGaze = CGSize.zero

    /// A stable starting angle per session so mote layouts never shuffle.
    private static func seedPhase(_ id: String) -> Double {
        Double(abs(id.hashValue % 628)) / 100.0
    }

    /// Computes this frame's fleet motes on the session ring (INF-280):
    /// working motes orbit the pet, quiet motes settle into their agent's
    /// bottom-arc cluster, needs-you and finished motes freeze in place with
    /// their glyphs, the focused mote sits pinned at `focusedAngle`, and
    /// badge membership changes animate. Call after `pose(at:...)` each
    /// frame.
    func fleet(activity: CompanionActivityState, reduceMotion: Bool) -> [BubblesFleetMote] {
        let now = lastTick ?? Date().timeIntervalSinceReferenceDate
        let dt = min(1.0 / 15.0, max(0, now - (lastFleetTick ?? now)))
        lastFleetTick = now

        let layout = BubblesFleetLayout.compute(fleet: activity.fleet)
        var motes: [BubblesFleetMote] = []
        var shownIDs: Set<String> = []
        var badgeCenters: [CompanionAgentIdentity: CGPoint] = [:]
        let ringCenterY = BubblesPetChoreography.ringCenter.y

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

        func ripples(for session: CompanionFleetSession) -> [Double] {
            guard session.activeSubAgents > 0, !reduceMotion else { return [] }
            let period = max(0.45, 1.4 / (Double(session.activeSubAgents)).squareRoot())
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
                focusedAngle = fleetOrbitPhases[focused.id] ?? focusedAngle
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
        var states: [String: CompanionFleetSession.State] = [:]
        for session in activity.fleet { states[session.id] = session.state }

        for agent in CompanionAgentIdentity.allCases {
            guard let group = layout.groups[agent] else { continue }

            var badgeCenter: CGPoint?
            if group.orbitingBadgeCount > 0 {
                var phase = badgePhases[agent] ?? Self.seedPhase(agent.rawValue)
                if !reduceMotion { phase += dt * 0.5 }
                badgePhases[agent] = phase
                badgeCenter = BubblesPetChoreography.ringPoint(angle: phase)
                badgeCenters[agent] = badgeCenter
            }

            for session in group.orbiting where !session.isFocused {
                shownIDs.insert(session.id)
                var phase = fleetOrbitPhases[session.id] ?? Self.seedPhase(session.id)
                if !reduceMotion { phase += dt * 0.55 }
                fleetOrbitPhases[session.id] = phase
                let target = BubblesPetChoreography.ringPoint(angle: phase)
                let position = ease(session.id, toward: target, spawnAt: badgeCenter ?? target)
                let subs = session.activeSubAgents
                motes.append(BubblesFleetMote(
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
                let target = BubblesPetChoreography.ringPoint(
                    angle: BubblesPetChoreography.parkAngle(agent: agent, slot: index)
                )
                let position = ease(session.id, toward: target, spawnAt: badgeCenter ?? target)
                motes.append(BubblesFleetMote(
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
                motes.append(BubblesFleetMote(
                    position: BubblesPetChoreography.ringPoint(
                        angle: BubblesPetChoreography.parkAngle(agent: agent, slot: slot)
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
                let target = BubblesPetChoreography.innerRingPoint(angle: frozenAngle(session.id))
                let position = ease(session.id, toward: target, spawnAt: target)
                let pulse = reduceMotion ? 0 : 0.4 * sin(2 * .pi * now / 1.6)
                if lastFleetStates[session.id] != .blocked {
                    glance = (position, now + 0.9, false)
                }
                motes.append(BubblesFleetMote(
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
                let target = BubblesPetChoreography.innerRingPoint(angle: frozenAngle(session.id))
                let position = ease(session.id, toward: target, spawnAt: target)
                if lastFleetStates[session.id] != .finished {
                    glance = (position, now + 0.9, true)
                }
                motes.append(BubblesFleetMote(
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
                motes.append(BubblesFleetMote(
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
            let target = BubblesPetChoreography.ringPoint(angle: focusedAngle)
            let position = ease(focused.id, toward: target, spawnAt: target, rate: draggingFocus ? 16 : 7)
            focusedMotePosition = position
            let glyph: BubblesFleetMote.Glyph
            switch focused.state {
            case .blocked: glyph = .question
            case .finished: glyph = .check
            case .working, .quiet: glyph = .none
            }
            let focusedSubs = glyph == .none ? focused.activeSubAgents : 0
            motes.append(BubblesFleetMote(
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
                    motes.append(BubblesFleetMote(
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

/// The pet renderer (INF-270): Bubbles animated by the companion contract.
/// Consumes `CompanionActivityState` only; the caller injects fresh audio via
/// `with(audio:)`. The animation clock pauses whenever the host window loses
/// visibility and drops to 12 fps for the calm phases, keeping the idle pet
/// under the 2 percent CPU budget.
struct BubblesPetView: View {
    var activity: CompanionActivityState
    var moment: CompanionActivityMoment?
    var theme: CompanionTheme
    var brightnessLevel: Int
    var delights: PetDelights = .none
    /// The shiny easter egg: golden arcs on the 1-in-20 profiles (INF-273).
    var shiny = false
    /// The character in the middle of the ring (INF-283).
    var character: BubblesPetCharacter = .bubbles
    /// Fleet interactivity (INF-275): click a mote to focus its session,
    /// click a badge to open the session switcher.
    var onFleetFocus: ((String) -> Void)?
    var onFleetSwitch: (() -> Void)?
    /// The focused mote's persisted ring angle and its writeback when the
    /// user finishes dragging it (INF-280).
    var focusAngle: Double = BubblesPetChoreography.defaultFocusAngle
    var onFocusAngleChanged: ((Double) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var motor = BubblesPetMotor()
    @State private var windowVisible = true
    @State private var hoverGaze: CGSize?
    @State private var hoveredMote: (title: String, at: CGPoint)?
    @State private var draggedMote: (id: String, isFocused: Bool)?

    private static let headroom: CGFloat = 28

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: frameInterval, paused: !windowVisible)) { context in
                BubblesPetFigure(
                    pose: motor.pose(
                        at: context.date,
                        activity: activity,
                        moment: moment,
                        delights: delights,
                        hoverGaze: hoverGaze,
                        reduceMotion: reduceMotion
                    ),
                    arcColor: arcColor,
                    headroom: Self.headroom,
                    anatomy: .head,
                    character: character,
                    fleetMotes: motor.fleet(activity: activity, reduceMotion: reduceMotion),
                    accentColor: colorScheme == .dark
                        ? .white
                        : Color(red: 0.10, green: 0.11, blue: 0.14),
                    accentIsLight: colorScheme == .dark
                )
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
                    hoveredMote = fleetMote(at: location, in: proxy.size)
                        .map { ($0.title, moteViewPosition($0, in: proxy.size)) }
                case .ended:
                    hoverGaze = nil
                    hoveredMote = nil
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
        }
        .padding(36)
        .frame(maxWidth: 620, maxHeight: 660)
        .background(HostWindowVisibilityObserver { visible in
            if windowVisible != visible { windowVisible = visible }
        })
        .allowsHitTesting(delights.hoverReacts || !activity.fleet.isEmpty)
    }

    private func moteViewPosition(_ mote: BubblesFleetMote, in size: CGSize) -> CGPoint {
        let (s, ox, oy) = BubblesPetFigure.designTransform(size: size, headroom: Self.headroom)
        return CGPoint(x: ox + mote.position.x * s, y: oy + mote.position.y * s)
    }

    /// The ring angle under a view-space point, for dragging the focused
    /// mote along the path.
    private func ringAngle(at location: CGPoint, in size: CGSize) -> Double {
        let (s, ox, oy) = BubblesPetFigure.designTransform(size: size, headroom: Self.headroom)
        let dx = ((location.x - ox) / s - BubblesPetChoreography.ringCenter.x)
            / BubblesPetChoreography.ringRadii.width
        let dy = ((location.y - oy) / s - BubblesPetChoreography.ringCenter.y)
            / BubblesPetChoreography.ringRadii.height
        return atan2(dy, dx)
    }

    private func fleetMote(at location: CGPoint, in size: CGSize) -> BubblesFleetMote? {
        let (s, _, _) = BubblesPetFigure.designTransform(size: size, headroom: Self.headroom)
        var best: (mote: BubblesFleetMote, distance: CGFloat)?
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
/// hidden), so the pet's animation clock can stop burning CPU behind other
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
