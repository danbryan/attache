# Context Management

Attaché gives your agents a voice while managing what context reaches each
model, where it goes, how it is bounded, and how to recover when it cannot
fit. This document covers user-facing settings, privacy, recovery, and the
developer architecture.

## Context Strategies

Attaché compiles every model request through a context compiler that plans a
token budget, fits authorized evidence, and emits a content-free receipt. The
strategy controls how much evidence fits.

### Automatic (default)

Attaché balances evidence and speed automatically. No tuning needed. This is
the right choice for most users.

### Maximum coverage

Attaché uses more relevant raw evidence and staged verification when useful. It
does not promise to send everything. Useful when you want the model to have as
much context as the budget allows.

### Efficient

Attaché prefers compact evidence for speed and local-model limits. Useful for
small local models or when latency matters more than depth.

### Custom (advanced)

Set your own input limits, reserves, and evidence preferences. Invalid Custom
values cannot be saved and the error explains how to fix them. Custom can make
requests fail if the limits are too tight for protected content (safety
policy, active personality, and the current user turn must always fit).

When the Advanced capability panel says capacity is unknown, select **Set a
Custom cap** there. Attaché switches the strategy to Custom and reveals the
hard and working input-limit fields in place. A Custom cap is user policy: it
limits how Attaché uses a model but never rewrites the model evidence shown
above it.

Advertised context is a ceiling, not a target. Attaché never fills the
context window for its own sake.

### Which strategy should I choose?

| If you want... | Choose | What changes |
| --- | --- | --- |
| A strong default that adapts to the selected model | **Automatic** | Balanced evidence allowances, rolling conversation compression, and bounded retrieval |
| Faster answers or dependable behavior on a small local model | **Efficient** | Smaller recent-turn and memory allowances, earlier compression, and tighter tool-result limits |
| The deepest answer the known model budget can support | **Maximum coverage** | Larger evidence allowances and wider staged whole-session review |
| A hard ceiling you control for cost, latency, or an unprofiled model | **Custom** | Your input cap, reserves, evidence mix, and retrieval limits become the working policy |

The strategies are ceilings and priorities, not filler. A context-free greeting
can compile identically under Efficient and Maximum coverage because there is no
relevant authorized evidence to add. The difference becomes visible on longer
direct chats, focused sessions, memory retrieval, tool results, and whole-session
reviews. Expand **Advanced** to see the concrete plan before sending anything.

Expand **Advanced** to see a live strategy plan. It changes immediately when
you select a strategy and shows the runtime evidence allowance, conversation
compression behavior, durable-memory budget, retrieved-tool limits, and
whole-session review stage size. The separate Model evidence card is labeled
independent of strategy because a strategy changes how Attaché uses a model's
capacity, not the model facts themselves. Efficient and Maximum coverage can
produce the same request when no relevant, authorized context is available.

## Model Capabilities

Attaché detects model capabilities at runtime from provider metadata, runtime
observation, or local cache. Capabilities include:

- **Architectural maximum**: the model's input token ceiling, as reported or
  observed. This is detected evidence, not a timeless claim. Providers change
  limits without notice.
- **Reasoning levels**: whether the model supports reasoning and at what
  levels (low, medium, high). Unknown until confirmed.
- **Provenance and freshness**: where the capability information came from
  (provider metadata, runtime observation, user override, curated fallback)
  and when it was last confirmed. Stale profiles are flagged.
- **Custom policy**: a user can set a separate effective input limit and
  reserves. Custom policy never rewrites detected provider facts; both remain
  visible in the advanced view.
- **Unknown providers**: when Attaché cannot detect capabilities, named
  strategies use a 16,384-token working envelope, staged retrieval, and
  bounded tools. Custom uses its input cap when one is set, or the same
  envelope otherwise. Attaché never treats the envelope as a provider fact or
  assumes a large context window.
- **Installed Ollama models**: Attaché discovers the exact tags on the selected
  Ollama host, then asks `/api/show` for each installed model's context and
  thinking capabilities. The model digest travels with the cached capability
  and frozen request identity. If an unchanged digest is temporarily offline,
  Attaché can retain its last-known ceiling while visibly marking the evidence
  stale. A changed digest starts a new identity and cannot inherit the prior
  model's facts. A saved tag that is no longer installed is labeled as such
  rather than presented as a mysterious unknown profile.
- **xAI catalog gaps**: Attaché asks xAI which models are available. xAI's
  current catalog omits capacity and reasoning fields, so exact current Grok
  4.3, 4.5, Build 0.1, and 4.20 records are supplemented from a versioned
  verified model catalog. The Advanced panel labels those facts "Verified model
  catalog". Any capability fields returned by xAI take precedence.
- **Reset**: deleting the capability cache forces a fresh detection on the
  next request.

## Context Sources

Attaché treats these as distinct sources, each with its own authorization and
egress policy:

1. **Safety policy**: always included, always fits or fails.
2. **Active personality**: the brain, voice, and visual presence of the
   current personality.
3. **Current user turn**: what you just said. Always included.
4. **Recent direct-chat turns**: the exact recent turns in the current direct
   conversation, kept as a strategy-dependent suffix.
5. **Older chat summary**: neutral, locally extracted capsules that compress
   older direct-chat history while retaining decisions, questions,
   corrections, and unresolved commitments. Not durable memory. Private calls
   build these capsules in process memory only and erase them at hangup.
6. **Durable personal memory**: facts you told Attaché to remember, scoped and
   egress-labeled. Treated as quoted user data, never system instructions.
7. **Focused-session metadata**: the title, source, and working directory of
   the session you explicitly focused. Only included when a session is
   focused.
8. **Retrieved transcript evidence**: bounded excerpts from the focused
   session's transcript, accessed through provenance-addressable tools.
9. **Retrieved file evidence**: bounded excerpts from project files in the
   focused session's working directory.
10. **Tool definitions and results**: session transcript and project-file
    tools are available only with exact frozen focus authority. Context-free
    app tools, such as proposing a memory or opening native session discovery,
    remain available without exposing session data. Private calls do not expose
    memory, rename, exhaustive-review, or agent-send effects.

## Search vs Authorization

Attaché can search for a session without authorizing it. When you ask "find
the session about X," Attaché opens a native picker. The model sees only a
match count, not titles, paths, or transcript snippets. Only your explicit
selection (Enter or click) focuses the session and advances the authorization
epoch.

No-focus conversation cannot read any session's transcript, files, metadata,
or tools. Watched sessions, recent activity, and search results do not grant
access.

## Whole-Session Review

When you explicitly ask to review an entire focused session, Attaché processes
every eligible region through a checkpointed staged workflow:

1. **Cost preview**: shows the session size, selected model/strategy,
   estimated stages, egress class, and a cancel option before any remote call.
2. **Coverage ledger**: one entry per eligible episode. Progress is shown by
   covered ranges, not an indeterminate spinner.
3. **Staged processing**: small models use more bounded stages; large models
   may combine more evidence. Both stay within per-call and cumulative limits.
   A single exact range that cannot fit is not sent and the review reports
   incomplete instead of silently truncating it.
4. **Cancellation and resume**: cancel stops new provider calls. Resume
   continues from in-memory checkpoints during the current app run without
   repeating completed work, as long as the source version and authorization
   are still valid. Relaunching starts a new cost preview and coverage ledger.
5. **Final output**: states complete, incomplete, canceled, or stale. Only
   complete may say the whole eligible session was reviewed. Every completed
   stage must return machine-validated episode IDs, turn boundaries, and full
   source hashes for every supplied range; those locators are retained with the
   stage summary.

Source mutation, focus change, or authorization expiry marks the review
incomplete or stale. No effectful tool or reverse-send is available in review
stages.

## Memory

Memory capture is explicit-only. Attaché saves a durable fact only when you
ask it to remember something ("remember...", "save...", "note that...") in a
call or direct chat. Nothing is noticed or suggested automatically, and there
is no suggestion review queue. Two modes:

- **Off** (default for fresh users who skip onboarding): no writes at all.
- **On**: an explicit ask saves immediately after the local validator passes.
  The ask is explicit-in-context: affirming Attaché's own offer to remember
  counts, and the saved statement must appear, in the user's own words, in one
  of the user's recent turns of the active conversation (negation preserved;
  hang-up clears the window). A statement the user never said is rejected. A
  quiet "Memory saved" chip in the call surface is the confirmation channel
  and opens the Memory settings pane.

### What is never saved

Secrets, credentials, financial account data, private reasoning, transient
moods, guesses, inferred protected traits, medical/legal conclusions, and
work-session content not explicitly restated by the user.

### Local storage and egress

Memory records are stored locally with 0600 file permissions. Each record has
an egress label (local-only or allowed-remote). Local-only memories never
appear in remote-bound requests, even when the active personality uses a
remote model. A model tool can only propose local-only memory. Promoting one
record for remote use requires an explicit native per-item confirmation in
Settings. Legacy migration and JSON import also start every record local-only;
an imported egress label is never treated as disclosure consent.

### Scope

Memory visibility and network egress are separate controls. A saved record can
be scoped to:

- **All personalities** for stable facts and preferences that should follow the
  user everywhere.
- **This personality** for a relationship, tone, shared history, or standing
  instruction that belongs only to one character.
- **This topic** for a bounded subject that should not leak into unrelated
  conversations.

Attaché filters scope before memory text enters a request. A personality-scoped
record is invisible to other personalities, and switching characters does not
copy it. Global memory should remain the default for ordinary user facts;
personality scope should be reserved for details whose meaning really depends on
that character.

### Inspection and correction

You can inspect which memories informed a response, edit them, accept or
reject proposals, forget individual records, undo supersessions, export all
records, or delete all memory. Forgetting a record removes it from future
retrieval.

## Provider Egress Classes

Attaché classifies where data goes before any request:

- **On-device**: data stays on your Mac. No network.
- **Loopback**: local model (e.g., Ollama at 127.0.0.1).
- **Local network**: LAN-hosted model. Stays on your network.
- **Configured remote**: your own hosted endpoint.
- **Subscription remote CLI**: Codex or Claude CLI, backed by a subscription.
  Leaves your Mac.
- **Unknown custom**: a custom provider Attaché cannot classify. Fails closed.
- **Disabled**: the provider is turned off.

Consent transitions (local to remote, or trust-class changes) require
reconsent.

## Context Receipts

Every model-backed response has a privacy-safe context receipt. It shows:

- Provider, model, strategy, estimated tokens, effective budget
- Source categories with counts and dispositions (included, omitted,
  truncated, staged)
- Omission reasons (unauthorized, budget, egress, stale, staged)
- Whether a fallback was used and that context was recompiled
- Safe focused-session display metadata (title and source, not hidden
  sessions)

The receipt deliberately does not reveal: prompt text, memory text, excerpts,
private reasoning, file contents, full paths, API keys, or tool-result
content.

## Fallback and Recovery

When the primary model fails, Attaché may fall back to another model in the
personality's ordered fallback list. The fallback request is newly compiled
for the fallback's concrete capacity, not replayed from the primary's
messages.

- **Rate limits, unavailable models, transient transport**: auto-fallback is
  allowed.
- **Context-limit overflow**: never auto-falls back. The draft is preserved
  and explicit retry with Automatic or Efficient is offered.
- **Authentication failures**: never auto-fallback.
- **Effectful tools**: never replayed on fallback. The effect tracker is
  carried forward.
- **Unknown fallback capacity**: uses an unknown-capacity plan, never the
  primary's limit.
- **Per-call reset**: a new call starts with the personality's primary again.

## Semantic Retrieval Benchmark

An ADR documents the on-device semantic retrieval benchmark
(`docs/adr/INF-314-on-device-semantic-retrieval.md`). The verdict is defer:
the lexical reranker is a pure-Foundation proxy and no real on-device semantic
option has been measured against the runtime gates on laptop-class hardware
yet. Optional semantic reranking (INF-322) stays blocked until the benchmark
recommends shipping. The FTS-only baseline remains the production retrieval
engine.

## Developer Architecture

### Core types (Sources/AttacheCore/)

- **AttacheRequestAuthority**: freezes the active personality and authorized
  session for every model role. Legacy persona store removed (INF-304).
- **AttacheContextPolicy**: ModelIdentity, AttacheModelCapabilityProfile with
  provenance/confidence, AttacheContextStrategy, AttacheContextCustomPolicy,
  versioned AttacheContextPolicyRecord (INF-305).
- **SessionFTSIndex**: SQLite FTS5 index over privacy-filtered session chunks
  with provenance locators (INF-306). Reconciliation and insertion run on the
  background session-index queue. A fast app-owned metadata catalog keeps
  Command-K and model-assisted discovery usable during a first build. JSONL
  records over 2 MiB are omitted from the discovery index to bound memory;
  explicitly focused transcript reads remain available on demand under their
  separate 64 MiB per-record safety ceiling.
- **AttacheDataEgress**: endpoint-aware egress classifier and consent
  transitions (INF-307).
- **AttacheCapabilityDiscovery**: parsers for Codex cache, Ollama show/ps,
  hosted model lists, plus AttacheCapabilityCache (INF-308).
- **AttacheContextBudget**: TokenEstimating protocol, conservative
  Unicode-aware fallback estimator, ContextBudgetPlanner (INF-309).
- **AttacheMemoryLedger**: SQLite-backed structured memory ledger with typed
  records, scope/egress/supersession, secret filtering (INF-310).
- **AttacheSessionSearchService**: unified Core search service over the FTS
  index (INF-311).
- **ContextCompiler**: the keystone pure context compiler. Every role compiles
  through it (INF-312).
- **AttacheContextStrategyUI**: strategy descriptions, capability summary,
  view model (INF-313).
- **AttacheRetrievalBenchmark**: sanitized evaluation corpus, predeclared
  thresholds, FTS/lexical/hybrid candidates, verdict (INF-314).
- **AttacheSessionDiscovery**: two-phase safe session discovery coordinator
  (INF-315).
- **AttacheDirectChatSummary**: provenance-backed rolling direct-chat summaries
  (INF-316).
- **AttacheToolBudgetEnforcer**: per-call and cumulative tool budget enforcer
  (INF-317).
- **AttacheTokenUsageCalibration**: provider token usage parser and
  content-free calibration (INF-318). Underestimation can raise estimates after
  five observations. Overestimation needs at least twenty consistent
  observations, uses the upper 95th-percentile ratio with additional headroom,
  and can reduce an estimate by at most 25 percent. Downward calibration never
  applies to Custom or unknown-capacity models and never changes a hard limit.
- **AttacheMemorySelector**: pure memory selector with policy filtering and
  conflict surfacing (INF-319).
- **AttacheProgressiveTranscriptTools**: inspect, search, readRange for
  focused transcripts (INF-320).
- **AttacheFallbackRecompiler**: recompile per fallback model with explicit
  overflow recovery (INF-321).
- **AttacheProjectFileTools**: inspect, search, readRange for project files
  (INF-323).
- **AttacheMemoryProposals**: explicit-only memory capture policy, validation,
  and consolidation (INF-324).
- **AttacheContextReceiptView**: privacy-safe context receipts (INF-325).
- **AttacheSessionMap**: incremental session maps with topic episodes (INF-326).
- **AttacheHierarchicalCapsules**: pure provenance and validation primitives
  for future persisted hierarchical retrieval (INF-328). Production direct
  chat currently uses local extractive capsules, while whole-session review
  uses session-map stages and validated citations.
- **AttacheExhaustiveReview**: exhaustive whole-session review with coverage
  ledger (INF-329).
- **AttacheEvaluationHarness**: deterministic offline evaluation gate (INF-330).

### Schema versions

- SessionFTSIndex: schema version 2
- AttacheMemoryLedger: migration version 1
- AttacheDirectChatSummaryStore: schema version 2
- AttacheCalibrationStore: schema version 1

### Evaluation gate

Run `scripts/context-evaluation.sh` for the deterministic offline evaluation
harness. It measures budget compliance, authorization leakage, strategy
monotonicity, memory scope/egress, effectful-tool-once, incomplete-never-
complete, report-no-secrets, and determinism. All scenarios must pass for a
green gate.

Run `scripts/context-smoke.sh` for the release gate. It reports the actual
XCTest cases executed across named authorization, budget, memory, retrieval,
receipt, fallback, and review matrices. It then packages the app and captures
the exact production-broker payload for every request role over HTTP and the
tool-isolated Claude CLI path without contacting a provider. Codex personality
inference has a separate fail-closed canary because its CLI cannot currently
disable native file-reading tools. The conversation artifacts
use a synthetic frozen focus grant and matching session evidence before session
tools are enabled. The gate verifies every captured artifact, proves a payload
mutation is rejected, drives the packaged context, memory, receipt, discovery,
overflow, and exhaustive-review surfaces through accessibility, and proves a
missing review surface makes that UI gate fail. `scripts/release-readiness-smoke.sh`
invokes this gate first.
