# Two-way: the "Go live" channel

Status: shipped in v0.1.0. This is the design of record for the code in
`AttacheCore` (`InstructionReplyEngine`, `InstructionSafetyFilter`, `Instruction`)
and `AttacheApp` (`TwoWayCoordinator`, `AgentResumeDeliveryAdapter`, the send
UX).

## What it is

"Go live" lets you talk back by voice or text in two explicit modes. **Ask
Attaché** sends the turn to the active personality, which may read the watched
session and may request `stage_agent_instruction` when it decides the user wants
the agent instructed. **Tell Agent** sends the exact turn to the focused Codex or
Claude Code session through Attaché's two-way pipeline.

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
resume** primitive (`claude -p --resume <id> "<text>"`,
`codex exec resume <id> "<text>"`), **queued until the target session is idle**.
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
| **Claude Code CLI** | `claude -p --resume <id> "<text>"` | Appends real turns to the *same* session JSONL, keeps the *same* `session_id`, no fork file. A later resume sees the full history including the appended turn. | headless resume, queued until idle |
| **Claude Code Desktop** | same headless resume (shared `~/.claude/projects`) | Append lands in shared storage. Present on the session's next open/restart; live visibility while the desktop app holds the session open can lag, so the UX shows "delivered, may need a Desktop refresh". | headless resume, queued until idle |
| **Codex CLI** | `codex exec resume <id> "<text>"` | Resume-by-id appends to the shared rollout file, id and filename unchanged (no fork). | headless resume, queued until idle |
| **Codex Desktop** | same headless resume (shared `~/.codex/sessions`) | Same as Codex CLI on disk; desktop live visibility can lag, same "may need a refresh" hint. | headless resume, queued until idle |
| *(rejected)* raw JSONL injection | write a turn directly into the session file | Invisible to the desktop apps until restart; forges history; breaks on format changes. | not used |
| *(future)* live-into-running-process | vendor remote-control / app-server, or Attaché-as-MCP inbox | Reaches a *running* process without a second writer. Not in this design. | later enhancement |

## Idle detection

Delivery only fires when the target session is **idle**, so a headless resume (a
second writer) never interleaves with the agent writing the same file.
`TwoWayCoordinator` resolves the session's transcript file and treats it as idle
when it has not been appended to for a quiet window (`SessionActivityClassifier`,
default 6s), which lines up with the watcher's own ~6s completed-turn debounce
(three 2s polls). A session is safely idle when all hold:

1. **No growth:** the session file's length is unchanged across the quiet window
   (no newly appended bytes).
2. **Turn complete:** the last surfaced record is a completed assistant turn (for
   Codex, a `final_answer`; for Claude Code, a top-level non-sidechain
   `assistant` message), never mid-tool-call and never a dangling user turn.
3. **Not being written this instant:** the file's modification time is older than
   the current poll tick.
4. **Nothing in flight:** no delivery is already in progress for this session.

The debounce is deliberately conservative so a model pausing briefly between tool
calls is not mistaken for done. While the target is not idle, the instruction
stays queued; the transition to idle is the trigger to deliver. Confirmed
instructions expire (fail) after a bounded window (default 30 minutes) so an
undeliverable one never fires hours later.

## Safety

Two-way turns Attaché from an observer into an actuator, so these are hard
constraints, enforced in `InstructionReplyEngine` and `InstructionSafetyFilter`:

- **Off by default, per session.** Two-way must be explicitly enabled for a
  specific session. No global preference bypasses session-level enablement.
- **Confirm by default, direct by explicit preference.** The default
  `AgentInstructionSendPolicy` creates an instruction as `pending` and only
  leaves that state after explicit visual confirmation. A power-user preference
  can skip the final sheet after a session is already enabled; that still runs
  the same target check, safety filter, idle queue, and delivery log.
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
- **Persisted instruction log.** Every instruction is logged with its text,
  target session, timestamps, state transitions, delivery mechanism, outcome, and
  the narration card the agent's reply produced. The log is the audit trail.
- **Deleted/archived target.** If the session is gone when delivery is attempted,
  the instruction fails with a clear reason; it is never redirected to a different
  session.
- **Reply is narrated normally.** After delivery, the agent's reply is observed by
  the watcher like any other update and narrated, and the resulting card is linked
  back to the instruction.

## Smoke and canary coverage

Two-way has three intentionally separate verification layers:

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
   first-use enable sheet and per-message confirmation, waits for real Codex to
   answer, then asks the personality to use `read_session_transcript` and report
   the result. The smoke forces plain watched-card readback and skips topic
   tagging so success depends on Codex's watched answer, not a presentation-model
   paraphrase. It still uses real Codex auth/network, but it does not require
   xAI, Claude, Anthropic, OpenAI, Groq, Ollama, or LM Studio credentials.

Attaché intentionally does **not** use a host-side natural-language intent
router to decide whether a live message should go to the personality or the
agent. That approach is brittle for multilingual speech and free-form phrasing,
and false positives are unsafe because they can send a message to an agent when
the user meant to ask Attaché a question. Destination is a visible UI state:
Ask Attaché or Tell Agent. LLM inference remains available inside Ask Attaché
through the provider-neutral `stage_agent_instruction` tool, but hidden
phrase-matching is not a routing contract.

Personality tools are provider-neutral. HTTP providers that support the
OpenAI-style `tool_calls` protocol receive the normal structured tool schema.
CLI-backed personalities such as `claude_cli` and `codex_cli` still run the
vendor CLI with its native filesystem/tools disabled, but Attaché exposes its own
bounded app tools through a JSON bridge in the prompt and parses that response
before executing anything. That means every personality provider can request
`stage_agent_instruction`, `read_session_transcript`, transcript search,
working-directory listing, file reads rooted in the attached session, and
Attaché-local session renames without giving the CLI subprocess direct tool
access.

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

Pre-release coverage adds eight opt-in gates through
`scripts/release-readiness-smoke.sh`:

1. `scripts/release-install-smoke.sh` builds a candidate, wraps it in a temporary
   DMG, installs it into a temp Applications directory, verifies the installed
   bundle, and launches that installed app with the UI smoke driver.
2. `scripts/upgrade-from-stable-smoke.sh` builds the stable baseline from
   `origin/main` (or `ATTACHE_STABLE_REF`), seeds state through the stable app,
   installs the current candidate over it, and verifies the candidate still sees
   the pre-upgrade card and settings.
3. `scripts/provider-canaries.sh` verifies the personality tool-calling contract
   across local and configured hosted providers.
4. `scripts/codex-two-way-safety-smoke.sh` proves approval-like send-to-agent
   payloads are refused before confirmation and never reach a transcript.
5. `scripts/agent-destination-smoke.sh` configures a text-only CLI personality,
   focuses a disposable Codex session, switches the live conversation to Tell
   Agent, and proves Attaché opens the send-to-agent confirmation path without
   relying on provider-side tool calls or host-side phrase matching.
6. `scripts/no-key-first-run-smoke.sh` proves a fresh no-key profile stays on the
   local Ollama default, seeds no cloud credentials, and still files a card.
7. `scripts/macos-lifecycle-smoke.sh` proves launch, quit, relaunch, local event
   server recovery, and Settings still work.
8. `scripts/load-smoke.sh` indexes many fake Codex sessions, files many local
   cards, and verifies Command-K plus inbox search remain responsive.

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
  state: enum { pending, confirmed, delivering, delivered, failed, canceled }
  createdAt: Date
  confirmedAt: Date?
  deliveredAt: Date?
  deliveryMechanism: String?     // e.g. "headless-resume"
  error: String?                 // failure reason / stderr on failure
  resultingCardID: String?       // the narration card the agent's reply produced
}
```

Delivery goes through the `InstructionDeliveryAdapter` protocol: the engine is
agent-agnostic and talks only to `capability(forSessionID:)` and
`deliver(_:)`. `AgentResumeDeliveryAdapter` implements it once per vendor,
resolving the session file, reporting `requiresIdle: true`, and performing the
resume. The surface (CLI vs desktop) only affects display copy and the
"may need a refresh" hint, never the delivery call.
