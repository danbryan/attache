import XCTest
@testable import AttacheApp

final class CompanionTipTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "tips-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testOneTipPerLaunch() {
        let engine = CompanionTipEngine(defaults: freshDefaults())
        XCTAssertNotNil(engine.nextTip())
        XCTAssertNil(engine.nextTip(), "second ask in the same launch stays quiet")
    }

    func testTipsNeverRepeatAcrossLaunches() {
        let defaults = freshDefaults()
        var seen: Set<String> = []
        for _ in 0..<(CompanionTip.all.count) {
            let engine = CompanionTipEngine(defaults: defaults)
            guard let tip = engine.nextTip() else { return XCTFail("ran dry early") }
            XCTAssertFalse(seen.contains(tip.id), "tip \(tip.id) repeated")
            seen.insert(tip.id)
        }
        let exhausted = CompanionTipEngine(defaults: defaults)
        XCTAssertNil(exhausted.nextTip(), "all tips seen, engine stays quiet")
    }

    func testResetBringsTipsBack()  {
        let defaults = freshDefaults()
        let engine = CompanionTipEngine(defaults: defaults)
        _ = engine.nextTip()
        engine.resetSeen()
        XCTAssertNotNil(engine.nextTip())
    }

    func testEveryTipMentionsSomethingActionable() {
        for tip in CompanionTip.all {
            XCTAssertTrue(tip.text.hasPrefix("Tip:"), tip.id)
            XCTAssertLessThan(tip.text.count, 120, "\(tip.id) too long for a chip")
        }
    }
}
