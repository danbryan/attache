import XCTest
@testable import AttacheCore

final class CompanionActivityDamperTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func state(
        _ phase: CompanionActivityPhase,
        agent: CompanionAgentIdentity = .codex,
        toolKind: CompanionToolKind? = nil
    ) -> CompanionActivityState {
        CompanionActivityState(phase: phase, activeAgent: agent, toolKind: toolKind)
    }

    /// The ticket's synthetic burst: a storm flapping between toolRunning and
    /// agentThinking every 300 ms must render as sustained activity, never
    /// strobing faster than the dwell.
    func testRapidToolThinkingBurstDoesNotStrobe() {
        let damper = CompanionActivityDamper(ambientDwell: 1.2, toolKindDwell: 2.0)
        var changes = 0
        var lastPhase: CompanionActivityPhase?
        var lastChangeAt = start
        var minimumGap = TimeInterval.greatestFiniteMagnitude

        for tick in 0..<40 {
            let now = start.addingTimeInterval(Double(tick) * 0.3)
            let proposed = tick % 2 == 0
                ? state(.toolRunning, toolKind: .shell)
                : state(.agentThinking)
            let output = damper.damp(proposed, now: now)
            if let previous = lastPhase, previous != output.phase {
                changes += 1
                minimumGap = min(minimumGap, now.timeIntervalSince(lastChangeAt))
                lastChangeAt = now
            } else if lastPhase == nil {
                lastChangeAt = now
            }
            lastPhase = output.phase
        }

        XCTAssertGreaterThan(changes, 0, "dwell must not freeze the output forever")
        XCTAssertGreaterThanOrEqual(minimumGap, 1.2, "phases flipped faster than the ambient dwell")
    }

    func testToolKindStormHoldsTheKind() {
        let damper = CompanionActivityDamper(ambientDwell: 1.2, toolKindDwell: 2.0)
        let kinds: [CompanionToolKind] = [.shell, .read, .edit, .web]
        var kindChanges = 0
        var lastKind: CompanionToolKind?
        var lastKindChangeAt = start
        var minimumGap = TimeInterval.greatestFiniteMagnitude

        for tick in 0..<30 {
            let now = start.addingTimeInterval(Double(tick) * 0.4)
            let output = damper.damp(state(.toolRunning, toolKind: kinds[tick % kinds.count]), now: now)
            XCTAssertEqual(output.phase, .toolRunning)
            if let previous = lastKind, previous != output.toolKind {
                kindChanges += 1
                minimumGap = min(minimumGap, now.timeIntervalSince(lastKindChangeAt))
                lastKindChangeAt = now
            } else if lastKind == nil {
                lastKindChangeAt = now
            }
            lastKind = output.toolKind
        }

        XCTAssertGreaterThan(kindChanges, 0)
        XCTAssertGreaterThanOrEqual(minimumGap, 2.0, "tool kind flipped faster than its dwell")
    }

    func testBlockedSwitchesInstantlyBothWays() {
        let damper = CompanionActivityDamper()
        _ = damper.damp(state(.toolRunning, toolKind: .shell), now: start)
        let blocked = damper.damp(
            state(.blockedOnUser, agent: .claude),
            now: start.addingTimeInterval(0.1)
        )
        XCTAssertEqual(blocked.phase, .blockedOnUser)
        XCTAssertEqual(blocked.activeAgent, .claude)
        let back = damper.damp(
            state(.agentThinking, agent: .codex),
            now: start.addingTimeInterval(0.2)
        )
        XCTAssertEqual(back.phase, .agentThinking)
    }

    func testSpeakingInterruptsAmbientImmediately() {
        let damper = CompanionActivityDamper()
        _ = damper.damp(state(.agentThinking), now: start)
        let speaking = damper.damp(
            state(.speaking, agent: .claude),
            now: start.addingTimeInterval(0.05)
        )
        XCTAssertEqual(speaking.phase, .speaking)
    }

    func testHeldPhaseKeepsItsAgentButUpdatesPassThrough() {
        let damper = CompanionActivityDamper(ambientDwell: 1.2, toolKindDwell: 2.0)
        _ = damper.damp(state(.toolRunning, agent: .codex, toolKind: .shell), now: start)
        var proposed = state(.agentThinking, agent: .claude)
        proposed.unreadCount = 5
        proposed.userTyping = true
        let held = damper.damp(proposed, now: start.addingTimeInterval(0.4))
        XCTAssertEqual(held.phase, .toolRunning)
        XCTAssertEqual(held.activeAgent, .codex)
        XCTAssertEqual(held.unreadCount, 5)
        XCTAssertTrue(held.userTyping)
    }

    func testAmbientSwitchLandsAfterTheDwell() {
        let damper = CompanionActivityDamper(ambientDwell: 1.2, toolKindDwell: 2.0)
        _ = damper.damp(state(.toolRunning, toolKind: .shell), now: start)
        let after = damper.damp(
            state(.agentThinking, agent: .claude),
            now: start.addingTimeInterval(1.3)
        )
        XCTAssertEqual(after.phase, .agentThinking)
        XCTAssertEqual(after.activeAgent, .claude)
    }

    func testMomentShelfLifeIsGenerousEnoughToQueueBehindNarration() {
        XCTAssertGreaterThanOrEqual(CompanionActivityMoment.shelfLife, 5)
    }
}
