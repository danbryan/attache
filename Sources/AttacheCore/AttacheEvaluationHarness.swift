import Foundation

/// One synthetic capability profile for the evaluation harness (INF-330).
public struct AttacheEvaluationProfile: Equatable, Sendable {
    public let name: String
    public let capability: AttacheModelCapabilityProfile
    public let strategy: AttacheContextStrategy

    public init(name: String, capability: AttacheModelCapabilityProfile, strategy: AttacheContextStrategy) {
        self.name = name
        self.capability = capability
        self.strategy = strategy
    }
}

/// The result of one evaluation scenario (INF-330). Content-free.
public struct AttacheEvaluationScenarioResult: Equatable, Sendable {
    public let scenarioID: String
    public let profileName: String
    public let passed: Bool
    public let metrics: [String: Double]
    public let violations: [String]

    public init(scenarioID: String, profileName: String, passed: Bool, metrics: [String: Double], violations: [String] = []) {
        self.scenarioID = scenarioID
        self.profileName = profileName
        self.passed = passed
        self.metrics = metrics
        self.violations = violations
    }
}

/// The full evaluation report (INF-330). Content-free: no source text, no
/// secrets, no raw private reasoning.
public struct AttacheEvaluationReport: Equatable, Sendable {
    public let scenarioResults: [AttacheEvaluationScenarioResult]
    public let allPassed: Bool
    public let totalScenarios: Int
    public let passedCount: Int
    public let failedCount: Int

    public init(scenarioResults: [AttacheEvaluationScenarioResult]) {
        self.scenarioResults = scenarioResults
        self.allPassed = scenarioResults.allSatisfy { $0.passed }
        self.totalScenarios = scenarioResults.count
        self.passedCount = scenarioResults.filter { $0.passed }.count
        self.failedCount = scenarioResults.filter { !$0.passed }.count
    }

    /// Serialize to a concise human-readable report (INF-330). No source text
    /// or secrets.
    public func humanReport() -> String {
        var lines: [String] = []
        lines.append("Context Management Evaluation Report")
        lines.append("Total: \(totalScenarios), Passed: \(passedCount), Failed: \(failedCount)")
        lines.append(allPassed ? "ALL PASSED" : "FAILURES DETECTED")
        for result in scenarioResults where !result.passed {
            lines.append("  FAIL: \(result.scenarioID) [\(result.profileName)] - \(result.violations.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    /// Serialize to machine-readable JSON (INF-330). No source text or secrets.
    public func jsonReport() -> String {
        let scenarios = scenarioResults.map { result in
            "\"\(result.scenarioID)\":{\"profile\":\"\(result.profileName)\",\"passed\":\(result.passed),\"violations\":\(result.violations.count)}"
        }
        return "{\(scenarios.joined(separator: ","))}"
    }
}

/// The pure deterministic evaluation harness (INF-330). One reproducible,
/// offline gate that measures context safety, budget compliance, retrieval
/// coverage, answer support, and mode behavior across constrained and frontier
/// synthetic models. No network or paid inference.
public enum AttacheEvaluationHarness {

    /// Synthetic capability profiles (INF-330). 8K, 64K, 1M, 10M, and unknown.
    public static let profiles: [AttacheEvaluationProfile] = [
        AttacheEvaluationProfile(name: "8K-efficient",
            capability: AttacheModelCapabilityProfile(architecturalMaximum: 8_000, confidence: .authoritative, provenance: .providerMetadata),
            strategy: .efficient),
        AttacheEvaluationProfile(name: "8K-automatic",
            capability: AttacheModelCapabilityProfile(architecturalMaximum: 8_000, confidence: .authoritative, provenance: .providerMetadata),
            strategy: .automatic),
        AttacheEvaluationProfile(name: "64K-automatic",
            capability: AttacheModelCapabilityProfile(architecturalMaximum: 64_000, confidence: .authoritative, provenance: .providerMetadata),
            strategy: .automatic),
        AttacheEvaluationProfile(name: "1M-maximum",
            capability: AttacheModelCapabilityProfile(architecturalMaximum: 1_000_000, confidence: .authoritative, provenance: .providerMetadata),
            strategy: .maximumCoverage),
        AttacheEvaluationProfile(name: "10M-maximum",
            capability: AttacheModelCapabilityProfile(architecturalMaximum: 10_000_000, confidence: .authoritative, provenance: .providerMetadata),
            strategy: .maximumCoverage),
        AttacheEvaluationProfile(name: "unknown-automatic",
            capability: AttacheModelCapabilityProfile(architecturalMaximum: nil, confidence: .unknown, provenance: .unknown),
            strategy: .automatic),
    ]

    // MARK: - Budget Compliance Scenarios

    /// Verify all synthetic profiles stay within their hard limits (INF-330).
    public static func scenarioBudgetCompliance(profile: AttacheEvaluationProfile) -> AttacheEvaluationScenarioResult {
        let input = ContextCompilerInput(
            userInput: "What did the agent do?",
            modelIdentity: ModelIdentity(provider: "synthetic", normalizedEndpoint: "local", requestedModel: profile.name),
            role: .conversation, profilePrompt: "Speak plainly.",
            memoryContext: nil, session: .contextFree
        )
        let items: [AttacheContextItem] = [
            AttacheContextItem(source: .safetyPolicy, content: "Safety.", priority: 100),
            AttacheContextItem(source: .activePersonality, content: "You are Attaché.", priority: 90),
            AttacheContextItem(source: .currentUserTurn, content: "What did the agent do?", priority: 80),
        ]
        do {
            let compiled = try ContextCompiler.compile(
                input: input, items: items, capability: profile.capability, strategy: profile.strategy
            )
            let hardLimit = compiled.budgetPlan.effectiveHardLimit ?? Int.max
            let within = compiled.receipt.totalEstimatedTokens <= hardLimit
            return AttacheEvaluationScenarioResult(
                scenarioID: "budget-compliance", profileName: profile.name,
                passed: within,
                metrics: ["totalTokens": Double(compiled.receipt.totalEstimatedTokens), "hardLimit": Double(hardLimit)],
                violations: within ? [] : ["total exceeds hard limit"]
            )
        } catch {
            return AttacheEvaluationScenarioResult(
                scenarioID: "budget-compliance", profileName: profile.name,
                passed: false, metrics: [:], violations: ["compile error: \(error)"]
            )
        }
    }

    // MARK: - Authorization Leakage Scenarios

    /// Verify no-focus requests leak zero unauthorized source IDs (INF-330).
    public static func scenarioNoFocusLeakage() -> AttacheEvaluationScenarioResult {
        let input = ContextCompilerInput(
            userInput: "What can you tell me?",
            modelIdentity: ModelIdentity(provider: "synthetic", normalizedEndpoint: "local", requestedModel: "test"),
            role: .conversation, profilePrompt: "Speak plainly.",
            memoryContext: nil, session: .contextFree
        )
        let focusedSession = AttacheFocusedSession(sessionID: "secret-sess", sourceKind: "codex", displayTitle: "Secret", workingDirectory: "/secret")
        let items: [AttacheContextItem] = [
            AttacheContextItem(source: .safetyPolicy, content: "Safety.", priority: 100),
            AttacheContextItem(source: .currentUserTurn, content: "What can you tell me?", priority: 80),
            AttacheContextItem(source: .focusedSessionMetadata, content: "Session: secret-sess",
                authorization: .focused(focusedSession), priority: 30),
            AttacheContextItem(source: .toolDefinitions, content: "{}",
                authorization: .focused(focusedSession), priority: 20),
        ]
        do {
            let compiled = try ContextCompiler.compile(
                input: input, items: items,
                capability: AttacheModelCapabilityProfile(architecturalMaximum: 32_000, confidence: .authoritative, provenance: .providerMetadata),
                strategy: .automatic
            )
            let leaked = compiled.receipt.includedSources.contains("focusedSessionMetadata")
                || compiled.receipt.includedSources.contains("toolDefinitions")
            return AttacheEvaluationScenarioResult(
                scenarioID: "no-focus-leakage", profileName: "32K-automatic",
                passed: !leaked,
                metrics: ["includedSources": Double(compiled.receipt.includedSources.count)],
                violations: leaked ? ["unauthorized source included in no-focus compile"] : []
            )
        } catch {
            return AttacheEvaluationScenarioResult(
                scenarioID: "no-focus-leakage", profileName: "32K-automatic",
                passed: false, metrics: [:], violations: ["compile error"]
            )
        }
    }

    // MARK: - Strategy Monotonicity Scenarios

    /// Verify Maximum >= Automatic >= Efficient for evidence inclusion (INF-330).
    public static func scenarioStrategyMonotonicity() -> AttacheEvaluationScenarioResult {
        let input = ContextCompilerInput(
            userInput: "What did the agent do?",
            modelIdentity: ModelIdentity(provider: "synthetic", normalizedEndpoint: "local", requestedModel: "test"),
            role: .conversation, profilePrompt: "Speak plainly.",
            memoryContext: nil, session: .contextFree
        )
        var items: [AttacheContextItem] = [
            AttacheContextItem(source: .safetyPolicy, content: "Safety.", priority: 100),
            AttacheContextItem(source: .activePersonality, content: "You are Attaché.", priority: 90),
            AttacheContextItem(source: .currentUserTurn, content: "What did the agent do?", priority: 80),
        ]
        for i in 0..<20 {
            items.append(AttacheContextItem(
                source: .retrievedTranscriptEvidence,
                content: String(repeating: "evidence \(i) ", count: 5_000),
                priority: 50, treatment: .exactOnly
            ))
        }
        let cap = AttacheModelCapabilityProfile(architecturalMaximum: 1_000_000, confidence: .authoritative, provenance: .providerMetadata)
        let efficient = (try? ContextCompiler.compile(input: input, items: items, capability: cap, strategy: .efficient))
        let automatic = (try? ContextCompiler.compile(input: input, items: items, capability: cap, strategy: .automatic))
        let maximum = (try? ContextCompiler.compile(input: input, items: items, capability: cap, strategy: .maximumCoverage))
        let effCount = efficient?.receipt.includedSources.filter { $0 == "retrievedTranscriptEvidence" }.count ?? 0
        let autoCount = automatic?.receipt.includedSources.filter { $0 == "retrievedTranscriptEvidence" }.count ?? 0
        let maxCount = maximum?.receipt.includedSources.filter { $0 == "retrievedTranscriptEvidence" }.count ?? 0
        let passed = maxCount >= autoCount && autoCount >= effCount
        return AttacheEvaluationScenarioResult(
            scenarioID: "strategy-monotonicity", profileName: "1M",
            passed: passed,
            metrics: ["efficient": Double(effCount), "automatic": Double(autoCount), "maximum": Double(maxCount)],
            violations: passed ? [] : ["monotonicity violated: eff=\(effCount) auto=\(autoCount) max=\(maxCount)"]
        )
    }

    // MARK: - Large Profile Not Small-Capped

    /// Verify large profiles are not held to a universal small cap (INF-330).
    public static func scenarioLargeProfileNotCapped() -> AttacheEvaluationScenarioResult {
        let smallProfile = profiles.first { $0.name == "8K-efficient" }!
        let largeProfile = profiles.first { $0.name == "1M-maximum" }!
        let input = ContextCompilerInput(
            userInput: "test", modelIdentity: ModelIdentity(provider: "synthetic", normalizedEndpoint: "local", requestedModel: "test"),
            role: .conversation, profilePrompt: "test", memoryContext: nil, session: .contextFree
        )
        let items: [AttacheContextItem] = [
            AttacheContextItem(source: .safetyPolicy, content: "Safety.", priority: 100),
            AttacheContextItem(source: .currentUserTurn, content: "test", priority: 80),
        ]
        let smallCompiled = try? ContextCompiler.compile(input: input, items: items, capability: smallProfile.capability, strategy: smallProfile.strategy)
        let largeCompiled = try? ContextCompiler.compile(input: input, items: items, capability: largeProfile.capability, strategy: largeProfile.strategy)
        let smallLimit = smallCompiled?.budgetPlan.effectiveHardLimit ?? 0
        let largeLimit = largeCompiled?.budgetPlan.effectiveHardLimit ?? 0
        let passed = largeLimit > smallLimit
        return AttacheEvaluationScenarioResult(
            scenarioID: "large-not-capped", profileName: "1M-maximum",
            passed: passed,
            metrics: ["smallLimit": Double(smallLimit), "largeLimit": Double(largeLimit)],
            violations: passed ? [] : ["large profile capped to small limit"]
        )
    }

    // MARK: - Effectful Tool At Most Once

    /// Verify effectful tools execute at most once (INF-330).
    public static func scenarioEffectfulOnce() -> AttacheEvaluationScenarioResult {
        var tracker = AttacheToolEffectTracker()
        tracker.recordEffect(toolName: "send_message", callID: "c1")
        let passed = tracker.prohibitsReplay() && !tracker.wasRecorded(toolName: "send_message", callID: "c2")
        return AttacheEvaluationScenarioResult(
            scenarioID: "effectful-once", profileName: "all",
            passed: passed,
            metrics: ["effectfulCount": 1],
            violations: passed ? [] : ["effectful tool replay not prohibited"]
        )
    }

    // MARK: - Memory Scope/Egress Separate

    /// Verify memory scope/egress and session authorization remain separate (INF-330).
    public static func scenarioMemoryScopeEgressSeparate() -> AttacheEvaluationScenarioResult {
        let localRecord = AttacheMemoryRecord(
            id: "m1", statement: "User prefers terse summaries", type: .preference,
            egress: .localOnly, status: .active
        )
        let remoteQuery = AttacheMemorySelectionQuery(
            userTurn: "summaries", personalityID: "robot",
            strategy: .automatic, memoryBudgetTokens: 1000, requestIsRemote: true
        )
        let selection = AttacheMemorySelector.select(query: remoteQuery, records: [localRecord])
        let localNotInRemote = !selection.candidates.contains { $0.record.id == "m1" }
        return AttacheEvaluationScenarioResult(
            scenarioID: "memory-scope-egress", profileName: "all",
            passed: localNotInRemote,
            metrics: ["candidateCount": Double(selection.candidates.count)],
            violations: localNotInRemote ? [] : ["local-only memory leaked to remote request"]
        )
    }

    // MARK: - Incomplete Never Complete

    /// Verify incomplete or failed coverage never scores as complete (INF-330).
    public static func scenarioIncompleteNeverComplete() -> AttacheEvaluationScenarioResult {
        var episodes: [AttacheSessionMapEpisode] = []
        for i in 0..<5 {
            let ep = AttacheSessionMapEpisode(
                episodeID: "ep-\(i)", sessionID: "s1", sourceKind: "codex",
                startTurnOrdinal: i * 5, endTurnOrdinal: i * 5 + 4,
                startTimestamp: Date(timeIntervalSince1970: Double(i)),
                endTimestamp: Date(timeIntervalSince1970: Double(i + 1)),
                turnHashes: ["h\(i)"], lexicalTerms: []
            )
            episodes.append(ep)
        }
        let map = AttacheSessionMap(sessionID: "s1", sourceKind: "codex", episodes: episodes, totalTurnCount: 25, excludedTurnCount: 0)
        var ledger = AttacheExhaustiveReviewCoordinator.buildLedger(from: map, sourceVersion: "v1")
        ledger.entries[0].markComplete(receiptID: "r-0")
        ledger.entries[1].markFailed(reason: "budget")
        ledger.updateOverallStatus()
        let passed = ledger.overallStatus != AttacheReviewOverallStatus.complete
        return AttacheEvaluationScenarioResult(
            scenarioID: "incomplete-never-complete", profileName: "all",
            passed: passed,
            metrics: ["coverage": ledger.coveragePercentage],
            violations: passed ? [] : ["incomplete scored as complete"]
        )
    }

    // MARK: - Report No Secrets

    /// Verify reports contain no secret literals (INF-330). Uses a pre-computed
    /// result set to avoid recursion.
    public static func scenarioReportNoSecrets(results: [AttacheEvaluationScenarioResult]) -> AttacheEvaluationScenarioResult {
        let report = AttacheEvaluationReport(scenarioResults: results)
        let human = report.humanReport()
        let json = report.jsonReport()
        let combined = (human + json).lowercased()
        let secretMarkers = ["api_key", "sk-", "password", "private_key", "bearer ", "-----begin", "secret-sess"]
        let leaked = secretMarkers.filter { combined.contains($0) }
        return AttacheEvaluationScenarioResult(
            scenarioID: "report-no-secrets", profileName: "all",
            passed: leaked.isEmpty,
            metrics: ["leakedCount": Double(leaked.count)],
            violations: leaked.map { "secret marker in report: \($0)" }
        )
    }

    // MARK: - Determinism

    /// Verify repeated runs are deterministic (INF-330). Uses a pre-computed
    /// result set to avoid recursion.
    public static func scenarioDeterminism(run1: [AttacheEvaluationScenarioResult], run2: [AttacheEvaluationScenarioResult]) -> AttacheEvaluationScenarioResult {
        let passed = run1 == run2
        return AttacheEvaluationScenarioResult(
            scenarioID: "determinism", profileName: "all",
            passed: passed,
            metrics: ["scenarioCount": Double(run1.count)],
            violations: passed ? [] : ["repeated runs are not deterministic"]
        )
    }

    // MARK: - Run All

    /// Run all evaluation scenarios (INF-330). Deterministic and offline.
    public static func runAllScenarios() -> [AttacheEvaluationScenarioResult] {
        var results: [AttacheEvaluationScenarioResult] = []
        // Budget compliance for each profile.
        for profile in profiles {
            results.append(scenarioBudgetCompliance(profile: profile))
        }
        // Authorization leakage.
        results.append(scenarioNoFocusLeakage())
        // Strategy monotonicity.
        results.append(scenarioStrategyMonotonicity())
        // Large profile not capped.
        results.append(scenarioLargeProfileNotCapped())
        // Effectful once.
        results.append(scenarioEffectfulOnce())
        // Memory scope/egress.
        results.append(scenarioMemoryScopeEgressSeparate())
        // Incomplete never complete.
        results.append(scenarioIncompleteNeverComplete())
        // Report no secrets (uses the results so far, not recursive).
        results.append(scenarioReportNoSecrets(results: results))
        return results
    }

    /// Run the full harness and return a report (INF-330).
    public static func run() -> AttacheEvaluationReport {
        AttacheEvaluationReport(scenarioResults: runAllScenarios())
    }
}