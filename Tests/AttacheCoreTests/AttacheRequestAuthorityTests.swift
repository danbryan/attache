import AttacheCore
import XCTest

final class AttacheRequestAuthorityTests: XCTestCase {

    // MARK: - Precedence

    func testSelectedPersonalityBeatsLegacyAndDefault() {
        let resolved = AttacheRequestAuthority.resolvedProfilePrompt(
            testOverride: nil,
            selectedPersonalityPrompt: "You are Colt, a trail boss.",
            migratedLegacyPrompt: "You are a legacy peer.",
            fallback: AttachePersonality.defaultProfilePrompt
        )
        XCTAssertEqual(resolved, "You are Colt, a trail boss.")
    }

    func testSentinel_SelectedPersonalityWinsOverConflictingLegacy() {
        // The verified problem: legacy AttachePersonaStore state holds one
        // prompt while the user selected a different personality. The selected
        // personality must win for every role.
        let resolved = AttacheRequestAuthority.resolvedProfilePrompt(
            testOverride: nil,
            selectedPersonalityPrompt: "Selected: big-picture robot.",
            migratedLegacyPrompt: "Legacy: old file prompt the user abandoned.",
            fallback: AttachePersonality.defaultProfilePrompt
        )
        XCTAssertEqual(resolved, "Selected: big-picture robot.")
    }

    func testTestOverrideBeatsSelectedAndLegacy() {
        let resolved = AttacheRequestAuthority.resolvedProfilePrompt(
            testOverride: "TEST OVERRIDE PROMPT",
            selectedPersonalityPrompt: "Selected prompt",
            migratedLegacyPrompt: "Legacy prompt"
        )
        XCTAssertEqual(resolved, "TEST OVERRIDE PROMPT")
    }

    func testEmptyTestOverrideFallsThroughToSelected() {
        let resolved = AttacheRequestAuthority.resolvedProfilePrompt(
            testOverride: "   ",
            selectedPersonalityPrompt: "Selected prompt",
            migratedLegacyPrompt: "Legacy prompt"
        )
        XCTAssertEqual(resolved, "Selected prompt")
    }

    func testMigratedLegacyUsedOnlyWhenNoSelectedValue() {
        let resolved = AttacheRequestAuthority.resolvedProfilePrompt(
            testOverride: nil,
            selectedPersonalityPrompt: "",
            migratedLegacyPrompt: "Migrated legacy prompt",
            fallback: AttachePersonality.defaultProfilePrompt
        )
        XCTAssertEqual(resolved, "Migrated legacy prompt")
    }

    func testBuiltInDefaultWhenNothingElseExists() {
        let resolved = AttacheRequestAuthority.resolvedProfilePrompt(
            testOverride: nil,
            selectedPersonalityPrompt: "",
            migratedLegacyPrompt: nil,
            fallback: AttachePersonality.defaultProfilePrompt
        )
        XCTAssertEqual(resolved, AttachePersonality.defaultProfilePrompt)
    }

    func testEmptyMigratedLegacyFallsToDefault() {
        let resolved = AttacheRequestAuthority.resolvedProfilePrompt(
            testOverride: nil,
            selectedPersonalityPrompt: "",
            migratedLegacyPrompt: "   ",
            fallback: AttachePersonality.defaultProfilePrompt
        )
        XCTAssertEqual(resolved, AttachePersonality.defaultProfilePrompt)
    }

    // MARK: - Resolved personality

    func testResolvedPersonalityUsesSelected() {
        let resolved = AttacheRequestAuthority.resolvedPersonality(
            selected: ("builtin.cowboy", "Colt prompt"),
            migratedLegacy: ("custom.migrated", "Legacy prompt")
        )
        XCTAssertEqual(resolved.id, "builtin.cowboy")
        XCTAssertEqual(resolved.prompt, "Colt prompt")
    }

    func testResolvedPersonalityFallsToMigratedWhenNoSelection() {
        let resolved = AttacheRequestAuthority.resolvedPersonality(
            selected: nil,
            migratedLegacy: ("custom.migrated", "Legacy prompt")
        )
        XCTAssertEqual(resolved.id, "custom.migrated")
        XCTAssertEqual(resolved.prompt, "Legacy prompt")
    }

    func testResolvedPersonalityFallsToBuiltInDefault() {
        let resolved = AttacheRequestAuthority.resolvedPersonality(
            selected: nil,
            migratedLegacy: nil
        )
        XCTAssertEqual(resolved.id, "builtin.bigPicture")
        XCTAssertEqual(resolved.prompt, AttachePersonality.defaultProfilePrompt)
    }

    func testResolvedPersonalityIgnoresBlankSelectedID() {
        let resolved = AttacheRequestAuthority.resolvedPersonality(
            selected: ("  ", "prompt"),
            migratedLegacy: ("custom.migrated", "Legacy prompt")
        )
        XCTAssertEqual(resolved.id, "custom.migrated")
    }

    // MARK: - Session authorization per role

    func testContextFreeNeverAuthorizesSessionContext() {
        for role in AttacheRequestRole.allCases {
            XCTAssertFalse(
                AttacheRequestAuthority.roleMayUseSessionContext(role, authorization: .contextFree),
                "Role \(role) must not use session context when no session is focused."
            )
        }
    }

    func testTopicTaggingNeverUsesSessionContextEvenWhenFocused() {
        let focused = AttacheSessionAuthorization.focused(AttacheFocusedSession(
            sessionID: "s1", sourceKind: "codex", displayTitle: "T", workingDirectory: nil
        ))
        XCTAssertFalse(AttacheRequestAuthority.roleMayUseSessionContext(.topicTagging, authorization: focused))
    }

    func testUserFacingRolesUseSessionContextWhenFocused() {
        let focused = AttacheSessionAuthorization.focused(AttacheFocusedSession(
            sessionID: "s1", sourceKind: "codex", displayTitle: "T", workingDirectory: nil
        ))
        let userFacing: [AttacheRequestRole] = [.presentation, .conversation, .recap, .followUp, .liveFollowUp, .anotherTake, .preview]
        for role in userFacing {
            XCTAssertTrue(
                AttacheRequestAuthority.roleMayUseSessionContext(role, authorization: focused),
                "Role \(role) should use focused session context."
            )
        }
    }

    func testFocusedSessionIsFrozenByValue() {
        let session = AttacheFocusedSession(
            sessionID: "s1", sourceKind: "codex", displayTitle: "Original", workingDirectory: "/a"
        )
        let auth = AttacheSessionAuthorization.focused(session)
        // A later selection produces a different value; the frozen one is unchanged.
        let later = AttacheSessionAuthorization.focused(AttacheFocusedSession(
            sessionID: "s2", sourceKind: "codex", displayTitle: "Later", workingDirectory: "/b"
        ))
        XCTAssertNotEqual(auth, later)
        XCTAssertEqual(auth.focusedSession?.sessionID, "s1")
        XCTAssertEqual(auth.focusedSession?.displayTitle, "Original")
    }

    // MARK: - Role coverage

    func testAllRolesCovered() {
        // Every role named in INF-304 must exist in the enum so the snapshot
        // can name it and table-driven tests can iterate.
        let expected: Set<AttacheRequestRole> = [
            .presentation, .conversation, .recap, .followUp, .liveFollowUp,
            .anotherTake, .preview, .topicTagging
        ]
        XCTAssertEqual(Set(AttacheRequestRole.allCases), expected)
    }
}