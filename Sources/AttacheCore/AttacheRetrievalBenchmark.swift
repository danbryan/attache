import Foundation

/// The category of a benchmark query (INF-314). Each category stresses a
/// different failure mode so a verdict cannot hide behind a single easy case.
public enum AttacheRetrievalQueryCategory: String, Equatable, Sendable, CaseIterable {
    case exactKeyword
    case paraphrase
    case renamedTopic
    case ambiguousTerm
    case date
    case projectPath
    case adversarialNearMatch
}

/// A sanitized document in the benchmark corpus (INF-314). All content is
/// synthetic. No private session content appears anywhere in the corpus.
public struct AttacheRetrievalDocument: Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let projectPath: String?
    public let updatedAt: Date

    public init(id: String, title: String, body: String, projectPath: String? = nil, updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.id = id
        self.title = title
        self.body = body
        self.projectPath = projectPath
        self.updatedAt = updatedAt
    }
}

/// A sanitized benchmark query with its known-relevant document IDs and the
/// category that stresses a specific failure mode (INF-314).
public struct AttacheRetrievalQuery: Equatable, Sendable {
    public let id: String
    public let text: String
    public let relevantDocIDs: Set<String>
    public let category: AttacheRetrievalQueryCategory

    public init(id: String, text: String, relevantDocIDs: Set<String>, category: AttacheRetrievalQueryCategory) {
        self.id = id
        self.text = text
        self.relevantDocIDs = relevantDocIDs
        self.category = category
    }
}

/// The sanitized evaluation corpus (INF-314). Synthetic content only: exact
/// keyword hits, paraphrases, renamed topics, ambiguous terms, dates, project
/// paths, and adversarial near-matches. No private session content.
public enum AttacheRetrievalCorpus {
    public static let documents: [AttacheRetrievalDocument] = {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return [
            AttacheRetrievalDocument(
                id: "doc-router-dns",
                title: "UniFi router drops DNS forwarding",
                body: "The UniFi U7 Pro Max stopped forwarding DNS for bryanlabs.net after the controller rebuild. The system_ip override got reset and clients fell back to the ISP resolver.",
                projectPath: "/Users/dan/code/bare-metal", updatedAt: base
            ),
            AttacheRetrievalDocument(
                id: "doc-printer-ink",
                title: "Canon MG3620 low ink warning",
                body: "The Canon MG3620 reported a low ink warning on the color cartridge. Reset the ink counter after replacing the cartridge and ran a nozzle check.",
                projectPath: nil, updatedAt: base.addingTimeInterval(60)
            ),
            AttacheRetrievalDocument(
                id: "doc-tax-1120s",
                title: "Bryanlabs 1120-S K-1 reconciliation",
                body: "Reconciled the Bryanlabs S-Corp 1120-S K-1 against the trial balance. The wages expense line matched the year-end payroll summary.",
                projectPath: "/Users/dan/code/local/finops", updatedAt: base.addingTimeInterval(120)
            ),
            AttacheRetrievalDocument(
                id: "doc-hsa-receipt",
                title: "BryanRX HSA qualified medical receipt",
                body: "Filed a qualified medical receipt against the BryanRX HSA for an eye exam. The receipt date was within the plan year.",
                projectPath: "/Users/dan/code/local/finops", updatedAt: base.addingTimeInterval(180)
            ),
            AttacheRetrievalDocument(
                id: "doc-solo401k-rollover",
                title: "BryanVentures Solo 401k rollover contribution",
                body: "Recorded a rolver contribution into the BryanVentures Solo 401k. The custodian confirmed the funds landed in the participant account.",
                projectPath: "/Users/dan/code/local/finops", updatedAt: base.addingTimeInterval(240)
            ),
            AttacheRetrievalDocument(
                id: "doc-haproxy-cert",
                title: "HAProxy wildcard cert renewal",
                body: "Renewed the wildcard bryanlabs.net certificate on pfSense. The HAProxy production-https frontend reloaded with zero dropped connections.",
                projectPath: "/Users/dan/code/bare-metal", updatedAt: base.addingTimeInterval(300)
            ),
            AttacheRetrievalDocument(
                id: "doc-grafana-nodeport",
                title: "Grafana NodePort behind HAProxy",
                body: "Exposed Grafana on a NodePort at 192.168.8.13 and added an HAProxy backend pointing at it. The Route 53 record resolves to the public IP.",
                projectPath: "/Users/dan/code/bare-metal", updatedAt: base.addingTimeInterval(360)
            ),
            AttacheRetrievalDocument(
                id: "doc-voicemail-recap",
                title: "Voicemail recap coalescing pipeline",
                body: "The narration coalescer groups related voicemail cards before speaking a recap. Solved problems compress to their outcome.",
                projectPath: "/Users/dan/code/github.com/danbryan/attache", updatedAt: base.addingTimeInterval(420)
            ),
            AttacheRetrievalDocument(
                id: "doc-karaoke-captions",
                title: "Karaoke caption timing",
                body: "Caption timing follows the speech playback cursor so karaoke captions stay visible during pause and seek. The visualizer reacts to analyzed energy.",
                projectPath: "/Users/dan/code/github.com/danbryan/attache", updatedAt: base.addingTimeInterval(480)
            ),
            AttacheRetrievalDocument(
                id: "doc-personality-unify",
                title: "Unify personality voice and pet",
                body: "A personality is one unit owning brain, voice, visual presence, and model. Switching applies the unit together. Another take re-narrates in a different voice.",
                projectPath: "/Users/dan/code/github.com/danbryan/attache", updatedAt: base.addingTimeInterval(540)
            ),
            AttacheRetrievalDocument(
                id: "doc-two-way-freeze",
                title: "Two-way agent freeze and fail closed",
                body: "A live call freezes the focused session id, source, title, and working directory. Tell Agent applies to one turn then resets. Delivery fails closed on mismatch.",
                projectPath: "/Users/dan/code/github.com/danbryan/attache", updatedAt: base.addingTimeInterval(600)
            ),
            AttacheRetrievalDocument(
                id: "doc-egress-classify",
                title: "Egress classifier for provider data",
                body: "The egress classifier labels where data goes: on-device, loopback, local network, configured remote, subscription remote CLI, unknown custom, or disabled. Custom fails closed.",
                projectPath: "/Users/dan/code/github.com/danbryan/attache", updatedAt: base.addingTimeInterval(660)
            ),
            AttacheRetrievalDocument(
                id: "doc-context-compiler",
                title: "Context compiler budget and receipts",
                body: "Every model role compiles through the context compiler. It plans a budget, fits authorized items, and emits a content-free receipt. Protected content overflows fail loudly.",
                projectPath: "/Users/dan/code/github.com/danbryan/attache", updatedAt: base.addingTimeInterval(720)
            ),
            AttacheRetrievalDocument(
                id: "doc-memory-ledger",
                title: "Structured memory ledger scopes",
                body: "The memory ledger stores typed records with scope and egress labels. Supersession chains forget stale facts. Secret filtering rejects api keys and bearer tokens.",
                projectPath: "/Users/dan/code/github.com/danbryan/attache", updatedAt: base.addingTimeInterval(780)
            ),
            AttacheRetrievalDocument(
                id: "doc-obsidian-vault",
                title: "Obsidian vault operations notes",
                body: "Network topology, home printer setup, and UniFi controller recovery notes live in the private vault under Operations/Systems. Read these before answering from general knowledge.",
                projectPath: nil, updatedAt: base.addingTimeInterval(840)
            ),
            AttacheRetrievalDocument(
                id: "doc-sparkle-appcast",
                title: "Sparkle appcast EdDSA signing",
                body: "The Sparkle appcast is generated and EdDSA-signed by generate_appcast. The private key lives in the login keychain. CFBundleVersion must strictly increase or updates silently stop.",
                projectPath: "/Users/dan/code/github.com/danbryan/attache", updatedAt: base.addingTimeInterval(900)
            ),
            AttacheRetrievalDocument(
                id: "doc-dmg-notarize",
                title: "DMG notarize and staple pipeline",
                body: "The release pipeline signs, notarizes, and staples the app, then wraps and notarizes the DMG. The Homebrew cask sha256 must equal the released DMG sha256.",
                projectPath: "/Users/dan/code/github.com/danbryan/attache", updatedAt: base.addingTimeInterval(960)
            ),
            AttacheRetrievalDocument(
                id: "doc-fts5-index",
                title: "SQLite FTS5 session index recovery",
                body: "The FTS5 index recovers from a corrupt database by deleting and rebuilding. Incremental indexing skips chunks unchanged by mtime and size.",
                projectPath: "/Users/dan/code/github.com/danbryan/attache", updatedAt: base.addingTimeInterval(1020)
            ),
            AttacheRetrievalDocument(
                id: "doc-bundle-main",
                title: "Never use Bundle.module",
                body: "Bundle.module calls fatalError when it cannot resolve the SwiftPM resource bundle. Load bundled resources via Bundle.main or an explicit path with a graceful fallback.",
                projectPath: "/Users/dan/code/github.com/danbryan/attache", updatedAt: base.addingTimeInterval(1080)
            ),
            AttacheRetrievalDocument(
                id: "doc-canon-reset",
                title: "Canon MG3620 factory reset procedure",
                body: "Hold the Stop button until the alarm lamp flashes to factory reset the Canon MG3620. Re-pair over USB before rejoining Wi-Fi. The nozzle check pattern confirms head health.",
                projectPath: nil, updatedAt: base.addingTimeInterval(1140)
            ),
            // Adversarial near-matches: share keywords with other docs but are
            // about different subjects, to stress false-positive rate.
            AttacheRetrievalDocument(
                id: "doc-cert-expiry-monitor",
                title: "Cert expiry monitor for internal services",
                body: "A cert expiry monitor watches the internal services certificate chain. It alerts before the leaf expires. Unrelated to the HAProxy wildcard renewal run.",
                projectPath: "/Users/dan/code/bare-metal", updatedAt: base.addingTimeInterval(1200)
            ),
            AttacheRetrievalDocument(
                id: "doc-ink-supplier-order",
                title: "Ink supplier reorder threshold",
                body: "The office supplier reorder threshold for ink cartridges is two spare color and two spare black. Unrelated to the printer low ink warning itself.",
                projectPath: nil, updatedAt: base.addingTimeInterval(1260)
            ),
            AttacheRetrievalDocument(
                id: "doc-personalities-roster",
                title: "Built-in personality roster",
                body: "The built-in roster is three units. The cowboy uses an on-device voice. The robot is the default. The voice-only unit keeps the original visual bars. No other built-in is shown.",
                projectPath: "/Users/dan/code/github.com/danbryan/attache", updatedAt: base.addingTimeInterval(1320)
            ),
            AttacheRetrievalDocument(
                id: "doc-benchmark-dates",
                title: "Benchmark run on 2026-07-15",
                body: "The retrieval benchmark ran on 2026-07-15 against the sanitized corpus. Latency and recall were recorded for the FTS5 baseline and the lexical reranker candidate.",
                projectPath: "/Users/dan/code/github.com/danbryan/attache", updatedAt: base.addingTimeInterval(1380)
            ),
            AttacheRetrievalDocument(
                id: "doc-tax-extension",
                title: "2025 tax extension filing",
                body: "Filed a 2025 calendar year extension for the S-Corp. The extension grants until September to finalize the 1120-S. Estimated payments were reconciled first.",
                projectPath: "/Users/dan/code/local/finops", updatedAt: base.addingTimeInterval(1440)
            ),
            AttacheRetrievalDocument(
                id: "doc-unifi-controller-restore",
                title: "UniFi controller restore from backup",
                body: "Restored the UniFi controller from a backup after a disk failure. The system_ip override gotcha caught the first boot before the adoption fix was applied.",
                projectPath: "/Users/dan/code/bare-metal", updatedAt: base.addingTimeInterval(1500)
            ),
            AttacheRetrievalDocument(
                id: "doc-voice-compact-only",
                title: "Compact voices onboarding preview",
                body: "ATTACHE_COMPACT_VOICES_ONLY hides premium and enhanced voices to preview the compact-only onboarding. It does not delete installed voices.",
                projectPath: "/Users/dan/code/github.com/danbryan/attache", updatedAt: base.addingTimeInterval(1560)
            ),
            AttacheRetrievalDocument(
                id: "doc-activity-simulator",
                title: "Activity simulator debug panel",
                body: "ATTACHE_ACTIVITY_SIMULATOR shows a debug panel that overrides the activity state. Pick any phase, agent, or tool kind, or cycle through all phases.",
                projectPath: "/Users/dan/code/github.com/danbryan/attache", updatedAt: base.addingTimeInterval(1620)
            ),
            AttacheRetrievalDocument(
                id: "doc-dock-idle",
                title: "Idle dock and menu bar state",
                body: "The app runs in the background like a menu bar utility and optionally shows a translucent window. The dock reaches idle after launch completes.",
                projectPath: "/Users/dan/code/github.com/danbryan/attache", updatedAt: base.addingTimeInterval(1680)
            ),
            AttacheRetrievalDocument(
                id: "doc-keychain-notary",
                title: "Notary keychain profile and app-specific password",
                body: "The notary app-specific password lives in 1Password and loads through the bryanlabs-notary keychain profile. Never print or commit it.",
                projectPath: nil, updatedAt: base.addingTimeInterval(1740)
            ),
        ]
    }()

    public static let queries: [AttacheRetrievalQuery] = [
        AttacheRetrievalQuery(id: "q-exact-1", text: "UniFi DNS forwarding", relevantDocIDs: ["doc-router-dns"], category: .exactKeyword),
        AttacheRetrievalQuery(id: "q-exact-2", text: "1120-S K-1 reconciliation", relevantDocIDs: ["doc-tax-1120s"], category: .exactKeyword),
        AttacheRetrievalQuery(id: "q-exact-3", text: "HAProxy wildcard cert renewal", relevantDocIDs: ["doc-haproxy-cert"], category: .exactKeyword),
        AttacheRetrievalQuery(id: "q-paraphrase-1", text: "the access point stopped resolving local hostnames", relevantDocIDs: ["doc-router-dns"], category: .paraphrase),
        AttacheRetrievalQuery(id: "q-paraphrase-2", text: "combine the character brain and its voice into one thing", relevantDocIDs: ["doc-personality-unify"], category: .paraphrase),
        AttacheRetrievalQuery(id: "q-paraphrase-3", text: "make sure updates never silently break after a release", relevantDocIDs: ["doc-sparkle-appcast"], category: .paraphrase),
        AttacheRetrievalQuery(id: "q-renamed-1", text: "narration engine groups voicemails before speaking", relevantDocIDs: ["doc-voicemail-recap"], category: .renamedTopic),
        AttacheRetrievalQuery(id: "q-renamed-2", text: "privacy labels for where provider data goes", relevantDocIDs: ["doc-egress-classify"], category: .renamedTopic),
        AttacheRetrievalQuery(id: "q-ambiguous-1", text: "ink", relevantDocIDs: ["doc-printer-ink", "doc-canon-reset", "doc-ink-supplier-order"], category: .ambiguousTerm),
        AttacheRetrievalQuery(id: "q-ambiguous-2", text: "cert", relevantDocIDs: ["doc-haproxy-cert", "doc-cert-expiry-monitor"], category: .ambiguousTerm),
        AttacheRetrievalQuery(id: "q-date-1", text: "2026-07-15", relevantDocIDs: ["doc-benchmark-dates"], category: .date),
        AttacheRetrievalQuery(id: "q-date-2", text: "2025 tax extension", relevantDocIDs: ["doc-tax-extension"], category: .date),
        AttacheRetrievalQuery(id: "q-path-1", text: "/Users/dan/code/local/finops", relevantDocIDs: ["doc-tax-1120s", "doc-hsa-receipt", "doc-solo401k-rollover", "doc-tax-extension"], category: .projectPath),
        AttacheRetrievalQuery(id: "q-path-2", text: "/Users/dan/code/bare-metal", relevantDocIDs: ["doc-router-dns", "doc-haproxy-cert", "doc-grafana-nodeport", "doc-cert-expiry-monitor", "doc-unifi-controller-restore"], category: .projectPath),
        AttacheRetrievalQuery(id: "q-adv-1", text: "cert renewal monitor", relevantDocIDs: ["doc-haproxy-cert"], category: .adversarialNearMatch),
        AttacheRetrievalQuery(id: "q-adv-2", text: "ink reorder warning", relevantDocIDs: ["doc-printer-ink"], category: .adversarialNearMatch),
        AttacheRetrievalQuery(id: "q-adv-3", text: "UniFi controller system ip override", relevantDocIDs: ["doc-unifi-controller-restore"], category: .adversarialNearMatch),
        AttacheRetrievalQuery(id: "q-adv-4", text: "personality roster built in voices", relevantDocIDs: ["doc-personalities-roster"], category: .adversarialNearMatch),
        AttacheRetrievalQuery(id: "q-exact-4", text: "context compiler budget receipt", relevantDocIDs: ["doc-context-compiler"], category: .exactKeyword),
        AttacheRetrievalQuery(id: "q-exact-5", text: "memory ledger secret filtering", relevantDocIDs: ["doc-memory-ledger"], category: .exactKeyword),
    ]
}

/// Predeclared thresholds (INF-314). These are written BEFORE any results are
/// interpreted, so the verdict cannot be rationalized after the fact. A
/// candidate that misses any hard gate cannot ship.
public struct AttacheRetrievalThresholds: Equatable, Sendable {
    public let minRecallAt5: Double
    public let minMRR: Double
    public let maxFalsePositiveRate: Double
    public let maxKeywordRecallRegression: Double
    public let maxColdQueryLatencyMs: Double
    public let maxWarmQueryLatencyMs: Double
    public let maxIndexTimeMs: Double
    public let maxMemoryMB: Double
    public let maxBundleMB: Double
    public let maxEnergyScore: Double

    public init(
        minRecallAt5: Double, minMRR: Double, maxFalsePositiveRate: Double,
        maxKeywordRecallRegression: Double,
        maxColdQueryLatencyMs: Double, maxWarmQueryLatencyMs: Double,
        maxIndexTimeMs: Double, maxMemoryMB: Double,
        maxBundleMB: Double, maxEnergyScore: Double
    ) {
        self.minRecallAt5 = minRecallAt5
        self.minMRR = minMRR
        self.maxFalsePositiveRate = maxFalsePositiveRate
        self.maxKeywordRecallRegression = maxKeywordRecallRegression
        self.maxColdQueryLatencyMs = maxColdQueryLatencyMs
        self.maxWarmQueryLatencyMs = maxWarmQueryLatencyMs
        self.maxIndexTimeMs = maxIndexTimeMs
        self.maxMemoryMB = maxMemoryMB
        self.maxBundleMB = maxBundleMB
        self.maxEnergyScore = maxEnergyScore
    }

    /// The default predeclared thresholds (INF-314). A candidate semantic
    /// reranker must clear every gate to be worth shipping. Keyword-heavy cases
    /// cannot regress materially (maxKeywordRecallRegression caps the allowed
    /// drop vs the FTS baseline).
    public static let predeclared = AttacheRetrievalThresholds(
        minRecallAt5: 0.70,
        minMRR: 0.55,
        maxFalsePositiveRate: 0.15,
        maxKeywordRecallRegression: 0.05,
        maxColdQueryLatencyMs: 250,
        maxWarmQueryLatencyMs: 60,
        maxIndexTimeMs: 2_000,
        maxMemoryMB: 120,
        maxBundleMB: 50,
        maxEnergyScore: 3.0
    )
}

/// Metrics for one candidate over the corpus (INF-314). All purely computed
/// from the ranked result lists and the known-relevant document IDs.
public struct AttacheRetrievalMetrics: Equatable, Sendable {
    public let recallAt5: Double
    public let mrr: Double
    public let falsePositiveRate: Double
    public let keywordRecallAt5: Double

    public init(recallAt5: Double, mrr: Double, falsePositiveRate: Double, keywordRecallAt5: Double) {
        self.recallAt5 = recallAt5
        self.mrr = mrr
        self.falsePositiveRate = falsePositiveRate
        self.keywordRecallAt5 = keywordRecallAt5
    }

    /// Compute metrics from per-query ranked document IDs and the queries they
    /// answer (INF-314). Pure and deterministic.
    public static func compute(
        rankedDocIDsPerQuery: [(query: AttacheRetrievalQuery, rankedDocIDs: [String])],
        k: Int = 5
    ) -> AttacheRetrievalMetrics {
        guard !rankedDocIDsPerQuery.isEmpty else {
            return AttacheRetrievalMetrics(recallAt5: 0, mrr: 0, falsePositiveRate: 1, keywordRecallAt5: 0)
        }
        var recallSum = 0.0
        var reciprocalRankSum = 0.0
        var falsePositives = 0
        var consideredSlots = 0
        var keywordRecallSum = 0.0
        var keywordCount = 0

        for entry in rankedDocIDsPerQuery {
            let relevant = entry.query.relevantDocIDs
            let topK = Array(entry.rankedDocIDs.prefix(k))
            let hitsInTopK = topK.filter { relevant.contains($0) }.count
            if relevant.isEmpty {
                recallSum += 1.0
            } else {
                recallSum += Double(hitsInTopK) / Double(relevant.count)
            }
            if let firstRelevantRank = entry.rankedDocIDs.firstIndex(where: { relevant.contains($0) }) {
                reciprocalRankSum += 1.0 / Double(firstRelevantRank + 1)
            }
            for docID in topK where !relevant.contains(docID) {
                falsePositives += 1
            }
            consideredSlots += topK.count
            if entry.query.category == .exactKeyword {
                if relevant.isEmpty {
                    keywordRecallSum += 1.0
                } else {
                    keywordRecallSum += Double(hitsInTopK) / Double(relevant.count)
                }
                keywordCount += 1
            }
        }

        let n = Double(rankedDocIDsPerQuery.count)
        let recall = recallSum / n
        let mrr = reciprocalRankSum / n
        let fpr = consideredSlots > 0 ? Double(falsePositives) / Double(consideredSlots) : 1.0
        let keywordRecall = keywordCount > 0 ? keywordRecallSum / Double(keywordCount) : 0
        return AttacheRetrievalMetrics(
            recallAt5: recall, mrr: mrr, falsePositiveRate: fpr, keywordRecallAt5: keywordRecall
        )
    }
}

/// A measured candidate (INF-314).
public enum AttacheRetrievalCandidateKind: String, Equatable, Sendable, CaseIterable {
    case ftsOnly
    case lexicalReranker
    case hybrid
}

/// Laptop-class runtime measurements (INF-314). Captured on the benchmark
/// machine and attached to the report. Zero on a clean run means not measured.
public struct AttacheRetrievalRuntime: Equatable, Sendable {
    public let coldQueryLatencyMs: Double
    public let warmQueryLatencyMs: Double
    public let indexTimeMs: Double
    public let memoryMB: Double
    public let bundleMB: Double
    public let energyScore: Double
    public let hardware: String
    public let osVersion: String
    public let offlineBehavior: String
    public let modelLicense: String

    public init(
        coldQueryLatencyMs: Double, warmQueryLatencyMs: Double, indexTimeMs: Double,
        memoryMB: Double, bundleMB: Double, energyScore: Double,
        hardware: String, osVersion: String, offlineBehavior: String, modelLicense: String
    ) {
        self.coldQueryLatencyMs = coldQueryLatencyMs
        self.warmQueryLatencyMs = warmQueryLatencyMs
        self.indexTimeMs = indexTimeMs
        self.memoryMB = memoryMB
        self.bundleMB = bundleMB
        self.energyScore = energyScore
        self.hardware = hardware
        self.osVersion = osVersion
        self.offlineBehavior = offlineBehavior
        self.modelLicense = modelLicense
    }

    /// Placeholder for the FTS-only baseline: no added bundle, no model, fully
    /// offline, no license required (INF-314).
    public static let ftsBaseline = AttacheRetrievalRuntime(
        coldQueryLatencyMs: 0, warmQueryLatencyMs: 0, indexTimeMs: 0,
        memoryMB: 0, bundleMB: 0, energyScore: 0,
        hardware: "n/a", osVersion: "n/a",
        offlineBehavior: "Fully offline. SQLite FTS5 ships with the OS.",
        modelLicense: "None. No model."
    )
}

/// One candidate's full result row (INF-314).
public struct AttacheRetrievalCandidateResult: Equatable, Sendable {
    public let kind: AttacheRetrievalCandidateKind
    public let metrics: AttacheRetrievalMetrics
    public let runtime: AttacheRetrievalRuntime

    public init(kind: AttacheRetrievalCandidateKind, metrics: AttacheRetrievalMetrics, runtime: AttacheRetrievalRuntime) {
        self.kind = kind
        self.metrics = metrics
        self.runtime = runtime
    }
}

/// The verdict (INF-314). Exactly one: ship optional local semantic reranking,
/// defer it, or reject it. The follow-on semantic ticket stays blocked unless
/// the verdict is ship.
public enum AttacheRetrievalVerdict: String, Equatable, Sendable {
    case ship
    case defer_
    case reject

    public var allowsFollowOnSemantic: Bool { self == .ship }
}

/// The full benchmark report (INF-314). Content-free except for sanitized
/// metric and runtime values. The verdict is derived from the predeclared
/// thresholds, not chosen after the fact.
public struct AttacheRetrievalReport: Equatable, Sendable {
    public let thresholds: AttacheRetrievalThresholds
    public let results: [AttacheRetrievalCandidateResult]
    public let verdict: AttacheRetrievalVerdict
    public let rationale: String

    public init(thresholds: AttacheRetrievalThresholds, results: [AttacheRetrievalCandidateResult], verdict: AttacheRetrievalVerdict, rationale: String) {
        self.thresholds = thresholds
        self.results = results
        self.verdict = verdict
        self.rationale = rationale
    }
}

/// A candidate reranker protocol (INF-314). The lexical reranker is the
/// deterministic, pure-Core stand-in for an on-device semantic reranker. A
/// real Apple Natural Language or Core ML reranker would conform to the same
/// protocol so the harness can measure it without changing shape.
public protocol AttacheRetrievalReranker: Sendable {
    func rerank(query: AttacheRetrievalQuery, candidates: [AttacheRetrievalDocument]) -> [String]
}

/// A lexical-similarity reranker (INF-314). Scores documents by token overlap
/// (Jaccard) with the query, breaking ties by title overlap then document id.
/// This is the pure-Core candidate that stands in for a semantic reranker so
/// the benchmark logic is fully testable without a hosted embedding API or a
/// downloaded model.
public struct AttacheLexicalReranker: AttacheRetrievalReranker {
    public init() {}

    public func rerank(query: AttacheRetrievalQuery, candidates: [AttacheRetrievalDocument]) -> [String] {
        let queryTokens = AttacheLexicalReranker.tokens(query.text)
        return candidates.map { doc -> (id: String, score: Double, titleScore: Double) in
            let bodyTokens = AttacheLexicalReranker.tokens(doc.body)
            let titleTokens = AttacheLexicalReranker.tokens(doc.title)
            let bodyScore = AttacheLexicalReranker.jaccard(queryTokens, bodyTokens)
            let titleScore = AttacheLexicalReranker.jaccard(queryTokens, titleTokens)
            return (doc.id, bodyScore, titleScore)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.titleScore != rhs.titleScore { return lhs.titleScore > rhs.titleScore }
            return lhs.id < rhs.id
        }
        .map { $0.id }
    }

    static func tokens(_ text: String) -> Set<String> {
        let lower = text.lowercased()
        var tokens: Set<String> = []
        var current = ""
        for char in lower {
            if char.isLetter || char.isNumber {
                current.append(char)
            } else {
                if !current.isEmpty { tokens.insert(current); current = "" }
            }
        }
        if !current.isEmpty { tokens.insert(current) }
        return tokens
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        return union > 0 ? Double(intersection) / Double(union) : 0
    }
}

/// The benchmark harness (INF-314). Runs the FTS-only baseline, the lexical
/// reranker candidate, and the hybrid (FTS recall pool then lexical rerank),
/// then applies the predeclared thresholds to derive the verdict. Pure and
/// deterministic given the FTS index.
public enum AttacheRetrievalBenchmark {

    /// Run all three candidates and derive the verdict from the predeclared
    /// thresholds (INF-314). The FTS index must already be populated with the
    /// corpus documents. Runtimes are supplied by the caller (captured on the
    /// benchmark machine); the metric logic is computed here deterministically.
    public static func run(
        ftsIndex: SessionFTSIndex,
        documents: [AttacheRetrievalDocument] = AttacheRetrievalCorpus.documents,
        queries: [AttacheRetrievalQuery] = AttacheRetrievalCorpus.queries,
        thresholds: AttacheRetrievalThresholds = .predeclared,
        reranker: AttacheRetrievalReranker = AttacheLexicalReranker(),
        ftsRuntime: AttacheRetrievalRuntime = .ftsBaseline,
        lexicalRuntime: AttacheRetrievalRuntime? = nil,
        hybridRuntime: AttacheRetrievalRuntime? = nil
    ) -> AttacheRetrievalReport {
        let docsByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })

        // 1. FTS-only baseline: rank by the FTS5 service score.
        let ftsRanked = queries.map { query -> (query: AttacheRetrievalQuery, rankedDocIDs: [String]) in
            let hits = ftsIndex.search(query.text)
            return (query, hits.map { $0.sessionID })
        }
        let ftsMetrics = AttacheRetrievalMetrics.compute(rankedDocIDsPerQuery: ftsRanked)

        // 2. Lexical reranker: rank all documents by token overlap.
        let lexicalRanked = queries.map { query -> (query: AttacheRetrievalQuery, rankedDocIDs: [String]) in
            (query, reranker.rerank(query: query, candidates: documents))
        }
        let lexicalMetrics = AttacheRetrievalMetrics.compute(rankedDocIDsPerQuery: lexicalRanked)

        // 3. Hybrid: take the FTS recall pool (top 20), rerank it lexically.
        let hybridRanked = queries.map { query -> (query: AttacheRetrievalQuery, rankedDocIDs: [String]) in
            let pool = ftsIndex.search(query.text).prefix(20).map { $0.sessionID }
            let poolDocs = pool.compactMap { docsByID[$0] }
            if poolDocs.isEmpty {
                // FTS returned nothing; fall back to the pure lexical rank over all docs.
                return (query, reranker.rerank(query: query, candidates: documents))
            }
            return (query, reranker.rerank(query: query, candidates: poolDocs))
        }
        let hybridMetrics = AttacheRetrievalMetrics.compute(rankedDocIDsPerQuery: hybridRanked)

        let results: [AttacheRetrievalCandidateResult] = [
            AttacheRetrievalCandidateResult(kind: .ftsOnly, metrics: ftsMetrics, runtime: ftsRuntime),
            AttacheRetrievalCandidateResult(
                kind: .lexicalReranker, metrics: lexicalMetrics,
                runtime: lexicalRuntime ?? AttacheRetrievalRuntime(
                    coldQueryLatencyMs: 0, warmQueryLatencyMs: 0, indexTimeMs: 0,
                    memoryMB: 0, bundleMB: 0, energyScore: 0,
                    hardware: "n/a", osVersion: "n/a",
                    offlineBehavior: "Fully offline. Pure Foundation token overlap.",
                    modelLicense: "None. No model."
                )
            ),
            AttacheRetrievalCandidateResult(
                kind: .hybrid, metrics: hybridMetrics,
                runtime: hybridRuntime ?? AttacheRetrievalRuntime(
                    coldQueryLatencyMs: 0, warmQueryLatencyMs: 0, indexTimeMs: 0,
                    memoryMB: 0, bundleMB: 0, energyScore: 0,
                    hardware: "n/a", osVersion: "n/a",
                    offlineBehavior: "Fully offline. FTS5 pool plus lexical rerank.",
                    modelLicense: "None. No model."
                )
            ),
        ]

        let verdict = deriveVerdict(
            thresholds: thresholds, results: results, ftsBaseline: ftsMetrics
        )
        let rationale = verdictRationale(
            thresholds: thresholds, results: results, ftsBaseline: ftsMetrics, verdict: verdict
        )
        return AttacheRetrievalReport(
            thresholds: thresholds, results: results, verdict: verdict, rationale: rationale
        )
    }

    /// Derive the verdict from the predeclared thresholds (INF-314). The
    /// candidate semantic or hybrid option must clear every gate AND must not
    /// regress keyword-heavy recall materially vs the FTS baseline. If no
    /// candidate clears the gates, the verdict is reject. If a candidate
    /// clears the quality gates but a runtime gate is unmeasured or borderline,
    /// the verdict is defer.
    public static func deriveVerdict(
        thresholds: AttacheRetrievalThresholds,
        results: [AttacheRetrievalCandidateResult],
        ftsBaseline: AttacheRetrievalMetrics
    ) -> AttacheRetrievalVerdict {
        let candidates = results.filter { $0.kind != .ftsOnly }
        let bestQuality = candidates.filter { result in
            let m = result.metrics
            let keywordDrop = ftsBaseline.keywordRecallAt5 - m.keywordRecallAt5
            return m.recallAt5 >= thresholds.minRecallAt5
                && m.mrr >= thresholds.minMRR
                && m.falsePositiveRate <= thresholds.maxFalsePositiveRate
                && keywordDrop <= thresholds.maxKeywordRecallRegression
        }
        if bestQuality.isEmpty {
            return .reject
        }
        // Check runtime gates. A candidate that has not been measured (zero
        // latency and n/a hardware) cannot ship yet: defer until measured on
        // real hardware.
        let measuredAndPassing = bestQuality.filter { result in
            let r = result.runtime
            let measured = r.hardware != "n/a"
            guard measured else { return false }
            return r.coldQueryLatencyMs <= thresholds.maxColdQueryLatencyMs
                && r.warmQueryLatencyMs <= thresholds.maxWarmQueryLatencyMs
                && r.indexTimeMs <= thresholds.maxIndexTimeMs
                && r.memoryMB <= thresholds.maxMemoryMB
                && r.bundleMB <= thresholds.maxBundleMB
                && r.energyScore <= thresholds.maxEnergyScore
        }
        if let _ = measuredAndPassing.first {
            return .ship
        }
        return .defer_
    }

    /// A human-readable rationale that names the gates and why the verdict
    /// landed where it did (INF-314). Content-free of corpus text.
    public static func verdictRationale(
        thresholds: AttacheRetrievalThresholds,
        results: [AttacheRetrievalCandidateResult],
        ftsBaseline: AttacheRetrievalMetrics,
        verdict: AttacheRetrievalVerdict
    ) -> String {
        let lines: [String]
        switch verdict {
        case .ship:
            lines = ["A candidate cleared all quality and runtime gates.", "Follow-on semantic implementation may proceed."]
        case .defer_:
            lines = ["A candidate cleared quality gates but runtime gates were not measured on real hardware or were borderline.", "Follow-on semantic implementation stays blocked until measured."]
        case .reject:
            lines = ["No candidate cleared the predeclared quality gates.", "Follow-on semantic implementation stays blocked."]
        }
        let candidateLines = results.filter { $0.kind != .ftsOnly }.map { result in
            let m = result.metrics
            let drop = ftsBaseline.keywordRecallAt5 - m.keywordRecallAt5
            return "\(result.kind.rawValue): recall@5=\(m.recallAt5), mrr=\(m.mrr), fpr=\(m.falsePositiveRate), keywordDrop=\(drop)"
        }
        return (lines + candidateLines).joined(separator: " ")
    }
}