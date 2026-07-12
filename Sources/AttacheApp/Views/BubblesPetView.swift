import AppKit
import AttacheCore
import SwiftUI

/// Maps the companion contract to pose targets for the Bubbles rig: the pure
/// half of the pet renderer (unit-tested), consumed by `BubblesPetMotor`
/// which layers time on top. Values come from the state table in
/// `design/pet-animation-spec.md`; retune there first, then here.
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
            targets.pose.eyeOpenness = 0
            targets.pose.smile = 0.6
            targets.pose.cheekGlow = 0.45
            targets.pose.arcGlow = 0.25
            targets.breathePeriod = 4.5
            targets.blinkAllowed = false
            for index in 0..<3 { targets.pose.bubbles[index].brightness = 0.55 }

        case .idle:
            targets.breathePeriod = 3.2

        case .agentThinking:
            targets.pose.headTilt = active == 0 ? -6 : (active == 2 ? 6 : 0)
            targets.pose.gaze = CGSize(width: active == 0 ? -2 : (active == 2 ? 2 : 0), height: -1)
            targets.pose.smile = 0.45
            targets.pose.arcGlow = 0.8
            targets.breathePeriod = 2.8
            targets.dotsCycling = true
            spotlight(1, others: 0.45, lift: 8)

        case .toolRunning:
            targets.pose.eyeOpenness = 0.75
            targets.pose.smile = 0.6
            targets.pose.arcGlow = 0.8
            targets.breathePeriod = 2.4
            targets.dotsCycling = true
            targets.toolKind = activity.toolKind ?? .other
            spotlight(1, others: 0.45, lift: 4)

        case .agentResponding:
            targets.pose.gaze = CGSize(width: 0, height: -1.5)
            targets.pose.smile = 0.8
            targets.pose.arcGlow = 0.85
            targets.pose.arcRipple = -1
            targets.breathePeriod = 2.8
            spotlight(1, others: 0.45, lift: 12)

        case .speaking:
            targets.pose.arcGlow = 1
            targets.pose.arcRipple = 1
            targets.mouthTracksAudio = true
            targets.sways = true
            targets.breathePeriod = 2.8
            spotlight(1, others: 0.4)

        case .paused:
            targets.pose.eyeOpenness = 0.85
            targets.pose.mouthOpen = 0.18
            targets.pose.arcGlow = 0.5
            for index in 0..<3 { targets.pose.bubbles[index].brightness = 0.75 }

        case .blockedOnUser:
            targets.pose.browWorry = 1
            targets.pose.cheekGlow = 0.2
            targets.pose.smile = 0.3
            targets.pose.arcGlow = 0.15
            targets.urgentJumps = true
            targets.dotsCycling = true
            spotlight(1, others: 0.3, lift: 6)

        case .error:
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

    func pose(at date: Date, activity: CompanionActivityState, reduceMotion: Bool) -> BubblesPose {
        let now = date.timeIntervalSinceReferenceDate
        let dt = min(1.0 / 15.0, max(0, now - (lastTick ?? now)))
        lastTick = now

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
        return pose
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
    var theme: CompanionTheme
    var brightnessLevel: Int

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var motor = BubblesPetMotor()
    @State private var windowVisible = true

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval, paused: !windowVisible)) { context in
            BubblesPetFigure(
                pose: motor.pose(at: context.date, activity: activity, reduceMotion: reduceMotion),
                arcColor: theme.energyColor(1.0, opacity: 0.96, brightnessLevel: brightnessLevel, darkScheme: colorScheme == .dark),
                headroom: 28
            )
        }
        .padding(36)
        .frame(maxWidth: 620, maxHeight: 660)
        .background(HostWindowVisibilityObserver { visible in
            if windowVisible != visible { windowVisible = visible }
        })
        .allowsHitTesting(false)
    }

    private var frameInterval: Double {
        switch activity.phase {
        case .sleeping, .idle, .paused: return 1.0 / 12.0
        default: return 1.0 / 40.0
        }
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
