# ADR: On-device semantic retrieval benchmark (INF-314)

## Status

Deferred. The follow-on optional semantic reranking ticket (INF-322) stays
blocked until a real on-device semantic option is measured on laptop-class
hardware and clears every predeclared gate below.

## Context

Before adding any vector infrastructure, Attaché needs an evidence-based ship
or no-ship decision on local semantic retrieval. The SQLite FTS5 service
(INF-306/311) is the production retrieval engine today. This benchmark
measures whether a semantic reranker earns its place on top of it.

The benchmark lives in `Sources/AttacheCore/AttacheRetrievalBenchmark.swift`
and is fully reproducible from one command:

```
scripts/retrieval-benchmark.sh
```

which runs `swift test --filter AttacheRetrievalBenchmark` (16 deterministic
tests covering metrics, thresholds, all three candidates, verdict logic, and
the no-private-content guarantee).

## Predeclared thresholds

Written before any results were interpreted (`AttacheRetrievalThresholds.predeclared`):

| Gate | Value |
|---|---|
| Minimum recall@5 | 0.70 |
| Minimum MRR | 0.55 |
| Maximum false-positive rate | 0.15 |
| Maximum keyword recall regression vs FTS | 0.05 |
| Maximum cold query latency | 250 ms |
| Maximum warm query latency | 60 ms |
| Maximum index time | 2000 ms |
| Maximum memory | 120 MB |
| Maximum bundle impact | 50 MB |
| Maximum energy score | 3.0 |

A candidate that misses any hard gate cannot ship. Keyword-heavy cases cannot
regress materially (the 0.05 cap on keyword recall regression versus the FTS
baseline).

## Candidates

1. **FTS-only baseline.** The production SQLite FTS5 service, lexical ranking
   and filters. No added bundle, no model, fully offline, no license required.
2. **Lexical reranker.** A pure-Foundation token-overlap (Jaccard) reranker
   (`AttacheLexicalReranker`). This is the deterministic stand-in for an
   on-device semantic reranker so the benchmark logic is fully testable
   without a hosted embedding API or a downloaded model. It is not a semantic
   model and is not the production candidate.
3. **Hybrid.** FTS5 recall pool (top 20) reranked lexically. Falls back to
   pure lexical rank when FTS returns nothing.

Viable self-contained macOS options that were evaluated for the real
candidate slot: Apple Natural Language embeddings (NLEmbedding), a small
bundled Core ML model, or another truly on-device option with a clear
license. Ollama may be measured as an optional enhancement but cannot be
required. None of these have been measured on real hardware for this
benchmark yet, which is why the verdict is defer rather than ship or reject.

## Verdict

**Defer.**

Rationale: the deterministic benchmark harness, predeclared thresholds,
metrics (recall@5, MRR, false-positive rate, keyword recall regression),
verdict derivation, and the no-private-content guarantee are all in place and
green. The lexical reranker candidate clears the quality gates
deterministically in the test suite, but it is a pure-Foundation proxy, not a
real semantic model. A real on-device semantic option (Apple Natural Language
embeddings, a bundled Core ML model, or equivalent) has not yet been measured
against the runtime gates (latency, memory, disk, bundle, energy) on
laptop-class hardware. Until that measurement happens and a candidate clears
every runtime gate, the verdict cannot be ship.

The follow-on semantic implementation ticket (INF-322, optional semantic
reranking) stays blocked.

## Fallback path

The FTS-only baseline remains the production retrieval engine. It is fully
offline, ships with the OS (SQLite FTS5), adds no bundle weight, requires no
model, and carries no license. If no on-device semantic option ever clears
the gates, Attaché keeps FTS-only retrieval and loses nothing.

## Hardware and OS

The deterministic metric logic runs anywhere `swift test` runs. The runtime
gates (latency, memory, disk, energy) must be measured on a real Mac. The
constrained-hardware reproducible benchmark target is the lowest-supported
Apple Silicon (M1) on the minimum supported macOS. Physical Intel hardware
was not available for this run; a reproducible constrained benchmark on Apple
Silicon with an energy and memory cap is the documented path. Runtime values
are recorded as `AttacheRetrievalRuntime` rows and attached to this ADR when
captured.

## Privacy

All corpus content is synthetic and sanitized. The corpus contains no private
session content, no real tokens, no real email addresses, no real key
material. The test `testCorpusContainsNoPrivateSessionContent` checks for
actual secret-material patterns (real API keys, real emails, real bearer
tokens, private key blocks, AWS keys, long opaque secrets). The benchmark
report rationale is content-free of corpus body text.

## Non-goals

This issue does not ship production embeddings, download a model silently, or
change user-facing search. It only produces the decision.