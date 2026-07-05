# Two-way communication: channel design (INF-159)

Status: design of record for the M7 implementation tickets (INF-171 reply engine,
INF-172 delivery adapters, INF-173 send UX). Two-way ships with launch.

## Summary

Attaché delivers a confirmed user instruction back to a watched agent session using
the vendor's **own headless resume** primitive (`claude -p --resume <id> "<text>"`,
`codex exec resume <id> "<text>"`), **queued until the target session is idle**. This
is the single v1 mechanism for all four surfaces, because:

- It uses the vendor's own writer, so it never forges agent-authored history and does
  not break when the on-disk format changes.
- CLI and Desktop for a vendor share the same session storage, so the same primitive
  reaches both; the only real variable is whether the session is mid-turn, which
  queue-until-idle resolves.
- It degrades safely: if a surface does not reflect the appended turn live, the turn is
  still really there and appears on the session's next open/resume.

Raw JSONL injection (writing turns directly into the session files) is the **rejected
baseline** (see matrix). Live injection into an actively-running process is **out of v1
scope**; the vendor remote-control / app-server / MCP channels are the documented future
path for that.

## Empirical channel matrix

Tested on this machine 2026-07-02. CLI = interactive terminal session; Desktop = the
vendor desktop app. Both share on-disk session storage per vendor
(`~/.claude/projects/<slug>/<sessionId>.jsonl`;
`~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`).

| Surface | Mechanism | Observed behavior | v1 delivery |
|---|---|---|---|
| **Claude Code CLI** | `claude -p --resume <id> "<text>"` | **TESTED.** Appends real turns to the *same* session JSONL (6 → 12 lines), keeps the *same* `session_id`, no fork file created. A later resume sees the full history including the injected turn. | headless resume, queued until idle |
| **Claude Code Desktop** | same headless resume (shared `~/.claude/projects`) | Append lands in shared storage (proven by the CLI test). **Live visibility while the Desktop app has the session open is DAN-VERIFY** (see test script). Present on next open/restart regardless. | headless resume, queued until idle; show "delivered — may need Desktop refresh" until live behavior is confirmed |
| **Codex CLI** | `codex exec resume <id> "<text>"` | Documented: "Resume a previous session by id ... Prompt to send after resuming." Structurally identical to Claude (resume-by-id appends to the shared rollout file). A full live capture **timed out in this spike** (codex exec was slow/blocked); **DAN-VERIFY** append + id-stability alongside the Desktop cells. | headless resume, queued until idle |
| **Codex Desktop** | same headless resume (shared `~/.codex/sessions`) | Same as Codex CLI on disk; **live Desktop visibility DAN-VERIFY.** | headless resume, queued until idle |
| *(rejected)* raw JSONL injection, any surface | write a turn directly into the session file | **REJECTED.** Dan verified injected turns are invisible to the Desktop apps until restart; also forges agent-authored history and breaks on format changes. Kept here only as the documented rejected baseline. | not used |
| *(future)* live-into-running-process | `codex remote-control` / `codex app-server`, `claude --remote-control`, or Attaché-as-MCP inbox | Experimental vendor channels that can reach a *running* process without a second session writer. Not in v1. | post-launch enhancement |

### Dan-verify test script (Desktop live + after-restart, and Codex append)

For each vendor, with the Desktop app open on a known session id `SID`:

```
# Claude
echo "Append the word PING and nothing else." | \
  claude -p --resume "$SID" --output-format json --tools "" \
  --permission-mode dontAsk --setting-sources "" --strict-mcp-config

# Codex
codex exec resume "$SID" "Append the word PING and nothing else."
```

Record three things per surface: (a) does the turn appear in the Desktop app **live**
(no restart)? (b) does it appear after **restarting** the Desktop app? (c) for Codex,
confirm the rollout file grew and the session id/filename is unchanged (no fork). The v1
recommendation does **not** depend on (a); queue-until-idle + resume is correct either
way. (a) only decides whether we show a "may need refresh" hint.

## Idle detection (precise, from existing watcher signals)

Delivery only fires when the target session is **idle**. Idle is derived entirely from
signals the watcher already has (`CodexSessionWatcher`, 2s poll, per-session byte offset
in `fileOffsets[sessionID]`, completed-assistant gating). A session is idle and eligible
when ALL hold:

1. **No growth:** the resolved session file's byte length equals the last recorded
   `fileOffsets[sessionID]` across **≥3 consecutive polls (~6s)**. No new appended bytes.
2. **Turn complete:** the last surfaced record is a *completed assistant turn* — Codex: a
   `response_item` / `type=message` / `role=assistant` with `phase == final_answer` (the
   watcher's existing `shouldSpeak(phase:)` gate); Claude Code: a top-level
   `type == "assistant"`, non-sidechain message. Never mid-tool-call, never a dangling
   user turn.
3. **Not being written this instant:** file mtime is older than the current poll tick.
4. **Nothing in flight:** no delivery already in progress for this session
   (single-delivery invariant).

The ~6s debounce (3 polls) is deliberately conservative so a model that pauses briefly
between tool calls is not mistaken for done. When the target is *not* idle, the
instruction stays queued; the watcher transition into the idle state is the trigger to
deliver.

Rationale for never delivering to a non-idle session: a headless resume spawns a
*separate* process that writes the same session file. Two concurrent writers to one
session risk interleaved/corrupt records. Queue-until-idle guarantees a single writer.

## Safety design

Two-way turns Attaché from an observer into an actuator, so the safety rules are hard
constraints, not preferences:

- **Off by default, per session.** Two-way must be explicitly enabled for a specific
  session. There is no global "always send" switch.
- **Confirm before every send.** Each instruction requires explicit user confirmation
  (spoken read-back + visual confirm) before delivery. No instruction is ever
  auto-sent.
- **Never deliver approvals.** The engine must refuse to deliver a payload whose content
  is an agent-side permission/tool approval (bare "yes", "y", "approve", "allow",
  "confirm", "2", etc.). Attaché must not be usable to click through an agent's
  permission prompt on the user's behalf. This is a content-level refusal in the reply
  engine, independent of the adapter.
- **One delivery in flight per session.** Additional confirmed instructions queue FIFO
  behind the in-flight one (recommended queue depth: small, e.g. 1 active + short
  backlog).
- **Persisted instruction log.** Every instruction is logged: text, target session,
  timestamps, chosen mechanism, delivery outcome, and the narration card produced by the
  agent's reply. The log is the audit trail.
- **Deleted/archived target.** If the session is deleted or archived while an instruction
  is queued, the instruction is canceled with a clear reason; it is never redirected to a
  different session.
- **Response is narrated normally.** After delivery, the agent's reply is observed by the
  watcher like any other update and narrated, with the resulting card linked back to the
  instruction in the log.

## Concurrency and identity

- **Session identity** is the external session id the watcher already tracks
  (`attachedCodexSessionID`, catalog ids). It is common to CLI and Desktop for a vendor,
  so an instruction targets a session, not a surface.
- **Single writer:** exactly one headless resume per session at a time (enforced by the
  in-flight invariant + queue-until-idle).
- **Ordering:** instructions to a session deliver FIFO in confirmation order.
- **Mid-queue identity loss:** delete/archive → cancel queued instruction with
  `failed`/`canceled` + reason.

## Data model: instruction log

Stored in the existing local SQLite DB alongside cards. Append-only state transitions.

```
Instruction {
  id: UUID
  sessionID: String                 // external agent session id (shared CLI/Desktop)
  vendor: enum { claude, codex }
  sourceSurface: enum { claudeCodeCLI, claudeCodeDesktop, codexCLI, codexDesktop }
  text: String                      // instruction as confirmed by the user
  createdAt: Date
  confirmedAt: Date?
  state: enum { pending, queued, delivering, delivered, failed, canceled }
  deliveryMechanism: enum { headlessResume }   // v1; room for remoteControl/mcp later
  deliveredAt: Date?
  outcome: String?                  // vendor exit status / stderr on failure
  linkedResponseCardID: String?     // narration card produced by the agent's reply
  failureReason: String?
}
```

Adapter contract (consumed by INF-172): `InstructionDeliveryAdapter` takes a resolved
session id + instruction text and performs one headless resume, returning a delivery
outcome. One adapter per vendor; the surface only affects display copy and the
"may need refresh" hint, not the delivery call.

## SPEC / architecture changes (made in this same change)

- `SPEC.md` "Adapter Rules": the MVP one-way boundary is replaced with: adapters may
  deliver an instruction back to a session **only** via a supported channel (headless
  resume), **only** with explicit per-instruction user confirmation, **only** while the
  session is idle, **never** an approval/permission token, and **at most one** delivery
  in flight per session. Card/live composers may now target the agent (send) in addition
  to answering the user; the send path is explicit and confirmed.
- `SPEC.md` harness-adapter list: `never send a message back into Codex from the
  companion` → replaced by the confirmed-send boundary above.
- `docs/architecture.md` Security: `Do not send messages into Codex ...` → send only via
  supported channels with explicit per-instruction confirmation and queue-until-idle.
