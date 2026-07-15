import AttacheCore
import XCTest
import Foundation

final class AttacheRetrievalBenchmarkTests: XCTestCase {

    // Helpers: build a temp FTS index populated with the sanitized corpus.
    private func populatedIndex() throws -> SessionFTSIndex {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-retrieval-bench-\(UUID().uuidString).sqlite")
        let index = SessionFTSIndex(databaseURL: tmp)
        let records = AttacheRetrievalCorpus.documents.map { doc -> SessionRecord in
            SessionRecord(
                id: doc.id,
                title: doc.title,
                project: doc.projectPath,
                threadName: nil,
                updatedAt: doc.updatedAt,
                archived: false,
                filePath: "/tmp/\(doc.id).jsonl",
                fileMtime: doc.updatedAt.timeIntervalSince1970,
                content: (doc.title + "\n" + doc.body).lowercased(),
                topicTag: nil,
                sourceKind: .codex
            )
        }
        _ = index.index(records: records)
        return index
    }

    // Criterion: thresholds are written before results are interpreted.
    func testPredeclaredThresholdsAreAccessibleBeforeResults() {
        let thresholds = AttacheRetrievalThresholds.predeclared
        XCTAssertGreaterThan(thresholds.minRecallAt5, 0)
        XCTAssertGreaterThan(thresholds.minMRR, 0)
        XCTAssertLessThan(thresholds.maxFalsePositiveRate, 1)
        XCTAssertGreaterThan(thresholds.maxKeywordRecallRegression, 0)
        XCTAssertLessThan(thresholds.maxKeywordRecallRegression, 1, "regression cap must be a material, not total, allowance")
        XCTAssertGreaterThan(thresholds.maxColdQueryLatencyMs, 0)
        XCTAssertGreaterThan(thresholds.maxWarmQueryLatencyMs, 0)
        XCTAssertGreaterThan(thresholds.maxIndexTimeMs, 0)
        XCTAssertGreaterThan(thresholds.maxMemoryMB, 0)
        XCTAssertGreaterThan(thresholds.maxBundleMB, 0)
        XCTAssertGreaterThan(thresholds.maxEnergyScore, 0)
    }

    // Criterion: metrics are computed correctly from ranked lists.
    func testMetricsComputeRecallMRRAndFPR() {
        let queries = AttacheRetrievalCorpus.queries
        // Perfect ranking: each query returns exactly its relevant docs first.
        let perfect = queries.map { q -> (query: AttacheRetrievalQuery, rankedDocIDs: [String]) in
            (q, Array(q.relevantDocIDs))
        }
        let metrics = AttacheRetrievalMetrics.compute(rankedDocIDsPerQuery: perfect)
        XCTAssertEqual(metrics.recallAt5, 1.0, accuracy: 0.0001, "perfect ranking has full recall")
        XCTAssertEqual(metrics.mrr, 1.0, accuracy: 0.0001, "perfect ranking has MRR 1")
        XCTAssertEqual(metrics.falsePositiveRate, 0.0, accuracy: 0.0001, "no false positives when only relevant docs returned")
        XCTAssertEqual(metrics.keywordRecallAt5, 1.0, accuracy: 0.0001)
    }

    func testMetricsPenalizeWrongRanking() {
        let query = AttacheRetrievalQuery(id: "q", text: "test", relevantDocIDs: ["a"], category: .exactKeyword)
        // Return the wrong doc first, then the relevant one.
        let ranked: [(query: AttacheRetrievalQuery, rankedDocIDs: [String])] = [(query, ["z", "a"])]
        let metrics = AttacheRetrievalMetrics.compute(rankedDocIDsPerQuery: ranked)
        XCTAssertEqual(metrics.recallAt5, 1.0, accuracy: 0.0001, "relevant doc is in top 5")
        XCTAssertEqual(metrics.mrr, 0.5, accuracy: 0.0001, "first relevant at rank 2 -> 1/2")
        XCTAssertGreaterThan(metrics.falsePositiveRate, 0, "one false positive in top 5")
    }

    func testMetricsEmptyResultsAreWorstCase() {
        let query = AttacheRetrievalQuery(id: "q", text: "test", relevantDocIDs: ["a"], category: .exactKeyword)
        let ranked: [(query: AttacheRetrievalQuery, rankedDocIDs: [String])] = [(query, [])]
        let metrics = AttacheRetrievalMetrics.compute(rankedDocIDsPerQuery: ranked)
        XCTAssertEqual(metrics.recallAt5, 0.0, accuracy: 0.0001)
        XCTAssertEqual(metrics.mrr, 0.0, accuracy: 0.0001)
        XCTAssertEqual(metrics.falsePositiveRate, 1.0, accuracy: 0.0001, "all slots are false positives when nothing relevant is returned")
    }

    // Criterion: FTS-only, candidate semantic, and hybrid are reproducible.
    func testAllThreeCandidatesRunAndAreReproducible() throws {
        let index = try populatedIndex()
        defer { _ = index }

        let report1 = AttacheRetrievalBenchmark.run(ftsIndex: index)
        let report2 = AttacheRetrievalBenchmark.run(ftsIndex: index)
        XCTAssertEqual(report1, report2, "benchmark is deterministic for the same index")
        XCTAssertEqual(report1.results.count, 3, "FTS, lexical, and hybrid all present")
        let kinds = Set(report1.results.map { $0.kind })
        XCTAssertEqual(kinds, [.ftsOnly, .lexicalReranker, .hybrid])
    }

    // Criterion: keyword-heavy cases cannot regress materially.
    func testKeywordRecallDoesNotRegressMateriallyVersusFTS() throws {
        let index = try populatedIndex()
        defer { _ = index }
        let report = AttacheRetrievalBenchmark.run(ftsIndex: index)
        let fts = report.results.first { $0.kind == .ftsOnly }!
        for candidate in report.results where candidate.kind != .ftsOnly {
            let drop = fts.metrics.keywordRecallAt5 - candidate.metrics.keywordRecallAt5
            XCTAssertLessThanOrEqual(
                drop,
                AttacheRetrievalThresholds.predeclared.maxKeywordRecallRegression + 0.0001,
                "\(candidate.kind.rawValue) must not regress keyword recall materially vs FTS"
            )
        }
    }

    // Criterion: no hosted embedding API or user-installed vector DB is required.
    func testNoHostedAPIOrVectorDBRequired() {
        // The lexical reranker is pure Foundation token overlap. No network,
        // no model download, no vector DB.
        let reranker = AttacheLexicalReranker()
        let query = AttacheRetrievalCorpus.queries.first { $0.category == .exactKeyword }!
        let ranked = reranker.rerank(query: query, candidates: AttacheRetrievalCorpus.documents)
        XCTAssertFalse(ranked.isEmpty, "lexical reranker runs offline with no model")
        XCTAssertTrue(ranked.contains(Array(query.relevantDocIDs)[0]),
                      "lexical reranker should rank the relevant doc somewhere")
    }

    // Criterion: the verdict identifies supported hardware/OS and a fallback path.
    func testVerdictIsRejectOrDeferWhenRuntimeUnmeasured() throws {
        let index = try populatedIndex()
        defer { _ = index }
        let report = AttacheRetrievalBenchmark.run(ftsIndex: index)
        // Without runtime measurements on real hardware, the verdict cannot be
        // ship. It must be defer or reject.
        XCTAssertNotEqual(report.verdict, .ship, "cannot ship without measured runtime on real hardware")
        XCTAssertTrue(report.verdict == .defer_ || report.verdict == .reject)
        XCTAssertFalse(report.rationale.isEmpty, "rationale must explain the verdict")
    }

    func testVerdictShipWhenAllGatesMeasuredAndPassing() {
        // Build synthetic metrics that clear every quality gate, plus a
        // measured runtime that clears every runtime gate.
        let thresholds = AttacheRetrievalThresholds.predeclared
        let ftsBaseline = AttacheRetrievalMetrics(recallAt5: 0.6, mrr: 0.5, falsePositiveRate: 0.2, keywordRecallAt5: 0.9)
        let passingMetrics = AttacheRetrievalMetrics(recallAt5: 0.8, mrr: 0.7, falsePositiveRate: 0.1, keywordRecallAt5: 0.9)
        let measuredRuntime = AttacheRetrievalRuntime(
            coldQueryLatencyMs: 100, warmQueryLatencyMs: 30, indexTimeMs: 500,
            memoryMB: 60, bundleMB: 20, energyScore: 2.0,
            hardware: "Apple M2", osVersion: "macOS 15",
            offlineBehavior: "Fully offline.",
            modelLicense: "MIT"
        )
        let results: [AttacheRetrievalCandidateResult] = [
            AttacheRetrievalCandidateResult(kind: .ftsOnly, metrics: ftsBaseline, runtime: .ftsBaseline),
            AttacheRetrievalCandidateResult(kind: .lexicalReranker, metrics: passingMetrics, runtime: measuredRuntime),
        ]
        let verdict = AttacheRetrievalBenchmark.deriveVerdict(
            thresholds: thresholds, results: results, ftsBaseline: ftsBaseline
        )
        XCTAssertEqual(verdict, .ship, "a measured candidate clearing all gates ships")
        XCTAssertTrue(verdict.allowsFollowOnSemantic)
    }

    func testVerdictRejectWhenNoCandidateClearsQuality() {
        let thresholds = AttacheRetrievalThresholds.predeclared
        let ftsBaseline = AttacheRetrievalMetrics(recallAt5: 0.9, mrr: 0.8, falsePositiveRate: 0.05, keywordRecallAt5: 0.95)
        // Candidate is worse on every axis.
        let badMetrics = AttacheRetrievalMetrics(recallAt5: 0.3, mrr: 0.2, falsePositiveRate: 0.5, keywordRecallAt5: 0.4)
        let measuredRuntime = AttacheRetrievalRuntime(
            coldQueryLatencyMs: 10, warmQueryLatencyMs: 5, indexTimeMs: 10,
            memoryMB: 1, bundleMB: 1, energyScore: 0.1,
            hardware: "Apple M2", osVersion: "macOS 15",
            offlineBehavior: "Offline.", modelLicense: "MIT"
        )
        let results: [AttacheRetrievalCandidateResult] = [
            AttacheRetrievalCandidateResult(kind: .ftsOnly, metrics: ftsBaseline, runtime: .ftsBaseline),
            AttacheRetrievalCandidateResult(kind: .lexicalReranker, metrics: badMetrics, runtime: measuredRuntime),
        ]
        let verdict = AttacheRetrievalBenchmark.deriveVerdict(
            thresholds: thresholds, results: results, ftsBaseline: ftsBaseline
        )
        XCTAssertEqual(verdict, .reject)
        XCTAssertFalse(verdict.allowsFollowOnSemantic)
    }

    func testVerdictDeferWhenQualityPassesButRuntimeUnmeasured() {
        let thresholds = AttacheRetrievalThresholds.predeclared
        let ftsBaseline = AttacheRetrievalMetrics(recallAt5: 0.6, mrr: 0.5, falsePositiveRate: 0.2, keywordRecallAt5: 0.8)
        let passingMetrics = AttacheRetrievalMetrics(recallAt5: 0.8, mrr: 0.7, falsePositiveRate: 0.1, keywordRecallAt5: 0.8)
        let unmeasuredRuntime = AttacheRetrievalRuntime(
            coldQueryLatencyMs: 0, warmQueryLatencyMs: 0, indexTimeMs: 0,
            memoryMB: 0, bundleMB: 0, energyScore: 0,
            hardware: "n/a", osVersion: "n/a",
            offlineBehavior: "Not yet measured.", modelLicense: "TBD"
        )
        let results: [AttacheRetrievalCandidateResult] = [
            AttacheRetrievalCandidateResult(kind: .ftsOnly, metrics: ftsBaseline, runtime: .ftsBaseline),
            AttacheRetrievalCandidateResult(kind: .lexicalReranker, metrics: passingMetrics, runtime: unmeasuredRuntime),
        ]
        let verdict = AttacheRetrievalBenchmark.deriveVerdict(
            thresholds: thresholds, results: results, ftsBaseline: ftsBaseline
        )
        XCTAssertEqual(verdict, .defer_, "quality passed but runtime unmeasured -> defer")
        XCTAssertFalse(verdict.allowsFollowOnSemantic)
    }

    // Criterion: the follow-on semantic ticket stays blocked unless verdict is ship.
    func testFollowOnSemanticBlockedUnlessShip() {
        XCTAssertFalse(AttacheRetrievalVerdict.reject.allowsFollowOnSemantic)
        XCTAssertFalse(AttacheRetrievalVerdict.defer_.allowsFollowOnSemantic)
        XCTAssertTrue(AttacheRetrievalVerdict.ship.allowsFollowOnSemantic)
    }

    // Criterion: benchmark code and fixtures contain no private session content.
    // The corpus may mention security concepts descriptively (the words
    // "secret", "bearer", "password" describe what the system filters or
    // stores), but it must not contain actual private data: real API keys,
    // real email addresses, real key material, real bearer tokens, or real
    // session transcripts.
    func testCorpusContainsNoPrivateSessionContent() {
        // Patterns that indicate actual leaked secret material, not concept words.
        let secretPatterns: [(label: String, regex: String)] = [
            ("real api key", "sk-[A-Za-z0-9]{16,}"),
            ("real email", "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"),
            ("real bearer token", "bearer [A-Za-z0-9._-]{16,}"),
            ("private key block", "-----begin"),
            ("aws key", "akia[0-9a-z]{12,}"),
            ("generic long secret", "[A-Za-z0-9+/]{40,}={0,2}"),
        ]
        for doc in AttacheRetrievalCorpus.documents {
            let combined = doc.title + " " + doc.body
            for pattern in secretPatterns {
                XCTAssertNil(combined.range(of: pattern.regex, options: [.regularExpression, .caseInsensitive]),
                               "corpus doc \(doc.id) must not contain \(pattern.label)")
            }
        }
        for query in AttacheRetrievalCorpus.queries {
            for pattern in secretPatterns {
                XCTAssertNil(query.text.range(of: pattern.regex, options: [.regularExpression, .caseInsensitive]),
                               "query \(query.id) must not contain \(pattern.label)")
            }
        }
    }

    // Corpus covers every query category.
    func testCorpusCoversEveryCategory() {
        let categories = Set(AttacheRetrievalCorpus.queries.map { $0.category })
        XCTAssertEqual(categories, Set(AttacheRetrievalQueryCategory.allCases),
                       "corpus must stress every category")
    }

    // Lexical reranker is deterministic.
    func testLexicalRerankerIsDeterministic() {
        let reranker = AttacheLexicalReranker()
        let query = AttacheRetrievalCorpus.queries.first { $0.category == .paraphrase }!
        let r1 = reranker.rerank(query: query, candidates: AttacheRetrievalCorpus.documents)
        let r2 = reranker.rerank(query: query, candidates: AttacheRetrievalCorpus.documents)
        XCTAssertEqual(r1, r2)
    }

    // Report is content-free of corpus body text.
    func testReportRationaleContainsNoCorpusBodyText() throws {
        let index = try populatedIndex()
        defer { _ = index }
        let report = AttacheRetrievalBenchmark.run(ftsIndex: index)
        let rationale = report.rationale.lowercased()
        // Spot-check a few distinctive corpus phrases that must not leak.
        XCTAssertFalse(rationale.contains("bryanlabs.net stopped forwarding"))
        XCTAssertFalse(rationale.contains("canon mg3620 reported a low ink"))
        XCTAssertFalse(rationale.contains("k-1 against the trial balance"))
    }
}