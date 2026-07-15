import XCTest
import AttacheCore
@testable import AttacheApp

final class AttacheCharacterChoreographyTests: XCTestCase {
    private func state(
        _ phase: AttacheActivityPhase,
        agent: AttacheAgentIdentity = .none,
        toolKind: AttacheToolKind? = nil
    ) -> AttacheActivityState {
        AttacheActivityState(phase: phase, activeAgent: agent, toolKind: toolKind)
    }

    func testBubbleIdentityMatchesBrandOrder() {
        XCTAssertEqual(AttacheCharacterChoreography.agentIndex(for: .claude), 0)
        XCTAssertEqual(AttacheCharacterChoreography.agentIndex(for: .none), 1)
        XCTAssertEqual(AttacheCharacterChoreography.agentIndex(for: .codex), 2)
    }

    func testSleepingClosesEyesAndSlowsBreathing() {
        let targets = AttacheCharacterChoreography.targets(for: state(.sleeping))
        XCTAssertEqual(targets.pose.eyeOpenness, 0)
        XCTAssertEqual(targets.breathePeriod, 4.5)
        XCTAssertFalse(targets.blinkAllowed)
        XCTAssertEqual(targets.pose.arcGlow, 0.25)
    }

    func testIdleIsTheLogoAtRest() {
        let targets = AttacheCharacterChoreography.targets(for: state(.idle))
        XCTAssertEqual(targets.pose.eyeOpenness, 1)
        XCTAssertEqual(targets.pose.smile, 1)
        XCTAssertEqual(targets.pose.arcGlow, 1)
        XCTAssertEqual(targets.pose.agentSignals.map(\.brightness), [1, 1, 1])
    }

    func testThinkingTiltsTowardTheActiveAgent() {
        let claude = AttacheCharacterChoreography.targets(for: state(.agentThinking, agent: .claude))
        XCTAssertEqual(claude.pose.headTilt, -6)
        XCTAssertEqual(claude.pose.agentSignals[0].lift, 8)
        XCTAssertEqual(claude.pose.agentSignals[0].brightness, 1)
        XCTAssertEqual(claude.pose.agentSignals[2].brightness, 0.45)
        XCTAssertTrue(claude.dotsCycling)

        let codex = AttacheCharacterChoreography.targets(for: state(.agentThinking, agent: .codex))
        XCTAssertEqual(codex.pose.headTilt, 6)
        XCTAssertEqual(codex.pose.agentSignals[2].lift, 8)
    }

    func testToolRunningCarriesTheFlavor() {
        let targets = AttacheCharacterChoreography.targets(for: state(.toolRunning, agent: .codex, toolKind: .shell))
        XCTAssertEqual(targets.toolKind, .shell)
        XCTAssertEqual(targets.pose.agentSignals[2].brightness, 1)
        XCTAssertEqual(targets.pose.eyeOpenness, 0.75)
    }

    func testToolRunningWithoutKindDefaultsToOther() {
        let targets = AttacheCharacterChoreography.targets(for: state(.toolRunning, agent: .codex))
        XCTAssertEqual(targets.toolKind, .other)
    }

    func testRespondingRipplesInwardAndBouncesTheBubble() {
        let targets = AttacheCharacterChoreography.targets(for: state(.agentResponding, agent: .claude))
        XCTAssertEqual(targets.pose.arcRipple, -1)
        XCTAssertEqual(targets.pose.agentSignals[0].lift, 12)
    }

    func testSpeakingTracksAudioAndRipplesOutward() {
        let targets = AttacheCharacterChoreography.targets(for: state(.speaking, agent: .codex))
        XCTAssertTrue(targets.mouthTracksAudio)
        XCTAssertTrue(targets.sways)
        XCTAssertEqual(targets.pose.arcRipple, 1)
        XCTAssertEqual(targets.pose.agentSignals[2].brightness, 1)
        XCTAssertEqual(targets.pose.agentSignals[0].brightness, 0.4)
    }

    func testBlockedIsWorriedPaleAndUrgent() {
        let targets = AttacheCharacterChoreography.targets(for: state(.blockedOnUser, agent: .claude))
        XCTAssertEqual(targets.pose.browWorry, 1)
        XCTAssertEqual(targets.pose.cheekGlow, 0.2)
        XCTAssertEqual(targets.pose.arcGlow, 0.15)
        XCTAssertTrue(targets.urgentJumps)
        XCTAssertEqual(targets.pose.agentSignals[0].brightness, 1)
        XCTAssertEqual(targets.pose.agentSignals[1].brightness, 0.3)
    }

    func testErrorIsDizzyWithFlickeringArcs() {
        let targets = AttacheCharacterChoreography.targets(for: state(.error, agent: .codex))
        XCTAssertEqual(targets.pose.dizzy, 1)
        XCTAssertTrue(targets.arcFlicker)
        XCTAssertFalse(targets.blinkAllowed)
        XCTAssertEqual(targets.pose.agentSignals[2].lift, -4)
    }

    func testMotorSettlesOnTargetsWithoutMotion() {
        let motor = AttacheCharacterMotor()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        var pose = AttachePose()
        for tick in 0..<40 {
            pose = motor.pose(
                at: start.addingTimeInterval(Double(tick) * 0.05),
                activity: state(.blockedOnUser, agent: .claude),
                reduceMotion: true
            )
        }
        XCTAssertEqual(pose.browWorry, 1, accuracy: 0.05)
        XCTAssertEqual(pose.cheekGlow, 0.2, accuracy: 0.05)
        XCTAssertEqual(pose.agentSignals[1].brightness, 0.3, accuracy: 0.05)
    }

    func testMotorSpringsConvergeOnTargets() {
        let motor = AttacheCharacterMotor()
        let start = Date(timeIntervalSinceReferenceDate: 2000)
        var pose = AttachePose()
        for tick in 0..<120 {
            pose = motor.pose(
                at: start.addingTimeInterval(Double(tick) * 0.025),
                activity: state(.sleeping),
                reduceMotion: false
            )
        }
        XCTAssertEqual(pose.eyeOpenness, 0, accuracy: 0.08)
        XCTAssertEqual(pose.arcGlow, 0.25, accuracy: 0.08)
    }

    /// Regression: at the idle 12 fps cadence a single-step integrator was
    /// unstable for the standard and snappy responses; every spring visibly
    /// exploded (eyes drawn across the whole canvas, attache vanishing).
    /// The substepped integrator must stay bounded and settle at any rate.
    func testMotorStaysStableAtIdleFrameRate() {
        let motor = AttacheCharacterMotor()
        let start = Date(timeIntervalSinceReferenceDate: 3000)
        var pose = AttachePose()
        for tick in 0..<240 {
            pose = motor.pose(
                at: start.addingTimeInterval(Double(tick) / 12.0),
                activity: state(.sleeping),
                reduceMotion: false
            )
            XCTAssertLessThan(abs(pose.eyeOpenness), 2, "eye spring diverged at tick \(tick)")
            XCTAssertLessThan(abs(pose.agentSignals[2].brightness), 2, "brightness spring diverged at tick \(tick)")
        }
        XCTAssertEqual(pose.eyeOpenness, 0, accuracy: 0.1)
        XCTAssertEqual(pose.agentSignals[2].brightness, 0.55, accuracy: 0.1)
    }

    func testSanitizedClampsDivergedValues() {
        var pose = AttachePose()
        pose.eyeOpenness = -40
        pose.headTilt = 720
        pose.arcGlow = .infinity
        pose.agentSignals[2].brightness = -3
        let clean = pose.sanitized()
        XCTAssertEqual(clean.eyeOpenness, -0.2)
        XCTAssertEqual(clean.headTilt, 30)
        XCTAssertEqual(clean.arcGlow, 0)
        XCTAssertEqual(clean.agentSignals[2].brightness, 0)
    }

    func testSanitizedLeavesNeutralUntouched() {
        XCTAssertEqual(AttachePose.neutral.sanitized(), AttachePose.neutral)
    }

    // MARK: One-shot moments (INF-271)

    private func moment(
        _ kind: AttacheActivityMoment.Kind,
        agent: AttacheAgentIdentity = .codex,
        at: Date
    ) -> AttacheActivityMoment {
        AttacheActivityMoment(kind: kind, agent: agent, at: at)
    }

    func testFocusedCompactionSquishesAndOwnsTheCrown() {
        // The app sets `compactingSince` on the activity when the FOCUSED
        // session compacts (from the PreCompact hook). Given that, the motor
        // must squish the character and show the compacting crown. This proves the
        // pipeline downstream of the hook, so a real session that does not
        // squish is one where the hook never fired (a session that predates
        // the hook install), not an app bug.
        let motor = AttacheCharacterMotor()
        let start = Date(timeIntervalSinceReferenceDate: 5000)
        var activity = state(.agentThinking, agent: .claude)
        activity.compactingSince = start.addingTimeInterval(-30)  // 30s into a ~42s ramp
        var pose = AttachePose()
        for tick in 0..<80 {
            pose = motor.pose(
                at: start.addingTimeInterval(Double(tick) * 0.05),
                activity: activity,
                reduceMotion: true
            )
        }
        XCTAssertGreaterThan(pose.compaction, 0.4, "the focused session's compaction squishes the character")
        XCTAssertEqual(pose.overhead, .compacting, "the crown shows the compacting symbol")
    }

    func testNoSquishWhenNothingIsCompacting() {
        // With no `compactingSince` (no PreCompact fired, or the compacting
        // session is not focused), the character does not squish and keeps its
        // ambient crown. This is exactly what a non-hooked session shows.
        let motor = AttacheCharacterMotor()
        let start = Date(timeIntervalSinceReferenceDate: 6000)
        var pose = AttachePose()
        for tick in 0..<40 {
            pose = motor.pose(
                at: start.addingTimeInterval(Double(tick) * 0.05),
                activity: state(.agentThinking, agent: .claude),
                reduceMotion: true
            )
        }
        XCTAssertLessThan(pose.compaction, 0.05)
        XCTAssertNotEqual(pose.overhead, .compacting)
    }

    func testCelebrateMomentHopsAndPopsTheAgentBubble() {
        let motor = AttacheCharacterMotor()
        let start = Date(timeIntervalSinceReferenceDate: 4000)
        _ = motor.pose(at: start, activity: state(.idle), reduceMotion: false)
        var maxHop: CGFloat = 0
        var maxPop: Double = 0
        for tick in 1..<30 {
            let at = start.addingTimeInterval(Double(tick) * 0.05)
            let pose = motor.pose(
                at: at,
                activity: state(.idle),
                moment: moment(.celebrate, agent: .codex, at: start),
                reduceMotion: false
            )
            maxHop = max(maxHop, pose.hop)
            maxPop = max(maxPop, pose.agentSignals[2].pop)
        }
        XCTAssertGreaterThan(maxHop, 8, "celebrate must visibly hop")
        XCTAssertGreaterThan(maxPop, 0.4, "celebrate must emit the agent's confetti")
    }

    func testMomentQueuesBehindSpeakingAndPlaysAfter() {
        let motor = AttacheCharacterMotor()
        let start = Date(timeIntervalSinceReferenceDate: 5000)
        let celebration = moment(.celebrate, agent: .claude, at: start)
        var maxHopWhileSpeaking: CGFloat = 0
        for tick in 0..<20 {
            let pose = motor.pose(
                at: start.addingTimeInterval(Double(tick) * 0.05),
                activity: state(.speaking, agent: .claude),
                moment: celebration,
                reduceMotion: false
            )
            maxHopWhileSpeaking = max(maxHopWhileSpeaking, pose.hop)
        }
        XCTAssertEqual(maxHopWhileSpeaking, 0, "moments must never fire over speech")

        var maxHopAfter: CGFloat = 0
        for tick in 0..<30 {
            let pose = motor.pose(
                at: start.addingTimeInterval(1.0 + Double(tick) * 0.05),
                activity: state(.idle),
                moment: celebration,
                reduceMotion: false
            )
            maxHopAfter = max(maxHopAfter, pose.hop)
        }
        XCTAssertGreaterThan(maxHopAfter, 8, "a queued moment must play once the stage frees up")
    }

    func testStaleMomentIsDroppedInsteadOfPlayed() {
        let motor = AttacheCharacterMotor()
        let start = Date(timeIntervalSinceReferenceDate: 6000)
        let stale = moment(.celebrate, at: start.addingTimeInterval(-20))
        var maxHop: CGFloat = 0
        for tick in 0..<30 {
            let pose = motor.pose(
                at: start.addingTimeInterval(Double(tick) * 0.05),
                activity: state(.idle),
                moment: stale,
                reduceMotion: false
            )
            maxHop = max(maxHop, pose.hop)
        }
        XCTAssertEqual(maxHop, 0, "a moment past its shelf life must be dropped")
    }

    // MARK: Delights (INF-273)

    func testTypesAlongBouncesOnlyWhenCalm() {
        let motor = AttacheCharacterMotor()
        let start = Date(timeIntervalSinceReferenceDate: 8000)
        let delights = CharacterDelights(typesAlong: true, rareIdles: false, hoverReacts: false)
        var typingState = state(.idle)
        typingState.userTyping = true
        var maxHop: CGFloat = 0
        for tick in 0..<30 {
            let pose = motor.pose(
                at: start.addingTimeInterval(Double(tick) * 0.05),
                activity: typingState,
                delights: delights,
                reduceMotion: false
            )
            maxHop = max(maxHop, pose.hop)
        }
        XCTAssertGreaterThan(maxHop, 0.5, "typing must bounce the character at idle")

        var speakingState = state(.speaking, agent: .codex)
        speakingState.userTyping = true
        var speakingHop: CGFloat = 0
        let speakingMotor = AttacheCharacterMotor()
        for tick in 0..<30 {
            let pose = speakingMotor.pose(
                at: start.addingTimeInterval(Double(tick) * 0.05),
                activity: speakingState,
                delights: delights,
                reduceMotion: false
            )
            speakingHop = max(speakingHop, pose.hop)
        }
        XCTAssertLessThan(speakingHop, 0.3, "delights must never fire over speech")
    }

    func testClickBounceIgnoredWhileBlocked() {
        let motor = AttacheCharacterMotor()
        let start = Date(timeIntervalSinceReferenceDate: 9000)
        let delights = CharacterDelights(typesAlong: false, rareIdles: false, hoverReacts: true)
        motor.noteClick(at: start)
        var maxHop: CGFloat = 0
        for tick in 0..<20 {
            let pose = motor.pose(
                at: start.addingTimeInterval(Double(tick) * 0.05),
                activity: state(.blockedOnUser, agent: .claude),
                delights: delights,
                reduceMotion: false
            )
            maxHop = max(maxHop, pose.hop)
        }
        XCTAssertEqual(maxHop, 0, "a click bounce must not play over blockedOnUser")
    }

    func testHoverGazeShiftsEyesAtIdle() {
        let motor = AttacheCharacterMotor()
        let start = Date(timeIntervalSinceReferenceDate: 10000)
        let delights = CharacterDelights(typesAlong: false, rareIdles: false, hoverReacts: true)
        let pose = motor.pose(
            at: start,
            activity: state(.idle),
            delights: delights,
            hoverGaze: CGSize(width: 2.5, height: -1),
            reduceMotion: false
        )
        XCTAssertGreaterThan(pose.gaze.width, 1.5)
    }

    func testMomentPlaysOnlyOncePerID() {
        let motor = AttacheCharacterMotor()
        let start = Date(timeIntervalSinceReferenceDate: 7000)
        let once = moment(.cardArrived, agent: .claude, at: start)
        for tick in 0..<40 {
            _ = motor.pose(
                at: start.addingTimeInterval(Double(tick) * 0.05),
                activity: state(.idle),
                moment: once,
                reduceMotion: false
            )
        }
        var maxLiftLater: CGFloat = 0
        for tick in 0..<20 {
            let pose = motor.pose(
                at: start.addingTimeInterval(3.0 + Double(tick) * 0.05),
                activity: state(.idle),
                moment: once,
                reduceMotion: false
            )
            maxLiftLater = max(maxLiftLater, pose.agentSignals[0].lift)
        }
        XCTAssertLessThan(maxLiftLater, 3, "the same moment id must not replay")
    }
}
