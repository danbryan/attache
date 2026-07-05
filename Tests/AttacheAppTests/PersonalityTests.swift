import XCTest
@testable import AttacheApp

final class PersonalityTests: XCTestCase {
    func testWelcomeArchetypesExistWithSubstantivePrompts() {
        for id in ["builtin.explainer", "builtin.bigPicture", "builtin.inquisitive"] {
            let personality = Personality.builtIns.first { $0.id == id }
            XCTAssertNotNil(personality, "\(id) missing from builtins")
            XCTAssertGreaterThan(personality?.prompt.count ?? 0, 120, "\(id) prompt is too thin")
        }
    }

    func testStoreMergesNewBuiltinsIntoOlderLists() {
        let suite = UserDefaults(suiteName: "personality-merge-test")!
        suite.removePersistentDomain(forName: "personality-merge-test")
        let store = PersonalityStore(defaults: suite)

        // Simulate an install persisted before Big Picture and Inquisitive existed.
        let old = Personality.builtIns.filter { !["builtin.bigPicture", "builtin.inquisitive"].contains($0.id) }
            + [Personality(id: "custom.mine", name: "Mine", prompt: "Be nice.")]
        store.save(old, activeID: "custom.mine")

        let loaded = store.load()
        XCTAssertTrue(loaded.personalities.contains { $0.id == "builtin.bigPicture" })
        XCTAssertTrue(loaded.personalities.contains { $0.id == "builtin.inquisitive" })
        XCTAssertTrue(loaded.personalities.contains { $0.id == "custom.mine" })
        XCTAssertEqual(loaded.activeID, "custom.mine")
        suite.removePersistentDomain(forName: "personality-merge-test")
    }
}
