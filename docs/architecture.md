# Architecture

Attaché is one native macOS app (pure SwiftPM, no `.xcodeproj`). It watches the
AI coding agents running on your Mac (OpenAI Codex and Claude Code, CLI and
desktop) and speaks their work out loud in a voice and personality you choose.
This is the map a new contributor follows: the two targets, how agent activity
comes in, how a raw turn becomes a spoken update, and how "Go live" talks back.

## Two targets

- **`AttacheCore`** (`Sources/AttacheCore`): pure logic, no AppKit, unit-tested.
  Transcript parsing, narration coalescing, pipeline ordering and dedup, the
  SQLite card store, session indexing/tagging/search, caption alignment, and the
  two-way instruction reply engine (with its safety filter). New logic that can
  be unit-tested belongs here.
- **`AttacheApp`** (`Sources/AttacheApp`): the SwiftUI/AppKit app. The menu bar
  item and windows, the local event server, the session watchers, the
  presentation-model service and its providers, speech synthesis and playback,
  the two-way delivery adapters and coordinator, and every view.

`AttacheApp` depends on `AttacheCore`, never the reverse. A third small
executable, `AttacheUISmoke`, drives the app through the accessibility API for
the UI smoke harness; it is test scaffolding, not part of the product.

`AppModel` (in `AttacheApp`) is the main-actor hub that wires these pieces
together and owns the observed UI state.

## The pipeline, end to end

```text
agent activity
  ├─ HTTP event  (POST /events, token-guarded)   → LocalEventServer
  └─ pinned session transcript (polled)           → CodexSessionWatcher
        │
        ▼
  EventNormalizer            normalize + validate a NormalizedEvent
        │
        ▼
  NarrationCoalescer         collapse one multi-message agent turn into one turn
        │
        ▼
  AttachePresentationService  turn raw agent output into a short spoken update
        │                        in the active personality's voice (pluggable
        │                        provider: local CLI or HTTP)
        ▼
  CardStore (SQLite)         persist a voicemail card (raw text + summary + spoken)
        │
        ▼
  Speech + captions          synthesize audio (ElevenLabs or on-device AVSpeech),
                             analyze it, play it with word-timed captions
```

### 1. Ingestion: two sources

`AttacheApp` accepts agent activity two ways, both local:

- **Event bridge (HTTP).** `LocalEventServer` binds a loopback listener on
  `127.0.0.1:7531` and accepts `POST /events`. `scripts/send-event.sh` posts a
  demo event; a Claude Code hook can post real ones. The server is hardened: it
  requires a per-launch bearer token written to
  `~/Library/Application Support/Attache/event-token` (mode 0600), rejects any
  request carrying an `Origin` or a non-loopback `Host` (anti DNS-rebinding),
  caps body size and concurrent connections, and exposes only an unauthenticated
  `GET /health`. `POST /cards/<id>/play` and `/cards/<id>/mark-heard` drive
  playback for integrators.
- **Session watcher.** `CodexSessionWatcher` polls the on-disk transcripts of the
  sessions you have pinned, on a ~2s timer, tracking a per-session byte offset so
  it parses only newly appended JSONL. It reads both vendors' storage: Codex
  rollouts under `~/.codex/sessions/...` and Claude Code sessions under
  `~/.claude/projects/<slug>/<id>.jsonl`. It emits a normalized event per
  completed turn and never re-reads the whole file on the timer. It also raises
  needs-you attention transitions (see below). `SessionActivityWatcher` is a
  second, lighter poller that surfaces interstitial "what the agent is doing
  right now" phrases for the live activity ticker.

Only pinned sessions are watched. Pin with Command-K; the catalog of active
sessions refreshes on a low cadence so new sessions appear without a manual
refresh.

### 2. Normalize and coalesce

`EventNormalizer` turns any inbound payload into a validated `NormalizedEvent`
(non-empty text, stable source/type/title, receipt timestamp for ordering).
`NarrationCoalescer` then buffers the stream of parsed transcript records and
collapses a single multi-message agent turn into one `CoalescedTurn`, so a burst
of assistant messages becomes one spoken recap and one card rather than several.
It is pure and deterministic (an in-flight buffer plus an idle-poll counter, no
clock or filesystem), and flushes a turn on a real boundary: a Codex
`final_answer`, a new human turn, or a quiet window.

`PipelineOrdering` keeps the timeline sane: presentation is serialized per
session (a slow model call for an earlier event can't let a later one's card land
first), while different sessions prepare concurrently, and a late out-of-order
update is filed read instead of spoken as new.

### 3. Presentation model: pluggable providers

`AttachePresentationService` is the layer that rewrites raw agent output into a
short spoken update in the active personality's voice. It builds a prompt from
the active persona, a bounded durable-memory block, and the observed event, then
calls the provider owned by the active personality. The provider is pluggable
(`AttachePresentationProvider`):

- **Local CLI providers** run a coding agent you are already logged into, as a
  subprocess, with no API key: Claude subscription (`claude`) or Codex
  subscription (`codex`). This path is sandboxed (tool use denied); it is for
  text generation only, kept deliberately separate from the two-way delivery
  path that is allowed to act.
- **HTTP providers** call an OpenAI-compatible `chat/completions` endpoint: xAI
  (Grok), Groq, and any custom OpenAI-compatible base URL (for example OpenAI
  itself), plus the local server Ollama. Ollama needs no key and defaults to a
  loopback endpoint; the hosted providers read their key from
  the shared secret vault. Reasoning effort and service tier are sent only for
  providers/models that advertise them.

Each personality owns its provider, model, supported reasoning level, ordered
live-call fallbacks, voice, and playback pace. The model's output becomes the
spoken and captioned update; the raw agent output stays stored for inspection
but is never the normal voice surface. A bounded deterministic read-back is the
failure fallback when personality presentation cannot run.

Durable memory and the persona prompt are editable local app-support files.
Memory is used only for tone, routing, and preferences; it is never evidence that
the app inspected a file, tool, or service.

### 4. Speech and captions

The speech layer owns TTS engine choice, the generated audio asset, deterministic
audio analysis of that exact asset, playback (pause, replay, seek, configurable
skip), and caption timing. Two engines ship: **ElevenLabs** (key read from the
secret vault) and **on-device macOS AVSpeech** (stores the chosen voice
identifier, falls back to the system voice if it goes missing). The app does not
silently swap a chosen cloud engine for another; failures surface in voice
status. Captions render the full line and color only the active word inline, tint
derived from the current theme; if provider word-alignment is missing, a fallback
alignment produces the same inline highlight. Seeks update the audio clock first,
then the caption word and the visualizer frame are recomputed from that
timestamp. The Echoform visualizer consumes analysis frames from the audio asset
being played and decays to near-still when idle.

Secrets (LLM and voice provider keys) are read through a shared vault:
`AttacheSecretVault` uses the login Keychain for signed builds and a 0600
`DevelopmentSecrets.json` fallback for unsigned development runs (Keychain ACLs do
not survive ad-hoc rebuilds); the first signed access migrates the fallback into
Keychain. Under `ATTACHE_UI_TEST=1` the vault never touches the real Keychain.

## Inbox, recap, and needs-you

Every update becomes a voicemail card in the SQLite `CardStore`. Live mode speaks
cards from the focused session as they arrive (queued single-file so one recap
finishes before the next starts); otherwise cards collect silently as unread
voicemail.

- **Inbox** (Command-I): the catch-all list of cards, replayable and skippable,
  filterable to the focused session, watched sessions, Codex, or Claude Code.
- **History** (Command-Y): prior spoken recaps and replies for review; selecting
  one replays it through the normal card playback path. Direct conversation
  replies share a frozen conversation id so the user can permanently delete the
  whole saved conversation. Any row can explicitly request Another Take from a
  different personality.
- **Recap** is one-shot: `InboxDigest` clusters unread cards by session, the
  presentation model writes a single spoken digest, the summarized originals are
  archived out of the inbox (they remain in history), and the recap plays as its
  own card. With no model configured it speaks a deterministic template digest.

**Needs-you** is the one interrupt. When a watched session enters a
waiting-on-you state (a `needs_attention` event from a Claude Code Notification
hook, or the watcher classifying the transcript as awaiting an answer), Attaché
files a priority notice immediately with no model pass and posts a local
notification through `AttacheNotifier` at a time-sensitive interruption level.
Delivery is entirely governed by macOS Focus and Do Not Disturb; the app builds
no quiet-hours logic of its own and nothing is ever marked critical. The notice
clears automatically once the session moves again. Everything that is not
needs-you just waits in the inbox.

## Two-way: the "Go live" channel

"Go live" (Command-L) is a two-way voice channel. It has two halves:

- **Talk to Attaché.** A live voice conversation with the active personality
  (`AttachePresentationService.converse`) that can pull deeper context on demand
  through session-reading tools (read/search the transcript, list the working
  directory, read a file, rename the session locally) and can request
  `stage_agent_instruction` when it decides the user wants the work agent
  instructed. Your speech is transcribed by `MicTranscriptController`; the reply
  is spoken with the same captions.
- **Push direction back to the agents.** A confirmed instruction is delivered
  into the target Codex or Claude Code session using the vendor's own headless
  resume (`claude -p --resume`, `codex exec resume`), queued until that session is
  safe to resume. `TwoWayCoordinator` requires stable file state and a completed
  top-level assistant turn with no unresolved tools, then drives
  `InstructionReplyEngine` (in `AttacheCore`), which owns the
  per-session enable gate, the safety filter, confirmation, single-flight FIFO
  delivery, expiry, and the audit log. `AgentResumeDeliveryAdapter` performs the
  resume (one adapter per vendor; CLI and desktop share session storage). This
  path uses the user's configured confirmation policy and deliberately inherits
  their own agent permissions. Persisted in-flight work fails closed after a
  restart. Full design of record: `docs/two-way.md`.

The live UI makes the destination explicit with Ask Attaché and Tell Agent.
Attaché does not use host-side phrase matching to infer destination from a
message such as "tell Codex..." because that fails across languages and creates
unsafe false positives. Tell Agent sends the raw turn through the two-way safety
pipeline as a one-shot destination; Ask Attaché lets the configured personality
reason and use app-owned tools. Agent sends require a focused session, and each
call freezes its target identity, title, source, and working directory so focus
changes cannot retarget a staged instruction. The structured instruction payload
is frozen separately and compared with persisted state immediately before
delivery; any mismatch fails closed.

Private Call is a separate storage mode frozen at call start. It does not write
conversation cards, memory proposals, direct-chat capsules, renames, or agent
instructions. Recent turns and locally generated continuity capsules exist only
in process memory and are cleared at hangup. This is a local Attaché storage
guarantee, not a promise about retention by a selected cloud model or voice
provider, which the UI states directly.

## Live call UI: the composer and `CallPhase`

The on-call composer is `onCallHUD` (`Sources/AttacheApp/Views/CallHUD.swift`,
an extension on `AttacheRootView`): the destination picker (Ask Attaché /
Tell Agent), one input row (AX label "Call message", the smoke harness's
target), and a single status region. It is the one status home while on a
call: nothing else duplicates it, other than the mic transcript overlay, which
has nowhere else to render while a turn is actively being captured (INF-251/A3).

What that status region shows is driven entirely by `CallPhase`
(`Sources/AttacheCore/CallPhase.swift`), a pure enum with no UI or AppModel
dependency: `.idle`, `.listening(mode:)`, `.thinking(since:)`,
`.preparingAudio`, `.speaking`, `.paused`, `.sendQueued(target:since:reason:)`,
`.sendDelivered(target:)`, `.failed(category:message:)`, and
`.fallbackAnnounced(message:)` (INF-258/D5, the opt-in auto-fallback chain's
neutral "just switched provider" notice, distinct from `.failed`). A pure
reducer, `CallPhase.derive(from: CallSignals)`, maps a snapshot of the live
call's raw signals (mic state, conversation wait, playback state, pending
send, failure) to exactly one phase, in a fixed precedence order (an active
mic and a failure always win over everything else; `.speaking` beats a
lingering `.sendDelivered`). `CallStatusPresentation`
(`Sources/AttacheApp/CallStatusPresentation.swift`) then maps a `CallPhase` to
display text, an icon, and error styling, so styling comes only from the
phase and its `ConversationFailureCategory`, never from scanning status text
for marker words (INF-244/A2). Both are unit-tested as pure functions
(`Tests/AttacheCoreTests/CallPhaseTests.swift`,
`Tests/AttacheAppTests/CallStatusPresentationTests.swift`) without a view host.

`Sources/AttacheApp/Views/ConversationView.swift` is a second, older composer
(AX label "Conversation message") that predates the `CallPhase` rework above.
It is not instantiated anywhere in the current view hierarchy; the UI smoke
harness's generic `sendConversationPrompt` helper still matches either label
defensively, but only "Call message" is reachable in the shipped app today.

## Security

Local-first, hardened by default.

- The HTTP listener binds loopback only, requires a per-launch token, rejects
  cross-origin/rebinding requests, and caps body size and connection count. Do not
  weaken these to make testing easier.
- API keys are never stored in the repo and never in plaintext when avoidable;
  they live in the Keychain for signed builds.
- Instructions reach an explicitly focused, frozen agent session only through
  the supported vendor channel (headless resume), under the configured
  confirmation policy, only when the transcript is safe to resume, never as an
  approval/permission token, and at most one delivery in flight per session.
  Attaché never writes into agent session files directly.

## Packaging

One installable app. The user drags `Attache.app` to `/Applications`, sees a
normal Dock item and one menu bar item, and gets one updater. Signed and notarized
under the Bryanlabs LLC Apple Developer ID, bundle id `com.bryanlabs.attache`. Any
future internal helper process must stay invisible to ordinary users.
