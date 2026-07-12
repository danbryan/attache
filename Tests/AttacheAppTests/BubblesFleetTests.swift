import XCTest
import AttacheCore
@testable import AttacheApp

final class BubblesFleetTests: XCTestCase {
    private func session(
        _ id: String,
        agent: CompanionAgentIdentity = .claude,
        state: CompanionFleetSession.State = .working,
        focused: Bool = false,
        subAgents: Int = 0
    ) -> CompanionFleetSession {
        CompanionFleetSession(
            id: id, agent: agent, state: state,
            isFocused: focused, activeSubAgents: subAgents, title: id
        )
    }

    func testSmallFleetShowsEveryoneIndividually() {
        let fleet = (0..<4).map { session("c\($0)") }
        let layout = BubblesFleetLayout.compute(fleet: fleet)
        let group = layout.groups[.claude]
        XCTAssertEqual(group?.orbiting.count, 4)
        XCTAssertEqual(group?.orbitingBadgeCount, 0)
    }

    func testLargeWorkingFleetMergesIntoBadge() {
        let fleet = (0..<12).map { session("c\($0)") }
        let layout = BubblesFleetLayout.compute(fleet: fleet)
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
        let layout = BubblesFleetLayout.compute(fleet: fleet)
        let group = layout.groups[.claude]
        XCTAssertEqual(group?.orbiting.count, 3, "focused plus two ripplers stay out front")
        XCTAssertTrue(group?.orbiting.contains { $0.isFocused } ?? false)
        XCTAssertEqual(group?.orbitingBadgeCount, 9, "eight plain plus the overflow rippler")
    }

    func testBlockedSessionsAlwaysIndividual() {
        var fleet = (0..<20).map { session("c\($0)") }
        fleet[5].state = .blocked
        fleet[11].state = .blocked
        let layout = BubblesFleetLayout.compute(fleet: fleet)
        let group = layout.groups[.claude]
        XCTAssertEqual(group?.blocked.count, 2)
        XCTAssertEqual(group?.orbitingBadgeCount, 18)
    }

    func testFocusFlipMovesTheRingNotTheMotes() {
        var fleet = [session("a", state: .quiet), session("b", state: .quiet)]
        fleet[0].isFocused = true
        let before = BubblesFleetLayout.compute(fleet: fleet)
        fleet[0].isFocused = false
        fleet[1].isFocused = true
        let after = BubblesFleetLayout.compute(fleet: fleet)
        XCTAssertEqual(before.groups[.claude]?.parked.map(\.id), ["a", "b"])
        XCTAssertEqual(after.groups[.claude]?.parked.map(\.id), ["a", "b"],
                       "shelf slots are stable across a focus change")
        XCTAssertEqual(after.groups[.claude]?.parked.map(\.isFocused), [false, true])
    }

    func testQuietFleetCollapsesIntoParkedBadge() {
        let fleet = (0..<9).map { session("c\($0)", state: .quiet) }
        let layout = BubblesFleetLayout.compute(fleet: fleet)
        let group = layout.groups[.claude]
        XCTAssertEqual(group?.parked.count, 0)
        XCTAssertEqual(group?.parkedBadgeCount, 9)
    }

    func testAgentsGroupSeparately() {
        let fleet = (0..<3).map { session("c\($0)", agent: .claude) }
            + (0..<2).map { session("x\($0)", agent: .codex) }
        let layout = BubblesFleetLayout.compute(fleet: fleet)
        XCTAssertEqual(layout.groups[.claude]?.orbiting.count, 3)
        XCTAssertEqual(layout.groups[.codex]?.orbiting.count, 2)
        XCTAssertNil(layout.groups[.none])
    }

    // MARK: Motor fleet rendering

    private func activity(fleet: [CompanionFleetSession]) -> CompanionActivityState {
        CompanionActivityState(phase: .idle, fleet: fleet)
    }

    private func runMotor(_ motor: BubblesPetMotor, fleet: [CompanionFleetSession], ticks: Int) -> [BubblesFleetMote] {
        let start = Date(timeIntervalSinceReferenceDate: 50_000)
        var motes: [BubblesFleetMote] = []
        for tick in 0..<ticks {
            _ = motor.pose(at: start.addingTimeInterval(Double(tick) * 0.05),
                           activity: activity(fleet: fleet), reduceMotion: false)
            motes = motor.fleet(activity: activity(fleet: fleet), reduceMotion: false)
        }
        return motes
    }

    func testMotorRendersBadgeWithCountForBigFleet() {
        let motor = BubblesPetMotor()
        let fleet = (0..<30).map { session("c\($0)") }
        let motes = runMotor(motor, fleet: fleet, ticks: 10)
        let badge = motes.first { $0.count != nil }
        XCTAssertEqual(badge?.count, 30)
        XCTAssertTrue(motes.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite })
    }

    func testMotorMarksBlockedAndFocused() {
        let motor = BubblesPetMotor()
        var fleet = (0..<3).map { session("c\($0)") }
        fleet[0].isFocused = true
        fleet[2].state = .blocked
        let motes = runMotor(motor, fleet: fleet, ticks: 10)
        XCTAssertTrue(motes.contains { $0.fill == .focused && $0.ring })
        XCTAssertTrue(motes.contains { $0.fill == .blocked })
    }

    func testMotorRipplesForSubAgents() {
        let motor = BubblesPetMotor()
        let fleet = [session("c0", subAgents: 8)]
        let motes = runMotor(motor, fleet: fleet, ticks: 10)
        XCTAssertTrue(motes.contains { !$0.ripples.isEmpty })
    }

    func testOrbitRidesTheLiftedBubble() {
        func meanOrbitY(phase: CompanionActivityPhase) -> CGFloat {
            let motor = BubblesPetMotor()
            let fleet = [session("c0")]
            let start = Date(timeIntervalSinceReferenceDate: 50_000)
            var ys: [CGFloat] = []
            for tick in 0..<80 {
                let state = CompanionActivityState(phase: phase, activeAgent: .claude, fleet: fleet)
                _ = motor.pose(at: start.addingTimeInterval(Double(tick) * 0.05),
                               activity: state, reduceMotion: false)
                let motes = motor.fleet(activity: state, reduceMotion: false)
                if tick > 40, let mote = motes.first { ys.append(mote.position.y) }
            }
            return ys.reduce(0, +) / CGFloat(ys.count)
        }
        let idleY = meanOrbitY(phase: .idle)
        let respondingY = meanOrbitY(phase: .agentResponding)
        XCTAssertLessThan(respondingY, idleY - 1,
                          "a lifted bubble carries its orbit up with it")
    }

    func testOrbitSplitsAcrossTheBubbleDepth() {
        let motor = BubblesPetMotor()
        let fleet = [session("c0")]
        let start = Date(timeIntervalSinceReferenceDate: 50_000)
        var sawBehind = false, sawFront = false
        for tick in 0..<160 {
            let state = CompanionActivityState(phase: .idle, fleet: fleet)
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
        let motor = BubblesPetMotor()
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
