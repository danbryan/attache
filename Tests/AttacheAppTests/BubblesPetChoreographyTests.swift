import XCTest
import AttacheCore
@testable import AttacheApp

final class BubblesPetChoreographyTests: XCTestCase {
    private func state(
        _ phase: CompanionActivityPhase,
        agent: CompanionAgentIdentity = .none,
        toolKind: CompanionToolKind? = nil
    ) -> CompanionActivityState {
        CompanionActivityState(phase: phase, activeAgent: agent, toolKind: toolKind)
    }

    func testBubbleIdentityMatchesBrandOrder() {
        XCTAssertEqual(BubblesPetChoreography.bubbleIndex(for: .claude), 0)
        XCTAssertEqual(BubblesPetChoreography.bubbleIndex(for: .none), 1)
        XCTAssertEqual(BubblesPetChoreography.bubbleIndex(for: .codex), 2)
    }

    func testSleepingClosesEyesAndSlowsBreathing() {
        let targets = BubblesPetChoreography.targets(for: state(.sleeping))
        XCTAssertEqual(targets.pose.eyeOpenness, 0)
        XCTAssertEqual(targets.breathePeriod, 4.5)
        XCTAssertFalse(targets.blinkAllowed)
        XCTAssertEqual(targets.pose.arcGlow, 0.25)
    }

    func testIdleIsTheLogoAtRest() {
        let targets = BubblesPetChoreography.targets(for: state(.idle))
        XCTAssertEqual(targets.pose.eyeOpenness, 1)
        XCTAssertEqual(targets.pose.smile, 1)
        XCTAssertEqual(targets.pose.arcGlow, 1)
        XCTAssertEqual(targets.pose.bubbles.map(\.brightness), [1, 1, 1])
    }

    func testThinkingTiltsTowardTheActiveAgent() {
        let claude = BubblesPetChoreography.targets(for: state(.agentThinking, agent: .claude))
        XCTAssertEqual(claude.pose.headTilt, -6)
        XCTAssertEqual(claude.pose.bubbles[0].lift, 8)
        XCTAssertEqual(claude.pose.bubbles[0].brightness, 1)
        XCTAssertEqual(claude.pose.bubbles[2].brightness, 0.45)
        XCTAssertTrue(claude.dotsCycling)

        let codex = BubblesPetChoreography.targets(for: state(.agentThinking, agent: .codex))
        XCTAssertEqual(codex.pose.headTilt, 6)
        XCTAssertEqual(codex.pose.bubbles[2].lift, 8)
    }

    func testToolRunningCarriesTheFlavor() {
        let targets = BubblesPetChoreography.targets(for: state(.toolRunning, agent: .codex, toolKind: .shell))
        XCTAssertEqual(targets.toolKind, .shell)
        XCTAssertEqual(targets.pose.bubbles[2].brightness, 1)
        XCTAssertEqual(targets.pose.eyeOpenness, 0.75)
    }

    func testToolRunningWithoutKindDefaultsToOther() {
        let targets = BubblesPetChoreography.targets(for: state(.toolRunning, agent: .codex))
        XCTAssertEqual(targets.toolKind, .other)
    }

    func testRespondingRipplesInwardAndBouncesTheBubble() {
        let targets = BubblesPetChoreography.targets(for: state(.agentResponding, agent: .claude))
        XCTAssertEqual(targets.pose.arcRipple, -1)
        XCTAssertEqual(targets.pose.bubbles[0].lift, 12)
    }

    func testSpeakingTracksAudioAndRipplesOutward() {
        let targets = BubblesPetChoreography.targets(for: state(.speaking, agent: .codex))
        XCTAssertTrue(targets.mouthTracksAudio)
        XCTAssertTrue(targets.sways)
        XCTAssertEqual(targets.pose.arcRipple, 1)
        XCTAssertEqual(targets.pose.bubbles[2].brightness, 1)
        XCTAssertEqual(targets.pose.bubbles[0].brightness, 0.4)
    }

    func testBlockedIsWorriedPaleAndUrgent() {
        let targets = BubblesPetChoreography.targets(for: state(.blockedOnUser, agent: .claude))
        XCTAssertEqual(targets.pose.browWorry, 1)
        XCTAssertEqual(targets.pose.cheekGlow, 0.2)
        XCTAssertEqual(targets.pose.arcGlow, 0.15)
        XCTAssertTrue(targets.urgentJumps)
        XCTAssertEqual(targets.pose.bubbles[0].brightness, 1)
        XCTAssertEqual(targets.pose.bubbles[1].brightness, 0.3)
    }

    func testErrorIsDizzyWithFlickeringArcs() {
        let targets = BubblesPetChoreography.targets(for: state(.error, agent: .codex))
        XCTAssertEqual(targets.pose.dizzy, 1)
        XCTAssertTrue(targets.arcFlicker)
        XCTAssertFalse(targets.blinkAllowed)
        XCTAssertEqual(targets.pose.bubbles[2].lift, -4)
    }

    func testMotorSettlesOnTargetsWithoutMotion() {
        let motor = BubblesPetMotor()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        var pose = BubblesPose()
        for tick in 0..<40 {
            pose = motor.pose(
                at: start.addingTimeInterval(Double(tick) * 0.05),
                activity: state(.blockedOnUser, agent: .claude),
                reduceMotion: true
            )
        }
        XCTAssertEqual(pose.browWorry, 1, accuracy: 0.05)
        XCTAssertEqual(pose.cheekGlow, 0.2, accuracy: 0.05)
        XCTAssertEqual(pose.bubbles[1].brightness, 0.3, accuracy: 0.05)
    }

    func testMotorSpringsConvergeOnTargets() {
        let motor = BubblesPetMotor()
        let start = Date(timeIntervalSinceReferenceDate: 2000)
        var pose = BubblesPose()
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
    /// exploded (eyes drawn across the whole canvas, bubbles vanishing).
    /// The substepped integrator must stay bounded and settle at any rate.
    func testMotorStaysStableAtIdleFrameRate() {
        let motor = BubblesPetMotor()
        let start = Date(timeIntervalSinceReferenceDate: 3000)
        var pose = BubblesPose()
        for tick in 0..<240 {
            pose = motor.pose(
                at: start.addingTimeInterval(Double(tick) / 12.0),
                activity: state(.sleeping),
                reduceMotion: false
            )
            XCTAssertLessThan(abs(pose.eyeOpenness), 2, "eye spring diverged at tick \(tick)")
            XCTAssertLessThan(abs(pose.bubbles[2].brightness), 2, "brightness spring diverged at tick \(tick)")
        }
        XCTAssertEqual(pose.eyeOpenness, 0, accuracy: 0.1)
        XCTAssertEqual(pose.bubbles[2].brightness, 0.55, accuracy: 0.1)
    }

    func testSanitizedClampsDivergedValues() {
        var pose = BubblesPose()
        pose.eyeOpenness = -40
        pose.headTilt = 720
        pose.arcGlow = .infinity
        pose.bubbles[2].brightness = -3
        let clean = pose.sanitized()
        XCTAssertEqual(clean.eyeOpenness, -0.2)
        XCTAssertEqual(clean.headTilt, 30)
        XCTAssertEqual(clean.arcGlow, 0)
        XCTAssertEqual(clean.bubbles[2].brightness, 0)
    }

    func testSanitizedLeavesNeutralUntouched() {
        XCTAssertEqual(BubblesPose.neutral.sanitized(), BubblesPose.neutral)
    }
}
