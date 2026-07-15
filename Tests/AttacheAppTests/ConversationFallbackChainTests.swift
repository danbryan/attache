import XCTest
import AppKit
import AttacheCore
@testable import AttacheApp

/// INF-258 (D5): the opt-in auto-fallback chain for the live call's
/// conversation model. Every rule the ticket's success criteria call out
/// (skip unconfigured, skip unconsented, stop when exhausted, `.auth` never
/// triggers, stickiness for the rest of the call, the primary is retried on
/// the next call) is pure logic in `ConversationFallbackChain.swift`, so
/// these tests exercise it directly with no AppModel, no network, and no
/// timers - the same style `ConversationRecoveryTests` already uses for
/// `ConversationRecovery.classify`.
final class ConversationFallbackChainTests: XCTestCase {

    // MARK: - shouldTrigger: structural proof that .auth (and .other) never trigger

    func testShouldTriggerExactCategorySet() {
        let triggering = Set(ConversationFailureCategory.allCases.filter(ConversationFallbackChain.shouldTrigger))
        XCTAssertEqual(triggering, [.usageOrRateLimit, .modelUnavailable, .transient])
    }

    func testAuthNeverTriggersAcrossEveryKnownCategory() {
        // Structural, not "no test case for it": this loops every case the
        // enum actually has (CaseIterable) rather than a hand-picked list, so
        // a future category is forced through this assertion too.
        for category in ConversationFailureCategory.allCases {
            let triggers = ConversationFallbackChain.shouldTrigger(for: category)
            if category == .auth {
                XCTAssertFalse(triggers, "auth must never trigger auto-fallback")
            }
        }
        XCTAssertFalse(ConversationFallbackChain.shouldTrigger(for: .auth))
    }

    // MARK: - nextCandidate: chain advance rules

    func testNextCandidateSkipsUnconfiguredProviders() {
        let candidate = ConversationFallbackChain.nextCandidate(
            chain: [.ollama, .groq],
            failedProvider: .xai,
            isConfigured: { $0 != .ollama },  // ollama pretends to be unconfigured
            isConsented: { _ in true }
        )
        XCTAssertEqual(candidate, .groq)
    }

    func testNextCandidateSkipsUnconsentedProviders() {
        let candidate = ConversationFallbackChain.nextCandidate(
            chain: [.groq, .ollama],
            failedProvider: .xai,
            isConfigured: { _ in true },
            isConsented: { $0 != .groq }  // groq is configured but not consented
        )
        XCTAssertEqual(candidate, .ollama)
    }

    func testNextCandidateSkipsTheProviderThatJustFailed() {
        // A chain can legitimately list the current primary (e.g. the user
        // reordered without removing it); the walk must never select it back
        // since that's what just failed.
        let candidate = ConversationFallbackChain.nextCandidate(
            chain: [.xai, .groq],
            failedProvider: .xai,
            isConfigured: { _ in true },
            isConsented: { _ in true }
        )
        XCTAssertEqual(candidate, .groq)
    }

    func testNextCandidateReturnsNilWhenChainIsExhausted() {
        let candidate = ConversationFallbackChain.nextCandidate(
            chain: [.groq, .custom],
            failedProvider: .xai,
            isConfigured: { _ in false },
            isConsented: { _ in true }
        )
        XCTAssertNil(candidate)
    }

    func testNextCandidateReturnsNilForEmptyChain() {
        let candidate = ConversationFallbackChain.nextCandidate(
            chain: [],
            failedProvider: .xai,
            isConfigured: { _ in true },
            isConsented: { _ in true }
        )
        XCTAssertNil(candidate)
    }

    func testNextCandidatePicksFirstEligibleEntryInOrder() {
        let candidate = ConversationFallbackChain.nextCandidate(
            chain: [.groq, .ollama, .codexCLI],
            failedProvider: .xai,
            isConfigured: { _ in true },
            isConsented: { _ in true }
        )
        XCTAssertEqual(candidate, .groq, "the first configured+consented entry wins, not just any eligible one")
    }

    // MARK: - announcement: format and dash-safety

    func testAnnouncementFormatForUsageOrRateLimit() {
        let text = ConversationFallbackChain.announcement(
            category: .usageOrRateLimit,
            failedProviderTitle: "xAI / Grok",
            fallbackProviderTitle: "Ollama"
        )
        XCTAssertEqual(text, "xAI / Grok hit its usage limit; using Ollama for now.")
    }

    func testAnnouncementFormatForModelUnavailable() {
        let text = ConversationFallbackChain.announcement(
            category: .modelUnavailable,
            failedProviderTitle: "Groq",
            fallbackProviderTitle: "Ollama"
        )
        XCTAssertEqual(text, "Groq model is unavailable; using Ollama for now.")
    }

    func testAnnouncementFormatForTransient() {
        let text = ConversationFallbackChain.announcement(
            category: .transient,
            failedProviderTitle: "Ollama",
            fallbackProviderTitle: "Codex subscription"
        )
        XCTAssertEqual(text, "Ollama had a connection issue; using Codex subscription for now.")
    }

    func testAnnouncementNeverContainsAnEmDash() {
        for category in ConversationFailureCategory.allCases {
            let text = ConversationFallbackChain.announcement(
                category: category,
                failedProviderTitle: "xAI / Grok",
                fallbackProviderTitle: "Ollama"
            )
            XCTAssertFalse(text.contains("\u{2014}"), "announcement must never contain an em dash: \(text)")
        }
    }

    // MARK: - ConversationFallbackState: stickiness and reset (next-call retry)

    func testAdvanceReturnsCandidateOnFirstTriggeringFailure() {
        var state = ConversationFallbackState()
        let result = state.advance(
            enabled: true,
            category: .usageOrRateLimit,
            chain: [.ollama, .groq],
            failedProvider: .xai,
            isConfigured: { _ in true },
            isConsented: { _ in true }
        )
        XCTAssertEqual(result, .ollama)
        XCTAssertEqual(state.activeProvider, .ollama)
        XCTAssertTrue(state.hasFallenBackThisCall)
    }

    func testAdvanceDoesNothingWhenDisabled() {
        var state = ConversationFallbackState()
        let result = state.advance(
            enabled: false,
            category: .usageOrRateLimit,
            chain: [.ollama],
            failedProvider: .xai,
            isConfigured: { _ in true },
            isConsented: { _ in true }
        )
        XCTAssertNil(result)
        XCTAssertFalse(state.hasFallenBackThisCall)
    }

    func testAdvanceDoesNothingForNonTriggeringCategory() {
        var state = ConversationFallbackState()
        for category: ConversationFailureCategory in [.auth, .other] {
            let result = state.advance(
                enabled: true,
                category: category,
                chain: [.ollama],
                failedProvider: .xai,
                isConfigured: { _ in true },
                isConsented: { _ in true }
            )
            XCTAssertNil(result, "\(category) must never trigger a fallback")
            XCTAssertFalse(state.hasFallenBackThisCall)
        }
    }

    func testAdvanceReturnsNilWhenChainIsExhausted() {
        var state = ConversationFallbackState()
        let result = state.advance(
            enabled: true,
            category: .usageOrRateLimit,
            chain: [.ollama, .groq],
            failedProvider: .xai,
            isConfigured: { _ in false },
            isConsented: { _ in true }
        )
        XCTAssertNil(result)
        XCTAssertFalse(state.hasFallenBackThisCall, "an exhausted chain must land on manual recovery, not a phantom fallback")
    }

    func testAdvanceIsStickyAndNeverRetriggersWithinTheSameCall() {
        var state = ConversationFallbackState()
        let first = state.advance(
            enabled: true,
            category: .usageOrRateLimit,
            chain: [.ollama, .groq],
            failedProvider: .xai,
            isConfigured: { _ in true },
            isConsented: { _ in true }
        )
        XCTAssertEqual(first, .ollama)

        // The fallback provider itself now fails too, with a category that
        // would otherwise trigger a second hop. Sticky: must not advance to
        // .groq, must return nil so the caller falls through to manual
        // recovery instead of silently hopping again.
        let second = state.advance(
            enabled: true,
            category: .usageOrRateLimit,
            chain: [.ollama, .groq],
            failedProvider: .ollama,
            isConfigured: { _ in true },
            isConsented: { _ in true }
        )
        XCTAssertNil(second, "a fallback already active this call must never re-evaluate the chain")
        XCTAssertEqual(state.activeProvider, .ollama, "the sticky fallback must remain in effect even though its own retry also failed")
    }

    func testResetAllowsThePrimaryToBeRetriedOnTheNextCall() {
        var state = ConversationFallbackState()
        _ = state.advance(
            enabled: true,
            category: .transient,
            chain: [.ollama],
            failedProvider: .xai,
            isConfigured: { _ in true },
            isConsented: { _ in true }
        )
        XCTAssertTrue(state.hasFallenBackThisCall)

        // Simulates AppModel.startConversation() at the top of a fresh call.
        state.reset()
        XCTAssertFalse(state.hasFallenBackThisCall)
        XCTAssertNil(state.activeProvider, "the next call must start back on the primary provider, not the previous call's fallback")

        // The chain can advance again from scratch on the new call.
        let result = state.advance(
            enabled: true,
            category: .transient,
            chain: [.ollama],
            failedProvider: .xai,
            isConfigured: { _ in true },
            isConsented: { _ in true }
        )
        XCTAssertEqual(result, .ollama)
    }
}

/// AppModel-level coverage (INF-258/D5): persistence of the two new settings,
/// and the default-off regression guarantee. `AppModel`'s only initializer
/// reads `UserDefaults.standard` directly, so this follows the same
/// snapshot/restore pattern as `PerRoleModelRecoveryAndConsentTests`.
@MainActor
final class ConversationFallbackChainSettingsTests: XCTestCase {
    private let preferenceKeys = [
        AttachePreferenceKey.conversationFallbackChainEnabled,
        AttachePreferenceKey.conversationFallbackChainProviders,
        AttachePreferenceKey.presentationLLMProvider,
        "attache.personalities",
        "attache.activePersonalityID",
        "attache.personalityVoicePetMigrated"
    ]

    func testFallbackChainIsDisabledAndEmptyByDefault() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        let model = try AppModel(store: CardStore.inMemory())

        XCTAssertFalse(model.conversationFallbackChainEnabled, "auto-fallback must default OFF")
        XCTAssertTrue(model.conversationFallbackChain.isEmpty)
    }

    func testFallbackChainSettingsPersistAcrossRelaunch() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        let model = try AppModel(store: CardStore.inMemory())
        model.selectPresentationProvider(.codexCLI)
        model.conversationFallbackChainEnabled = true
        model.addConversationFallbackChainProvider(.ollama)
        model.addConversationFallbackChainProvider(.groq)
        model.captureCurrentModelIntoActivePersonality()

        let relaunched = try AppModel(store: CardStore.inMemory())
        XCTAssertTrue(relaunched.conversationFallbackChainEnabled)
        XCTAssertEqual(relaunched.conversationFallbackChain, [.ollama, .groq])
    }

    func testAddRemoveAndReorderChainProviders() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(keys: preferenceKeys, defaults: defaults)
        defer { snapshot.restore() }

        let model = try AppModel(store: CardStore.inMemory())
        model.addConversationFallbackChainProvider(.ollama)
        model.addConversationFallbackChainProvider(.groq)
        model.addConversationFallbackChainProvider(.ollama)  // duplicate, ignored
        XCTAssertEqual(model.conversationFallbackChain, [.ollama, .groq])

        model.addConversationFallbackChainProvider(.custom)
        model.moveConversationFallbackChainProvider(at: 2, up: true)
        XCTAssertEqual(model.conversationFallbackChain, [.ollama, .custom, .groq])

        model.removeConversationFallbackChainProvider(.custom)
        XCTAssertEqual(model.conversationFallbackChain, [.ollama, .groq])
    }
}

private final class DefaultsSnapshot {
    private let keys: [String]
    private let defaults: UserDefaults
    private let values: [String: Any]

    init(keys: [String], defaults: UserDefaults) {
        self.keys = keys
        self.defaults = defaults
        self.values = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            defaults.object(forKey: key).map { (key, $0) }
        })
        keys.forEach { defaults.removeObject(forKey: $0) }
    }

    func restore() {
        keys.forEach { defaults.removeObject(forKey: $0) }
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
    }
}
