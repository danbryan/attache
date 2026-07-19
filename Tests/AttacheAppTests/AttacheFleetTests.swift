import XCTest
import AttacheCore
@testable import AttacheApp

final class AttacheFleetTests: XCTestCase {
    private func session(
        _ id: String,
        agent: AttacheAgentIdentity = .claude,
        state: AttacheFleetSession.State = .working,
        focused: Bool = false,
        subAgents: Int = 0
    ) -> AttacheFleetSession {
        AttacheFleetSession(
            id: id, agent: agent, state: state,
            isFocused: focused, activeSubAgents: subAgents, title: id
        )
    }

    func testSmallFleetShowsEveryoneIndividually() {
        let fleet = (0..<4).map { session("c\($0)") }
        let layout = AttacheFleetLayout.compute(fleet: fleet)
        let group = layout.groups[.claude]
        XCTAssertEqual(group?.orbiting.count, 4)
        XCTAssertEqual(group?.orbitingBadgeCount, 0)
    }

    func testLargeWorkingFleetMergesIntoBadge() {
        let fleet = (0..<12).map { session("c\($0)") }
        let layout = AttacheFleetLayout.compute(fleet: fleet)
        let group = layout.groups[.claude]
        XCTAssertEqual(group?.orbiting.count, 0)
        XCTAssertEqual(group?.orbitingBadgeCount, 12)
    }

    func testFocusedAndRipplersNeverMerge() {
        var fleet = (0..<12).map { session("c\($0)") }
        fleet[0].isFocused = true
        fleet[1].activeSubAgents = 6
        fleet[2].activeSubAgents = 3
        fleet[3].activeSubAgents = 2
        let layout = AttacheFleetLayout.compute(fleet: fleet)
        let group = layout.groups[.claude]
        XCTAssertEqual(group?.orbiting.count, 3, "focused plus two ripplers stay out front")
        XCTAssertTrue(group?.orbiting.contains { $0.isFocused } ?? false)
        XCTAssertEqual(group?.orbitingBadgeCount, 9, "eight plain plus the overflow rippler")
    }

    func testBlockedSessionsAlwaysIndividual() {
        var fleet = (0..<20).map { session("c\($0)") }
        fleet[5].state = .blocked
        fleet[11].state = .blocked
        let layout = AttacheFleetLayout.compute(fleet: fleet)
        let group = layout.groups[.claude]
        XCTAssertEqual(group?.blocked.count, 2)
        XCTAssertEqual(group?.orbitingBadgeCount, 18)
    }

    func testFocusFlipMovesTheRingNotTheMotes() {
        var fleet = [session("a", state: .quiet), session("b", state: .quiet)]
        fleet[0].isFocused = true
        let before = AttacheFleetLayout.compute(fleet: fleet)
        fleet[0].isFocused = false
        fleet[1].isFocused = true
        let after = AttacheFleetLayout.compute(fleet: fleet)
        XCTAssertEqual(before.groups[.claude]?.parked.map(\.id), ["a", "b"])
        XCTAssertEqual(after.groups[.claude]?.parked.map(\.id), ["a", "b"],
                       "shelf slots are stable across a focus change")
        XCTAssertEqual(after.groups[.claude]?.parked.map(\.isFocused), [false, true])
    }

    func testQuietFleetCollapsesIntoParkedBadge() {
        let fleet = (0..<9).map { session("c\($0)", state: .quiet) }
        let layout = AttacheFleetLayout.compute(fleet: fleet)
        let group = layout.groups[.claude]
        XCTAssertEqual(group?.parked.count, 0)
        XCTAssertEqual(group?.parkedBadgeCount, 9)
    }

    func testAgentsGroupSeparately() {
        let fleet = (0..<3).map { session("c\($0)", agent: .claude) }
            + (0..<2).map { session("x\($0)", agent: .codex) }
        let layout = AttacheFleetLayout.compute(fleet: fleet)
        XCTAssertEqual(layout.groups[.claude]?.orbiting.count, 3)
        XCTAssertEqual(layout.groups[.codex]?.orbiting.count, 2)
        XCTAssertNil(layout.groups[.none])
    }

    // MARK: Motor fleet rendering

    private func activity(fleet: [AttacheFleetSession]) -> AttacheActivityState {
        AttacheActivityState(phase: .idle, fleet: fleet)
    }

    private func runMotor(_ motor: AttacheCharacterMotor, fleet: [AttacheFleetSession], ticks: Int) -> [AttacheFleetMote] {
        let start = Date(timeIntervalSinceReferenceDate: 50_000)
        var motes: [AttacheFleetMote] = []
        for tick in 0..<ticks {
            _ = motor.pose(at: start.addingTimeInterval(Double(tick) * 0.05),
                           activity: activity(fleet: fleet), reduceMotion: false)
            motes = motor.fleet(activity: activity(fleet: fleet), reduceMotion: false)
        }
        return motes
    }

    func testMotorRendersBadgeWithCountForBigFleet() {
        let motor = AttacheCharacterMotor()
        let fleet = (0..<30).map { session("c\($0)") }
        let motes = runMotor(motor, fleet: fleet, ticks: 10)
        let badge = motes.first { $0.count != nil }
        XCTAssertEqual(badge?.count, 30)
        XCTAssertTrue(motes.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite })
    }

    func testMotorMarksBlockedAndFocused() {
        let motor = AttacheCharacterMotor()
        var fleet = (0..<3).map { session("c\($0)") }
        fleet[0].isFocused = true
        fleet[2].state = .blocked
        let motes = runMotor(motor, fleet: fleet, ticks: 10)
        XCTAssertTrue(motes.contains { $0.fill == .focused && $0.ring })
        XCTAssertTrue(motes.contains { $0.fill == .blocked })
    }

    func testMotorRipplesForSubAgents() {
        let motor = AttacheCharacterMotor()
        let fleet = [session("c0", subAgents: 8)]
        let motes = runMotor(motor, fleet: fleet, ticks: 10)
        let rippler = motes.first { $0.sessionID == "c0" }
        XCTAssertEqual(rippler?.ripples.isEmpty, false)
        XCTAssertEqual(rippler?.count, 8, "the sub-agent count rides the mote as a numeral")
    }

    func testOverheadSecondsCountTheRespondingWait() {
        let motor = AttacheCharacterMotor()
        let start = Date(timeIntervalSinceReferenceDate: 60_000)
        var pose = AttachePose.neutral
        for tick in 0..<70 {
            pose = motor.pose(at: start.addingTimeInterval(Double(tick) * 0.05),
                              activity: AttacheActivityState(phase: .agentResponding),
                              reduceMotion: false)
        }
        XCTAssertEqual(pose.overhead, .preparingAudio)
        XCTAssertGreaterThanOrEqual(pose.overheadSeconds, 3)
        pose = motor.pose(at: start.addingTimeInterval(3.6),
                          activity: AttacheActivityState(phase: .speaking),
                          reduceMotion: false)
        XCTAssertEqual(pose.overheadSeconds, 0, "the counter resets when the state changes")
    }

    func testOverheadTotemFollowsThePhase() {
        func overhead(_ phase: AttacheActivityPhase) -> AttacheOverhead {
            AttacheCharacterChoreography.targets(for: AttacheActivityState(phase: phase)).pose.overhead
        }
        XCTAssertEqual(overhead(.idle), .none)
        XCTAssertEqual(overhead(.speaking), .arcs)
        XCTAssertEqual(overhead(.agentThinking), .thinking)
        XCTAssertEqual(overhead(.toolRunning), .tool)
        XCTAssertEqual(overhead(.agentResponding), .preparingAudio)
        XCTAssertEqual(overhead(.paused), .paused)
        XCTAssertEqual(overhead(.sleeping), .sleeping)
        XCTAssertEqual(overhead(.blockedOnUser), .none,
                       "the amber ? mote carries blocked; no crown noise")
    }

    func testFocusedMoteStaysPinnedWhileOthersOrbit() {
        let motor = AttacheCharacterMotor()
        var fleet = [session("c0", focused: true), session("c1")]
        fleet[0].state = .working
        let pin = AttacheCharacterChoreography.outerRingPoint(angle: AttacheCharacterChoreography.defaultFocusAngle)
        var focusedAt40 = CGPoint.zero
        var orbiterAt40 = CGPoint.zero
        var focusedAt80 = CGPoint.zero
        var orbiterAt80 = CGPoint.zero
        let start = Date(timeIntervalSinceReferenceDate: 50_000)
        for tick in 0..<80 {
            let state = AttacheActivityState(phase: .idle, fleet: fleet)
            _ = motor.pose(at: start.addingTimeInterval(Double(tick) * 0.05),
                           activity: state, reduceMotion: false)
            let motes = motor.fleet(activity: state, reduceMotion: false)
            let focusedMote = motes.first { $0.sessionID == "c0" }!
            let orbiter = motes.first { $0.sessionID == "c1" }!
            if tick == 40 { focusedAt40 = focusedMote.position; orbiterAt40 = orbiter.position }
            if tick == 79 { focusedAt80 = focusedMote.position; orbiterAt80 = orbiter.position }
        }
        XCTAssertLessThan(abs(focusedAt80.x - pin.x) + abs(focusedAt80.y - pin.y), 1,
                          "the focused mote settles on its pin")
        XCTAssertLessThan(abs(focusedAt80.x - focusedAt40.x) + abs(focusedAt80.y - focusedAt40.y), 0.5,
                          "the pin does not drift")
        XCTAssertGreaterThan(abs(orbiterAt80.x - orbiterAt40.x) + abs(orbiterAt80.y - orbiterAt40.y), 4,
                             "unfocused working motes keep orbiting")
        XCTAssertNotNil(motor.focusedMotePosition, "the stare has a target")
    }

    func testFocusChangePinsTheNewMoteWhereItSat() {
        let motor = AttacheCharacterMotor()
        var fleet = [session("c0", focused: true), session("c1")]
        let start = Date(timeIntervalSinceReferenceDate: 50_000)
        // Let c1 orbit to a real, non-seed angle with explicit timestamps.
        for tick in 0..<60 {
            let state = AttacheActivityState(phase: .idle, fleet: fleet)
            _ = motor.pose(at: start.addingTimeInterval(Double(tick) * 0.05),
                           activity: state, reduceMotion: false)
            _ = motor.fleet(activity: state, reduceMotion: false)
        }
        // Read `before` from a reduced-motion frame so it is c1's exact orbit
        // angle, which is the same value the pin is derived from. The eased
        // render lags the true orbit angle by a fraction of a radian, and near
        // the crown dead zone's midpoint that lag flips which edge `before` and
        // the pin each clamp to, producing the intermittent ~1-radian miss (the
        // per-process orbit seed decided whether a run straddled the midpoint,
        // which is why parallel/loaded runs surfaced it). Reduced motion snaps
        // the ease to its target, removing the lag; timestamps stay explicit and
        // deterministic, never the wall clock.
        let settleState = AttacheActivityState(phase: .idle, fleet: fleet)
        _ = motor.pose(at: start.addingTimeInterval(3.0), activity: settleState, reduceMotion: true)
        let before = motor.fleet(activity: settleState, reduceMotion: true)
            .first { $0.sessionID == "c1" }!.position

        fleet[0].isFocused = false
        fleet[1].isFocused = true
        let flipState = AttacheActivityState(phase: .idle, fleet: fleet)
        _ = motor.pose(at: start.addingTimeInterval(3.05), activity: flipState, reduceMotion: true)
        let pinned = motor.fleet(activity: flipState, reduceMotion: true)
            .first { $0.sessionID == "c1" }!

        XCTAssertTrue(pinned.draggable)
        let center = AttacheCharacterChoreography.ringCenter
        let angleBefore = atan2(Double(before.y - center.y), Double(before.x - center.x))
        let angleAfter = atan2(Double(pinned.position.y - center.y), Double(pinned.position.x - center.x))
        let expected = AttacheCharacterChoreography.clampToOuterTrack(angleBefore)
        XCTAssertLessThan(abs(angleAfter - expected), 0.35,
                          "focusing a mote promotes it outward at the angle where it sat")
    }

    func testStareAimsAtThePinnedFocusAndGlancesAtNews() {
        let motor = AttacheCharacterMotor()
        var fleet = [session("c0", focused: true), session("c1")]
        let start = Date(timeIntervalSinceReferenceDate: 50_000)
        var pose = AttachePose.neutral
        for tick in 0..<40 {
            let state = AttacheActivityState(phase: .idle, fleet: fleet)
            pose = motor.pose(at: start.addingTimeInterval(Double(tick) * 0.05),
                              activity: state, reduceMotion: false)
            _ = motor.fleet(activity: state, reduceMotion: false)
        }
        XCTAssertGreaterThan(pose.gaze.height, 1.5,
                             "the default pin is below the head, so the stare looks down")

        fleet[1].state = .blocked
        for tick in 40..<44 {
            let state = AttacheActivityState(phase: .idle, fleet: fleet)
            pose = motor.pose(at: start.addingTimeInterval(Double(tick) * 0.05),
                              activity: state, reduceMotion: false)
            _ = motor.fleet(activity: state, reduceMotion: false)
        }
        XCTAssertGreaterThan(pose.browWorry, 0.3,
                             "a fresh needs-you steals a worried glance")
    }

    func testGlyphStates() {
        let motor = AttacheCharacterMotor()
        var fleet = [session("c0"), session("c1"), session("c2")]
        fleet[1].state = .blocked
        fleet[2].state = .finished
        let motes = runMotor(motor, fleet: fleet, ticks: 10)
        let blocked = motes.first { $0.sessionID == "c1" }
        let finished = motes.first { $0.sessionID == "c2" }
        XCTAssertEqual(blocked?.glyph, .question)
        XCTAssertEqual(blocked?.fill, .blocked)
        XCTAssertEqual(finished?.glyph, .check)
        XCTAssertEqual(finished?.fill, .agent(.claude))
    }

    func testGlyphMotesSitOnTheOuterTrack() {
        let motor = AttacheCharacterMotor()
        var fleet = [session("c0"), session("c1")]
        fleet[0].state = .blocked
        fleet[1].state = .finished
        let motes = runMotor(motor, fleet: fleet, ticks: 60)
        for mote in motes where mote.glyph != .none {
            let dx = (mote.position.x - AttacheCharacterChoreography.ringCenter.x)
                / AttacheCharacterChoreography.outerRingRadii.width
            let dy = (mote.position.y - AttacheCharacterChoreography.ringCenter.y)
                / AttacheCharacterChoreography.outerRingRadii.height
            XCTAssertEqual(dx * dx + dy * dy, 1, accuracy: 0.05,
                           "glyph motes live on the outer track, out of orbit traffic")
            XCTAssertFalse(mote.behind, "glyph motes always draw in front")
            XCTAssertTrue(mote.draggable, "glyph motes can be repositioned")
        }
    }

    func testOuterTrackKeepsTheCrownClear() {
        let crownMiddle = -Double.pi / 2
        let clamped = AttacheCharacterChoreography.clampToOuterTrack(crownMiddle)
        XCTAssertTrue(clamped <= AttacheCharacterChoreography.crownDeadZone.0
                        || clamped >= AttacheCharacterChoreography.crownDeadZone.1,
                      "an angle under the crown clamps to the nearest edge")
        XCTAssertEqual(AttacheCharacterChoreography.clampToOuterTrack(.pi / 2), .pi / 2,
                       "angles outside the dead zone pass through")
    }

    func testDraggingRepinsAGlyphMote() {
        let motor = AttacheCharacterMotor()
        var fleet = [session("c0"), session("c1")]
        fleet[1].state = .blocked
        _ = runMotor(motor, fleet: fleet, ticks: 30)
        motor.setDraggedAngle(sessionID: "c1", angle: .pi)
        let motes = runMotor(motor, fleet: fleet, ticks: 40)
        let target = AttacheCharacterChoreography.outerRingPoint(angle: .pi)
        let blocked = motes.first { $0.sessionID == "c1" }!
        XCTAssertLessThan(abs(blocked.position.x - target.x) + abs(blocked.position.y - target.y), 2,
                          "a dragged glyph mote settles at its new angle")
    }

    func testFinishedNeverMergesIntoTheBadge() {
        var fleet = (0..<12).map { session("c\($0)") }
        fleet[11].state = .finished
        let layout = AttacheFleetLayout.compute(fleet: fleet)
        let group = layout.groups[.claude]
        XCTAssertEqual(group?.orbitingBadgeCount, 11)
        XCTAssertEqual(group?.finished.map(\.id), ["c11"])
    }

    func testOrbitSplitsAcrossTheBubbleDepth() {
        let motor = AttacheCharacterMotor()
        let fleet = [session("c0")]
        let start = Date(timeIntervalSinceReferenceDate: 50_000)
        var sawBehind = false, sawFront = false
        for tick in 0..<160 {
            let state = AttacheActivityState(phase: .idle, fleet: fleet)
            _ = motor.pose(at: start.addingTimeInterval(Double(tick) * 0.05),
                           activity: state, reduceMotion: false)
            for mote in motor.fleet(activity: state, reduceMotion: false) {
                if mote.behind { sawBehind = true } else { sawFront = true }
            }
        }
        XCTAssertTrue(sawBehind, "the orbit's far half passes behind the bubble")
        XCTAssertTrue(sawFront, "the orbit's near half passes in front")
    }

    func testMotorSpawnsLeaversAtTheBadge() {
        let motor = AttacheCharacterMotor()
        var fleet = (0..<10).map { session("c\($0)") }
        _ = runMotor(motor, fleet: fleet, ticks: 10)
        fleet[9].state = .quiet
        let motes = runMotor(motor, fleet: fleet, ticks: 1)
        let parked = motes.first { $0.sessionID == "c9" }
        XCTAssertNotNil(parked, "the leaver appears individually")
        let badge = motes.first { $0.count != nil && $0.opacity == 1 }
        XCTAssertEqual(badge?.count, 9, "the badge count drops as the leaver departs")
    }
}
