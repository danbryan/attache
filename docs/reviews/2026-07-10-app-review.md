# Application review, 2026-07-10

Scope: the two-way bridge, live-call UI, model configuration, failure handling,
smoke coverage, and doc freshness. Method: code and smoke harness first, docs
second, per the review request. Reviewed at `c00e551` on
`danb/fix-cloud-voice-playback-fallback` (10 commits ahead of local `main`;
everything since 07-09 lives only on this branch). The `archive` remote named in
AGENTS.md is not wired in this clone, so pre-launch history was not consulted;
`git remote -v` shows only `origin`.

## Verdict

The two-way bridge's safety architecture is genuinely good and matches
`docs/two-way.md`: freeze-at-submit, per-session enablement, confirm-by-default,
fail-closed on restart and on frozen-content mismatch, single-flight FIFO
delivery, and a real end-to-end Codex smoke (f7) that most projects this age
would not have. The "buggy and not predictable" feeling does not come from the
architecture. It comes from a small set of identifiable mechanics: deliveries
that report success on exit code alone, reply correlation that breaks on any
paraphrase, an 8-16s polling floor with a silent 30-minute give-up, state that
evaporates on restart, and UI status derived from scattered booleans plus
substring matching instead of one state machine. Every instinct in the review
request checks out, and two of them are cheaper than expected: all five LLM
consumers already funnel through one settings loader, so per-role models are a
contained refactor, and a harness-owned system prompt already exists and already
contains a wrong-agent rule; it is missing runtime context, not a new layer.

## 1. Why the bridge feels unpredictable

Ranked by how much unpredictability each one generates.

**1. Delivery success is exit code 0, nothing more.**
`AgentResumeDeliveryAdapter` shells `claude -p --resume` / `codex exec resume
--skip-git-repo-check` with stdout discarded (`TwoWayDeliveryAdapters.swift:77-104`).
A resume that silently no-ops (stale or wrong session id, agent rejects the
turn) is recorded `delivered`. The app then waits for a reply that will never
come, which reads as "the bridge is flaky." Fix: run with `--output-format
json` / `--json`, require evidence of an accepted turn in the output, and
capture stderr into the failure message. The resume output usually contains the
assistant's reply, which also enables a stronger reply link (next item).

**2. Reply correlation demands an exact text match.**
`linkResponseCard` matches a transcript turn against the delivered instruction
by normalized exact text (`TwoWayCoordinator.swift:114-119`,
`SessionReplyCorrelation`, `TwoWayDeliveryAdapters.swift:279-316`), but the card
pipeline persists the presentation-rewritten text (`AppModel.swift:1288-1297`).
Any paraphrase breaks the link; the f7 smoke passes only because it forces
`ATTACHE_FORCE_PLAIN_READBACK=1`. Real usage with a personality on is exactly
where "I sent it but never heard back" comes from. Fix: correlate by position
and time (record the transcript offset at delivery; link the next completed
assistant turn), or carry the raw event text through to correlation. Every
correlation miss today is a silent guard-return with no UI.

**3. Waiting and expiry are invisible.**
Readiness needs two identical observations at least 6s apart, but observations
are sampled on the ~8s refresh pump (`TwoWayCoordinator.swift:140`,
`AppModel.swift:638`), so the floor is one to two pump cycles after the session
quiets, and a session that never quiets (a desktop app holding the file) rides
until the 30-minute expiry, whose result is discarded at the pump
(`TwoWayCoordinator.swift:95`) and logged only to the audit table. The user
sees "Sending when the session is quiet…" once, then nothing, forever. Fix:
surface the waiting state with elapsed time and the reason, surface expiry as a
failed status/card, and pump on watcher `onEvent` (`AppModel.swift:728`) instead
of only on the timer so delivery follows the session going quiet immediately.

**4. Two-way state is memory-only.**
`enabledSessions` and `submittedSnapshots` live only in memory
(`InstructionReplyEngine.swift:25,88`). Every app restart silently disables
two-way for every session and fails staged work closed. Fail-closed is the
right direction, and startup recovery is surfaced (`AppModel.swift:698`), but
silent enablement reset means "it worked yesterday" mysteries. Persist
enablement in SQLite, or state plainly in the UI that it reset.

**5. Engine DB writes are `try?` at every transition**
(`InstructionReplyEngine.swift:156,169,208,228`). A failed write mid-transition
can strand an instruction in `.delivering` with no error anywhere. Propagate.

Also worth fixing while in there: CLI-personality tool calls are recovered by
brace-balancing JSON scraping of free text
(`CompanionPresentationService.swift:466-530`); when the model wraps the JSON in
prose the tool call silently degrades into a spoken answer. One corrective
retry turn ("re-emit exactly one JSON object, no prose") would recover most of
these.

## 2. Live-call UI

The states mostly exist; they are split across two surfaces with gaps, and
nothing owns the truth.

| State | Exists? | Where | Gap |
|---|---|---|---|
| Listening | yes | top overlay live transcript (`CompanionRootView.swift:497-539`) | no indicator in the composer; `callMicStatusText` (`CallHUD.swift:141-163`) is rich but rendered only as a `.help` tooltip |
| Thinking | yes | composer "Thinking… Xs" + spinner (`AppModel.swift:1739`, `CallHUD.swift:76`) | the entire top bar disappears while thinking: `topOverlayVisible` excludes `isConversing` (`CompanionRootView.swift:912-919`) |
| Generating audio | yes | "Preparing audio…" (composer) and "Preparing voice…" (top bar) | same state, two names |
| Speaking | yes | "Speaking…" (composer), "Assistant speaking" (top bar) | pure duplication on-call |
| Error | yes | red status + Switch model / Retry (`CallHUD.swift:80-95,231`) | error detection is substring matching, see below |
| Send in flight | weak | text only, "Sending to X when the session is quiet…" (`AppModel.swift:2283`) | no spinner (`isConversing` is false so the info icon renders), no elapsed time, no queue reason |
| Send delivered | weak | "Sent to X. Watching for the reply…" (`AppModel.swift:2306`) | visually identical to in-flight; wording is the only difference |

The root cause is that there is no call-phase type. Phase is inferred from
`isConversing`, `playback.isPlaying/isPaused/isBusy`, `expectingReplyAudio`, and
free-text status strings, and error styling is
`status.contains("failed"/"error"/"problem")` (`CallHUD.swift:201-207`), which
misfires on any status that happens to contain "problem" and silently breaks
if a wording change or localization drops the marker words.

**Recommendation:** introduce one enum in `AttacheCore` (testable), roughly
`CallPhase { idle, listening, thinking(since:), preparingAudio, speaking,
sendQueued(target:since:reason:), sendDelivered(target:), failed(category:,
recovery:) }`, derive both the composer status and the top overlay from it, and
delete the substring heuristics. This one change is most of the "niceties"
list: distinct thinking/audio/error/send states, spinners and elapsed time
where they belong, and no state where the window goes silent.

**The top bar.** Half agree with removing it. On-call, its state line
("Assistant speaking", "Preparing voice…") duplicates the composer and should
go. But off-call it is the only status surface there is: inbox playback, unread
count, and "Listening for agent updates" all render there
(`CompanionRootView.swift:921-927`), and f2/f3 smoke assertions target those
exact strings. And the second line (session · project provenance,
`cardContext`, `:942`) is information the composer does not carry when the
destination is Ask Attaché. Concrete proposal: on-call, suppress the top bar
entirely except while the mic is live (the eyes-up live transcript is worth
keeping), and move "session · project" into the transport bar next to the time
readout so provenance survives; off-call, keep it as is. f3's pause/speaking
assertions would need to move to the transport bar labels.

## 3. Per-role models (personality vs everything else)

Confirmed: one global selection. All five consumers - per-event presentation
(`AppModel.swift:1277`), inbox recap (`:1509`), topic tagging (`:3475`), live
conversation (`:1840`), and follow-up answers (`:3759`) - call the same
`CompanionPresentationSettings.load()` (`CompanionPresentationService.swift:890`)
reading the same `presentationLLM*` UserDefaults keys (`:902-967`). Instruction
phrasing is a tool argument of the converse call, so it rides the conversation
model. There is no way to run Grok for the personality and something else for
recaps today.

Because of that single funnel, the split is contained:

- Add `ModelRole { conversation, presentation, recap, tagging }` (follow-ups
  ride conversation). `load(role:)` reads `presentationLLM.<role>.*` and falls
  back to the existing global keys, so nothing changes until a role is set.
- Model pane: an "Advanced: per-task models" disclosure, each role defaulting
  to "Use main model." Credentials already live per-provider in Integrations,
  so mixing providers needs no new key UX.
- Two details to get right: the recovery Switch-model action must update the
  failing role's selection, not the global one; and cloud consent
  (`cloudConsentPresentation`) is a single flag today, so switching one role to
  a new cloud provider should re-prompt.

Worth doing beyond the flexibility itself: tagging and presentation are
high-volume and cheap, and pointing them at a local model (Ollama/LM Studio are
already first-class providers, `CompanionPresentationProvider.swift:3-10`) cuts
cost and rate-limit pressure on the conversation model.

## 4. Failure detection and fallback

Current truth: no retry or backoff anywhere on chat calls (single
`URLSession.shared.data`, 120s timeout,
`CompanionPresentationService.swift:394-420,659-687`). Errors become strings.
`ConversationRecovery.classify` string-matches usage/model markers
(`ConversationRecovery.swift:18-41`), only the live-converse path uses it
(`AppModel.swift:1873-1887`), and recovery is manual: a Switch model menu and
Retry button (`CallHUD.swift:231`). Other consumers degrade deterministically
(presentation → plain readback, recap → digest, tagging → skipped) which is
good design, but mostly silently.

Recommended order:

1. **Classify structurally, not textually.** The HTTP status is in hand when
   the error string is built (`Service.swift:1011-1013`); keep it (and the
   `URLError` code) on the error type so 429/402/5xx/timeout classification is
   exact. Keep the string markers only for CLI providers, whose failures arrive
   as text.
2. **Extend the existing manual recovery everywhere.** Recap and follow-ups
   deserve the same Switch/Retry affordance; presentation can keep auto
   readback but should badge the card with why ("spoken plainly - Grok quota").
3. **Then opt-in auto-fallback.** A user-ordered provider chain in settings
   (e.g. xAI → Codex CLI → Ollama). Auto-advance only on
   `usageOrRateLimit`, `modelUnavailable`, or timeout; never on auth errors,
   where switching hides a problem the user must fix. Every fallback is
   announced in the status line and spoken once ("Grok hit its usage limit;
   using Ollama for now"), sticky for the call, with return-to-primary on the
   next call. "Fall back to local" is then just chain order.
4. **The pattern already exists in-repo:** voice playback deterministically
   reverts a broken cloud voice to the system voice with a surfaced reason
   (`CompanionSpeechProvider.swift:82-117`). Mirror that shape for the LLM path,
   with the plain-readback path remaining the final rung.

## 5. Wrong-agent awareness and the system prompt

Partly built already, which is worth knowing before writing new prompt text.
`conversationSystemPrompt` (`CompanionPersonality.swift:233-282`) is already
layered - harness identity + personality profile + task rules + session
context - and already contains the rule: "If the user names a different agent
than the focused one, ask them to focus that session instead of staging"
(`:258`). Two real gaps:

1. **The model has no session inventory.** Context carries only the focused
   session (`:279-281`). It cannot say "I'm not watching any Codex sessions
   right now" or "did you mean the Claude Code session?" because it does not
   know what exists. Add a compact inventory block: watched sessions by source
   (title, age), capped at a handful, plus whether two-way is enabled for the
   focused one. Cheap, and it makes rule `:258` executable instead of
   aspirational.
2. **Nothing is deterministic.** Honoring `:258` depends on the model. Add an
   optional `intended_agent` (source) argument to `stage_agent_instruction`;
   app-side, `requestSendToAgent` (`AppModel.swift:2203`) fails closed with a
   specific status when it mismatches the frozen target: "You said Codex - the
   focused session is Claude Code (Weekly Codex Improvement Review). Focus a
   Codex session or say send it to Claude Code." This respects the
   no-phrase-routing decision of record: the app never reroutes and never
   parses English; the LLM names the intent, the app only refuses mismatches.

On "a system prompt separate from the personality": that separation already
exists structurally; personas are interpolated between harness-owned blocks.
What is missing is content, not a layer: the runtime inventory above, and a
short error-behavior block ("when Attaché reports a blocked or failed send,
tell the user exactly what happened and the single next step"). Keep persona
files persona-only. One caution: the CLI tool bridge injects a second system
message (`CompanionPresentationService.swift:447-464`); put new harness text in
`conversationSystemPrompt` so the HTTP and CLI paths both receive it.

## 6. Verification coverage

Strong: f7 is a real Codex round trip (real `codex exec` session, real resume,
real `.jsonl` pong watch, SQLite instructions→cards join), f8 verifies the
staging/confirm plumbing against a mocked personality, and the routing canary
covers real intent classification opt-in. The harness driving everything
through AX labels is the right religion.

Gaps that map one-to-one onto the reported flakiness:

- **Claude Code has zero coverage on any layer.** Every smoke, fake or real, is
  Codex. The `claude -p --resume` delivery branch has never been exercised by
  automation. Build a fake-claude-home analog of `create-fake-codex-home.py`,
  then a real f7-style Claude gate.
- **`tell_agent` is never delivered under test.** f14 stages then cancels
  (`AttacheUISmoke/main.swift:1039-1062`). The origin used on live calls is the
  one origin with no end-to-end delivery test. Extend f14 (or add a gate) to
  deliver against the fake codex home.
- **No negative-path gates:** delivery failure (fake codex exiting nonzero),
  30-minute expiry, restart-fails-closed, never-goes-quiet. These are the
  two-way.md invariants users actually hit.
- Housekeeping: `scripts/__pycache__/` is untracked noise; gitignore it.

## 7. Docs

Applied as uncommitted edits alongside this review: AGENTS.md (archive remote
is not wired in a fresh clone - add-if-missing instructions; "Still manual" line
updated since f3 now asserts the visualizer; four missing testing affordances
documented: `ATTACHE_FORCE_PLAIN_READBACK`, `ATTACHE_DISABLE_TOPIC_TAGGING`,
`ATTACHE_LIVE_CODEX_ROUTING_TEST`, `SMOKE_POSE`/`SMOKE_TEXTSCALE`) and
docs/two-way.md (Codex resume command shows `--skip-git-repo-check`; idle
cadence corrected to the ~8s pump; expiry clarified as created-at based for
pending and confirmed alike; noted that enablement and delivery snapshots are
memory-only and reset on restart).

Not applied, worth a pass when the composer settles: architecture.md does not
mention the two distinct composer surfaces the harness drives ("Call message"
in CallHUD vs "Conversation message" in ConversationView).

## 8. Suggested order

1. `CallPhase` state machine driving both status surfaces (kills most of the
   unpredictable feel at the root; medium).
2. Delivery evidence + positional reply correlation (the two silent-failure
   generators; medium).
3. Session inventory in the system prompt + `intended_agent` mismatch guard
   (small, high leverage for the Codex/Claude confusion).
4. Structural error classification + recovery UI on all consumers (small).
5. Per-role model selection (medium).
6. Opt-in announced fallback chain (medium, after 4).
7. Top bar: suppress on-call, provenance into the transport bar, keep off-call;
   update f3 assertions (small).
8. Claude Code smoke parity (medium, high value given real usage is half
   Claude).

## Video

No changes made. Only note: if the on-call top bar or composer layout changes
(items 1 and 7), the live-call segment of the tour video will show a stale UI
and is worth a re-shoot; captions, tagline, and the rest are unaffected.
