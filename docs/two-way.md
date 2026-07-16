# Two-way: the "Go live" channel

Status: shipped in v0.1.0. This is the design of record for the code in
`AttacheCore` (`InstructionReplyEngine`, `InstructionSafetyFilter`, `Instruction`)
and `AttacheApp` (`TwoWayCoordinator`, `AgentResumeDeliveryAdapter`, the send
UX).

## What it is

"Go live" lets you talk back by voice or text in two explicit modes. **Ask
Attaché** sends the turn to the active personality, which may read the watched
session and may request `stage_agent_instruction` only for an explicit request to
act through the agent. Questions about what an agent said, did, can do, or should
do stay with Attaché. **Tell Agent** sends the exact next turn to the focused
Codex or Claude Code session through Attaché's two-way pipeline, then immediately
returns to Ask Attaché before hands-free listening resumes.

Agent sends require an explicitly focused session. Attaché freezes the session
ID, source kind, display title, and working directory when the call begins, and
uses that snapshot for personality tools, confirmation, and delivery until
hang-up. Ask Attaché remains available without a focused session, but Tell Agent
is disabled and explains how to focus one. The HUD names the frozen target while
Tell Agent is selected.

Two-way must still be enabled for that specific session before anything reaches
the agent. After enablement, Attaché delivers the instruction only after the
configured confirmation policy is satisfied. By default that means a per-message
confirmation sheet; users can opt into direct send after a session is enabled.
The agent's reply is then observed and narrated like any other update, and
linked back to the instruction in an audit log.

The four surfaces it targets are Codex and Claude Code, each in CLI and desktop
form.

## Delivery approach

Attaché delivers a confirmed instruction using the vendor's **own headless
resume** primitive (`claude -p --resume <id> --output-format json "<text>"`,
`codex exec resume --skip-git-repo-check --json <id> "<text>"`), **queued until
the target session is idle**. The `--skip-git-repo-check` flag lets Codex
resume sessions whose working directory is not a Git checkout. Both invocations
add a structured-output flag so delivery can parse evidence of a completed
assistant turn out of stdout instead of trusting exit code 0 alone (see Data
model below); stdout and stderr are each captured to a bounded (~1MB) buffer
under a hard process timeout (default 5 minutes).
One mechanism reaches all four surfaces, because:

- It uses the vendor's own writer, so it never forges agent-authored history and
  does not break when the on-disk format changes.
- CLI and desktop for a vendor share the same session storage, so the same
  primitive reaches both. An instruction targets a *session*, not a surface.
- It degrades safely: if a desktop surface does not reflect the appended turn
  live, the turn is still really there and appears on the session's next
  open/resume.

The resume runs as a subprocess that inherits your own agent permissions, exactly
as if you had typed the instruction yourself. This is deliberately the opposite of
the sandboxed CLI path used for the presentation model (`CLILanguageModel`): the
two paths are kept clearly separated, and no transcript text is ever routed
through the delivery path.

Raw JSONL injection (writing turns directly into the session files) is the
rejected baseline: it is invisible to the desktop apps until they restart, forges
agent-authored history, and breaks on format changes. Live injection into an
already-running process is out of scope for this design; the vendors' remote
control / app-server / MCP channels are the documented future path for that.

## Channel matrix

CLI = interactive terminal session; Desktop = the vendor desktop app. Both share
on-disk session storage per vendor
(`~/.claude/projects/<slug>/<sessionId>.jsonl`;
`~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`).

| Surface | Mechanism | On disk | Delivery |
|---|---|---|---|
| **Claude Code CLI** | `claude -p --resume <id> --output-format json "<text>"` | Appends real turns to the *same* session JSONL, keeps the *same* `session_id`, no fork file. A later resume sees the full history including the appended turn. | headless resume, queued until idle |
| **Claude Code Desktop** | same headless resume (shared `~/.claude/projects`) | Append lands in shared storage. Present on the session's next open/restart; live visibility while the desktop app holds the session open can lag, so the UX shows "delivered, may need a Desktop refresh". | headless resume, queued until idle |
| **Codex CLI** | `codex exec resume --skip-git-repo-check --json <id> "<text>"` | Resume-by-id appends to the shared rollout file, id and filename unchanged (no fork). | headless resume, queued until idle |
| **Codex Desktop** | same headless resume (shared `~/.codex/sessions`) | Same as Codex CLI on disk; desktop live visibility can lag, same "may need a refresh" hint. | headless resume, queued until idle |
| *(rejected)* raw JSONL injection | write a turn directly into the session file | Invisible to the desktop apps until restart; forges history; breaks on format changes. | not used |
| *(future)* live-into-running-process | vendor remote-control / app-server, or Attaché-as-MCP inbox | Reaches a *running* process without a second writer. Not in this design. | later enhancement |

## Idle detection

Delivery only fires when the target session is **idle**, so a headless resume (a
second writer) never interleaves with the agent writing the same file.
`TwoWayCoordinator` resolves the session transcript and uses
`SessionDeliveryReadinessClassifier` across a quiet window (default 6s).
Readiness sampling is event-driven (INF-255/B4): the session watcher's
`onEvent` callback schedules a pump whenever it observes file activity,
debounced ~1s so a fast burst of updates collapses to a single pump rather than
one per event. The coordinator's ~8s refresh timer still runs alongside it as
a backstop, catching a session that goes quiet with no further watcher event to
trigger the event-driven path (e.g. one that was already idle when Attaché
started watching it). Together the practical delivery floor is the ~1s
debounce after the watcher observes the session has gone quiet, not the ~8-16s
floor of sampling on the timer alone; the 6s quiet window above is unchanged
either way. A session is safe to resume when all hold:

1. **No growth:** the session file's length is unchanged across the quiet window
   (no newly appended bytes).
2. **Turn complete:** the last surfaced record is a completed assistant turn (for
   Codex, a `final_answer`; for Claude Code, a top-level non-sidechain
   `assistant` message), never mid-tool-call and never a dangling user turn.
3. **Stable modification time:** both size and modification time match the prior
   observation, and the modification time is older than the quiet window.
4. **Nothing in flight:** no delivery is already in progress for this session.

The debounce is deliberately conservative so a model pausing briefly between tool
calls is not mistaken for done. While the target is not idle, the instruction
stays queued; the transition to idle is the trigger to deliver. Instructions
expire (fail) after a bounded window (default 30 minutes) measured from
creation, for pending and confirmed alike, so an undeliverable one never fires
hours later. A slow confirmation therefore consumes part of the delivery
window.

## Safety

Two-way turns Attaché from an observer into an actuator, so these are hard
constraints, enforced in `InstructionReplyEngine` and `InstructionSafetyFilter`:

- **Off by default, per session.** Two-way must be explicitly enabled for a
  specific session. No global preference bypasses session-level enablement.
  Enablement is durable: it is persisted in SQLite (`two_way_enablement`,
  written through by `InstructionReplyEngine.setTwoWayEnabled`) and restored
  when a fresh engine loads, so a restart no longer silently resets every
  session to off. Restoration still checks that the session's transcript file
  exists before honoring the persisted row (the same check delivery already
  relies on): a session that has been deleted or rotated away does not come
  back enabled, and its stale row is pruned. This is separate from instruction
  state - interrupted pending/confirmed/delivering instructions still fail
  closed on restart (surfaced at startup) rather than resuming; that recovery
  path (`recoverInterruptedInstructions`) is unchanged (INF-242/B5).
- **Confirm by default, direct by explicit preference.** The default
  `AgentInstructionSendPolicy` creates an instruction as `pending` and only
  leaves that state after explicit visual confirmation. A power-user preference
  can skip the final sheet after a session is already enabled; that still runs
  the same target check, safety filter, idle queue, and delivery log.
- **Frozen explicit target and payload.** Agent sends require a focused session.
  The target identity and display title are captured at call start, while the
  exact structured instruction is captured when the turn is staged. Both are
  stored on every instruction and retained in an in-memory delivery snapshot. A
  focus change cannot retarget the tool call, and a persisted payload or target
  mismatch fails closed before the adapter runs.
- **Wrong-agent guard, fail closed, never reroute.** When the personality names
  a specific agent in its `stage_agent_instruction` call (`intended_agent`,
  INF-246/C2), Attaché compares that declared value against the frozen target's
  source before staging anything: `AgentInstructionMismatch.evaluate` in
  `AttacheCore` is a pure comparison of two already-known values, never a
  parse of the user's own words. A mismatch blocks staging entirely, with a
  distinct reason for each case (the named agent has no watched session at
  all; it does have one but it isn't focused; or the value didn't decode to a
  recognized agent) — the app never redirects the instruction to the agent
  the model actually named. Omitting `intended_agent` skips this check
  entirely, so staging proceeds exactly as it did before this guard existed.
- **Tell Agent is one-shot.** The raw turn is captured, staged or sent, and the
  destination resets to Ask Attaché before voice listening can accept another
  utterance.
- **Never deliver approvals.** The safety filter refuses any payload that is
  really an agent-side permission or tool approval, whether a bare token
  ("yes", "y", "approve", "allow", "1", "2", ...) or a phrase asking the agent to
  grant a permission or bypass its sandbox ("allow all tools", "bypass sandbox",
  "--dangerously", ...). Attaché must not be usable to click through an agent's
  permission prompt on your behalf. This is a content-level refusal, independent
  of the adapter.
- **One delivery in flight per session.** The engine delivers FIFO in
  confirmation order and marks an instruction `delivering` before the async call,
  so a concurrent pump sees the single-flight and additional confirmed
  instructions queue behind it.
- **Restart fails closed.** On startup, persisted pending, confirmed, or
  delivering instructions are marked failed with a review-and-resend message.
  Attaché cannot prove how far a pre-crash resume got, so it never retries one
  automatically. The same message is surfaced in the app's status area on
  launch, rather than living only in the audit row.
- **Persisted instruction log.** Every instruction is logged with its text,
  original user wording, origin, frozen target title, target session, timestamps,
  state transitions, pre-resume transcript checkpoint, delivery mechanism,
  outcome, and the narration card the agent's reply produced. The log is the
  audit trail.
- **Deleted/archived target.** If the session is gone when delivery is attempted,
  the instruction fails with a clear reason; it is never redirected to a different
  session.
- **Reply is narrated and correlated, positionally.** After delivery, the
  agent's reply is observed by the watcher like any other update. A card links
  to an instruction when the transcript after the stored delivery checkpoint
  contains a completed assistant turn; the single-flight FIFO delivery
  guarantee above means the bytes between one instruction's checkpoint and the
  next belong to it, so position is sufficient and exact text equality against
  the (possibly presentation-paraphrased) narrated card is only a secondary
  confidence signal, never a gate (INF-245/B2). When the transcript hasn't yet
  shown the completed turn but the delivery adapter already captured
  `deliveryReplyText` synchronously from the resume's own output, that evidence
  cross-checks and unblocks the link without waiting for the next transcript
  poll. Unrelated session cards are not linked by proximity alone. Every
  correlation miss for a session with an outstanding delivered instruction logs
  a warning with the reason.

## Smoke and canary coverage

Two-way has five intentionally separate verification layers:

1. **Default UI smoke:** `scripts/ui-smoke.sh` is free/local and excludes paid
   or network-dependent flows. It should stay green before every release.
2. **Direct Codex round trip:** `scripts/codex-two-way-smoke.sh` creates a
   disposable `CODEX_HOME`, copies only the Codex auth file, spawns a fresh Codex
   session, sends a confirmed instruction through real `codex exec resume`, waits
   for the transcript to append the resumed user turn and Codex reply, and checks
   that Attaché files the reply as a watched-session card. It uses real Codex
   auth/network and real Codex model calls, but no presentation provider.
3. **Personality-to-Codex round trip:**
   `scripts/codex-personality-two-way-smoke.sh` adds the personality layer. It
   starts a deterministic local OpenAI-compatible provider, asks the personality
   to stage a Codex instruction through `stage_agent_instruction`, drives the
   first-use enable sheet and confirmation, verifies a second explicit handoff
   still requires native confirmation even when Tell Agent direct-send is
   enabled, waits for real Codex to answer, and audits the
   stored origin, source wording, exact structured payload, frozen target, and
   delivery checkpoints. It also asks what Codex said, verifies that question uses
   `read_session_transcript` without staging another instruction, and reports the
   result.
   The smoke forces plain watched-card readback and skips topic
   tagging so success depends on Codex's watched answer, not a presentation-model
   paraphrase. It still uses real Codex auth/network, but it does not require
   xAI, Claude, Anthropic, OpenAI, Groq, or Ollama credentials.
4. **Codex personality isolation canary:**
   `scripts/codex-personality-routing-canary.sh` loads legacy `codex_cli`
   personality settings through the production service and proves they fail
   before compilation, subprocess launch, or app-tool execution. Codex CLI's
   read-only sandbox does not disable native file-reading tools, so it is not an
   eligible personality backend. This canary runs as part of the opt-in Codex
   release-readiness extras, while the direct and staged two-way gates continue
   to exercise Codex as an explicit agent destination.
5. **Direct Claude Code round trip:** `scripts/claude-two-way-smoke.sh`
   (INF-257/E2) is the Claude analog of layer 2. It copies only the
   `claudeAiOauth` portion of the real Claude credentials (Keychain item
   "Claude Code-credentials", or `~/.claude/.credentials.json`) into a
   disposable `CLAUDE_CONFIG_DIR`, spawns a fresh session via `claude -p`, runs
   the same off-call watch/enable/confirm sequence through a real
   `claude -p --resume`, and checks the reply is filed as a watched-session
   card. Unlike layer 2, presentation is left at its default (not forced to
   plain readback) since reply correlation is positional (INF-245/B2): this
   gate is the proof that a presentation paraphrase of a real Claude Code
   reply does not break card linking. Every place Attaché locates Claude
   session state resolves through `ClaudePaths`, which honors a
   `CLAUDE_CONFIG_DIR` override exactly like this gate's disposable one, so
   session discovery, the live watcher, and delivery all agree on where to
   look (a real defect here, INF-261, went undetected until this gate first
   exercised a real successful delivery).

Attaché intentionally does **not** use a host-side natural-language intent
router to decide whether a live message should go to the personality or the
agent. That approach is brittle for multilingual speech and free-form phrasing,
and false positives are unsafe because they can send a message to an agent when
the user meant to ask Attaché a question. Destination is a visible UI state:
Ask Attaché or Tell Agent. LLM inference remains available inside Ask Attaché
through the provider-neutral `stage_agent_instruction` tool, but hidden
phrase-matching is not a routing contract. The tool prompt is deliberately
conservative: uncertainty stays with Attaché, while explicit action requests may
be handed off under the user's configured confirmation policy.

Personality tools are provider-neutral. HTTP providers that support the
OpenAI-style `tool_calls` protocol receive the normal structured tool schema.
The `claude_cli` personality provider runs Claude Code with its native tools,
settings, MCP servers, skills, slash commands, and session persistence disabled.
Codex CLI cannot currently make the equivalent native-tool guarantee, so Attaché
keeps it available as an agent source and reverse-send destination but refuses
to use it for personality inference. Attaché exposes its own bounded app tools
through a JSON bridge in the prompt and parses that response before executing
anything. That means every enabled personality provider can request
`stage_agent_instruction`, `read_session_transcript`, transcript search,
working-directory listing, and file reads rooted in the attached session
without giving the CLI subprocess direct tool access. Session renames remain
an explicit app-owned action and are not exposed to the personality model.

The provider canaries are separate: `scripts/provider-canaries.sh` always runs a
deterministic local OpenAI-compatible provider as a free positive control, then
tests xAI, OpenAI-compatible, Groq, and Ollama when credentials or local models
are available. Missing hosted-provider credentials are reported as SKIP by
default so the suite does not require paid subscriptions; set
`ATTACHE_PROVIDER_CANARIES_REQUIRE_HOSTED=1` to make hosted-provider credentials
mandatory. The individual wrappers are `scripts/xai-tool-calling-canary.sh`,
`scripts/openai-tool-calling-canary.sh`, `scripts/groq-tool-calling-canary.sh`,
`scripts/ollama-tool-calling-canary.sh`, and
`scripts/local-provider-tool-calling-canary.sh`.

Pre-release coverage adds eleven opt-in gates through
`scripts/release-readiness-smoke.sh`:

1. `scripts/context-smoke.sh` fails closed over the production and Core context
   test matrix, verifies real XCTest counts, captures and verifies packaged
   production-broker HTTP and CLI payloads for every request role, drives the
   packaged context-management UI, runs deliberate mutation checks, and checks
   all repository docs links.
2. `scripts/release-install-smoke.sh` builds a candidate, wraps it in a temporary
   DMG, installs it into a temp Applications directory, verifies the installed
   bundle, and launches that installed app with the UI smoke driver.
3. `scripts/upgrade-from-stable-smoke.sh` builds the stable baseline from
   `origin/main` (or `ATTACHE_STABLE_REF`), seeds state through the stable app,
   installs the current candidate over it, and verifies the candidate still sees
   the pre-upgrade card and settings.
4. `scripts/provider-canaries.sh` verifies the personality tool-calling contract
   across local and configured hosted providers.
5. `scripts/codex-two-way-safety-smoke.sh` proves approval-like send-to-agent
   payloads are refused before confirmation and never reach a transcript.
6. `scripts/agent-destination-smoke.sh` configures a text-only CLI personality,
   focuses a disposable Codex session, switches the live conversation to Tell
   Agent, proves the frozen target is visible, proves Attaché opens the
   send-to-agent confirmation path without provider-side tool calls or host-side
   phrase matching, and proves the destination resets to Ask Attaché after one
   turn.
7. `scripts/conversation-feedback-smoke.sh` starts a deterministic local
   personality provider, presses the visible live Ask Attaché send button, proves
   the text field clears, proves a thinking indicator appears while the provider
   is delayed, proves audio-prep feedback appears, proves the reply starts
   through karaoke captions, and proves the reply is filed as a replayable card.
8. `scripts/no-key-first-run-smoke.sh` proves a fresh no-key profile stays on the
   local Ollama default, seeds no cloud credentials, and still files a card.
9. `scripts/macos-lifecycle-smoke.sh` proves launch, quit, relaunch, local event
   server recovery, and Settings still work.
10. `scripts/load-smoke.sh` indexes many fake Codex sessions, files many local
   cards, and verifies Command-K plus inbox search remain responsive.
11. `scripts/two-way-negative-path-smoke.sh` proves the three negative-path
    invariants above end to end against disposable fake Codex sessions: a
    delivery failure (fake codex exits nonzero) shows the stderr tail in the
    call status and logs `failed`; a queued send against a session kept
    perpetually non-idle visibly expires (via a test-only, opt-in-only
    `ATTACHE_TWO_WAY_EXPIRY_SECONDS` window) naming the window and target; and
    killing the app mid-send and relaunching surfaces the startup recovery
    message and logs the interrupted instruction `failed`.

The scripts fail closed on failed session creation, missing confirmation UI,
transcript timeout, missing watcher card, missing required tool calls, failed
bundle verification, failed state restore, or missing installed app artifacts.
They clean up their temp `CODEX_HOME` roots and generated test app bundles on
exit.

## Concurrency and identity

- **Session identity** is the external session id the watcher already tracks. It
  is common to CLI and desktop for a vendor, so an instruction targets a session,
  not a surface.
- **Single writer:** exactly one headless resume per session at a time (the
  in-flight invariant plus queue-until-idle).
- **Ordering:** instructions to a session deliver FIFO in confirmation order.
- **Mid-queue identity loss:** delete/archive of the target fails the queued
  instruction with a reason.

## Data model

Instructions live in the local SQLite DB alongside cards, as `Instruction`
(`Sources/AttacheCore/Instruction.swift`), with append-only state transitions:

```
Instruction {
  id: String
  sessionID: String              // external agent session id (shared CLI/Desktop)
  sourceKind: String             // "codex" | "claude_code"
  text: String                   // instruction as confirmed by the user
  origin: enum { tell_agent, personality_tool, off_call_composer, legacy }
  sourceUtterance: String?       // original Ask Attaché wording before a rewrite
  targetDisplayName: String?     // frozen title shown in confirmation and audit
  state: enum { pending, confirmed, delivering, delivered, failed, canceled }
  createdAt: Date
  confirmedAt: Date?
  deliveredAt: Date?
  deliveringAt: Date?            // most recent entry into .delivering, for stuck-delivery
                                  // strand recovery (INF-249/B6); distinct from confirmedAt,
                                  // which predates the idle wait, not the delivery attempt
  deliveryMechanism: String?     // e.g. "headless-resume"
  deliveryCheckpoint: Int64?     // transcript byte offset immediately before resume
  deliveryReplyText: String?     // assistant reply parsed from the resume output as delivery evidence
  deliveryReplyTurnID: String?   // turn/session identifier parsed from the resume output, if present
  workingDirectory: String?      // session's cwd, frozen at staging time (INF-260); claude -p
                                  // --resume only finds a session from its original cwd, so the
                                  // Claude delivery adapter spawns with this instead of Attaché's
                                  // own process cwd (Codex's --skip-git-repo-check is cwd-independent,
                                  // so this is unused on that path)
  error: String?                 // failure reason / stderr tail on failure
  resultingCardID: String?       // the narration card the agent's reply produced
}
```

Delivery evidence (`deliveryReplyText`/`deliveryReplyTurnID`) comes from parsing the
resume's own output rather than trusting exit code alone: Claude via `--output-format
json` (a single JSON result object; delivered requires `type == "result"`, `subtype ==
"success"`, `is_error == false`, and a non-empty `result`), Codex via `--json` (JSONL
thread events; delivered requires a completed `agent_message` item). Exit 0 without
that evidence is recorded `failed` with `"exited 0 but no assistant turn in output"`,
not `delivered`, so a stale session id or a silently rejected turn can no longer look
like a successful send.

Delivery goes through the `InstructionDeliveryAdapter` protocol: the engine is
agent-agnostic and talks only to `capability(forSessionID:)` and
`deliver(_:)`. `AgentResumeDeliveryAdapter` implements it once per vendor,
resolving the session file, reporting `requiresIdle: true`, and performing the
resume. The surface (CLI vs desktop) only affects display copy and the
"may need a refresh" hint, never the delivery call.
