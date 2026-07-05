# Two-way: the "Go live" channel

Status: shipped in v0.1.0. This is the design of record for the code in
`AttacheCore` (`InstructionReplyEngine`, `InstructionSafetyFilter`, `Instruction`)
and `AttacheApp` (`TwoWayCoordinator`, `AgentResumeDeliveryAdapter`, the send
UX).

## What it is

"Go live" lets you talk back to your agents by voice and push new direction into
a session they are working. You enable two-way for a specific session, speak or
type an instruction, confirm it, and Attaché delivers it into that Codex or Claude
Code session. The agent's reply is then observed and narrated like any other
update, and linked back to the instruction in an audit log.

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
  specific session. There is no global "always send" switch.
- **Confirm before every send.** An instruction is created `pending` and only
  leaves that state on explicit user confirmation (spoken read-back plus visual
  confirm). Nothing is ever auto-sent.
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
