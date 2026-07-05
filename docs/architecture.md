# Architecture

## MVP Architecture

The MVP is one macOS app process.

```text
Attache.app
  App shell
    Menu bar controller
    Companion window controller
    Settings controller

  Bridge core
    Event intake
    Adapter registry
    Codex session attachment
    Companion presentation
    Card store
    Companion follow-up questions

  Renderers
    Echoform renderer
    Optional avatar renderer

  Speech
    TTS provider adapter
    Generated voice audio asset
    Audio analysis timeline
    Caption alignment
    Playback controller

  Storage
    SQLite database
    Audio asset directory
```

## Module Boundaries

### App Shell

Owns native macOS behavior:

- app lifecycle,
- menu bar item,
- window creation,
- transparent window settings,
- always-on-top or click-through toggles,
- settings presentation.

### Bridge Core

Owns agent-facing behavior:

- normalized event intake,
- source and session registry,
- local Codex session attachment state,
- companion presentation for raw harness output,
- voicemail card creation,
- read and unread state,
- raw event retention,
- companion-only follow-up answers from observed context.

Bridge core should not depend on any one renderer. Raw harness output should be
stored, then converted into a card summary and spoken companion update through a
presentation stage. The presentation stage can call an OpenAI-compatible LLM
using the user's character prompt, model, provider, and reasoning effort.
Provider selection is a presentation concern, not a voice concern. The native
app exposes xAI/Grok, Ollama, LM Studio, Groq, and custom OpenAI-compatible
providers from Settings -> Personalities. Ollama defaults to `qwen3:7b` on
`http://127.0.0.1:11434/v1`; LM Studio defaults to
`http://127.0.0.1:1234/v1`. Local providers do not require API keys.
When a provider key or local endpoint is available, the app asks the provider
for model inventory through `/models`, xAI language-model discovery, or
Ollama's local tags endpoint. Reasoning choices are not universal. They are
shown only when the model discovery payload or a provider-specific capability
mapping identifies valid levels for the selected model.

The presentation prompt is a companion-owned conversation, separate from the
Codex session. It is built as:

- system message: Attaché persona, the current character prompt, and
  a bounded durable-memory block,
- user message: observed Codex event metadata and raw Codex output.

The LLM output becomes the spoken and captioned companion response. The raw
Codex response remains stored for inspection, but is not the voice surface. If
no provider is configured, the bridge falls back to a bounded deterministic
brief derived from the full response. The fallback must not collapse speech to
the first sentence of the card summary and must not read the raw Codex response
verbatim.

Provider API keys are read through the shared secret vault. Signed builds store
them in the login Keychain. Unsigned development runs can use the 0600
`~/Library/Application Support/Attache/DevelopmentSecrets.json` fallback because
Keychain ACLs do not survive ad-hoc rebuilds. The first signed read/write
migrates any fallback secrets into Keychain and removes the file.

The MVP durable-memory store is an editable local app-support file. Memory is
used for tone, routing, and user preferences only; it is not evidence that the
app checked a file, tool, browser, or connected service.

The persona prompt is also editable app state. Presets are only shortcuts for
the character prompt; the deeper companion identity prompt lives in a local
app-support file unless an explicit environment or defaults override is set.

### Renderers

Renderer implementations consume app state:

- playback envelope,
- mic level,
- companion status,
- unread count,
- card playback state,
- current caption line.

Renderers should not own harness routing or card persistence.

The abstract renderer owns a protected middle bar band. Text surfaces own the
top and bottom bands. Rings, glow, and wave hints may extend behind those text
bands, but bars should be clipped into the middle band so captions and status
text stay readable.

Display settings are app state, not renderer globals:

- visual mode,
- theme,
- brightness,
- intensity,
- captions enabled,
- low-latency captions,
- spoken language,
- on-device-only recognition,
- caption sync offset.

Quick Actions settings belong to the companion window surface, not only to the
idle visualizer. Right-click should reveal a compact custom palette instead of
a long native menu, and it must keep theme, visual mode, voice, caption, skip
interval, surface opacity, personality, and Codex session choices reachable
during playback.

Voicemail mode is separate from live mode. The live surface keeps a compact
unread badge and a left-edge watch rail for watched local-agent sessions.
Clicking the unread badge opens the global inbox by default. The inbox can be
filtered to the focused session, watched sessions, Codex, or Claude Code, but
the global view remains the catch-all so voicemail is not hidden by the wrong
session focus. Sessions with unheard voicemail show counts in Command K and in
the watch rail; non-session cards are grouped under General. Escape returns to
the Echoform-first live surface. Delete archives the selected card and Clear
Visible archives the visible scoped voicemail cards without confirmation.

The left-edge watch rail is a stable list of watched local-agent sessions, not
a selected-session stack. Selecting a watched session changes focus without
removing it from the watch list. The attached session is also shown by a
smaller top-center lock indicator with a detach affordance. Command K remains
the broader session picker and shows watched sessions plus sessions with
unheard voicemail near the top.

Companion History is a live-mode overlay for the attached session. It queries
recent cards by the attached `external_session_id` and shows prior spoken
companion recaps from that exact Codex thread. It is not the global voicemail
inbox and it does not change unread state. Selecting a history item only
highlights it; double-click or Play Selected reuses the normal card playback
path so the audio asset, Echoform analysis, transport clock, and karaoke
caption timing stay in one timeline.

History, captions, and the focus carousel share a fixed bottom HUD tray. The
tray is an overlay constrained by the existing window bounds, with internal
scrolling where needed. It must not ask SwiftUI or AppKit to resize the window
when playback starts, when a history row appears, or when caption text changes.

### Speech

Owns:

- TTS provider choice,
- generated voice audio assets for companion speech,
- selected assistant voice,
- deterministic audio analysis of the exact asset being played,
- audio playback,
- pause and replay,
- seek and configurable skip interval,
- caption timing,
- fallback alignment,
- live mic transcription when explicitly enabled.

The native speech path supports explicit engine selection. On-device macOS
speech stores the selected voice identifier in preferences, defaults to the
macOS system voice, and falls back to the system default if the chosen local
voice is missing. ElevenLabs and xAI provider keys are read through the shared
secret vault, which uses Keychain for signed builds and the development fallback
only for unsigned runs. Provider voice lists are fetched only after the user supplies a key; xAI
discovery merges built-in voices with team custom voices when the account
exposes them. The app does not silently fall back from a chosen cloud engine to
another engine; failures surface in voice status. Voice
settings belong to the speech layer, while visual analysis consumes the
generated audio asset regardless of provider.

The Echoform renderer must consume analysis frames derived from the active audio
source. For MVP companion speech, that source is the generated companion voice
asset. Idle or silent audio should decay to near-still visuals instead of
synthetic motion.

Caption rendering follows the prior Attaché karaoke component. Speech
owns the current playback clock and alignment data; the UI renders the full
caption text and colors only the active word inline. The active-word color is
derived from the current visual theme so caption emphasis feels integrated with
Classic, Cyberpunk, Aurora, and Ember. If provider alignment is missing, the
fallback alignment should still produce the same inline highlight behavior.

Seeking is driven by the playback controller. Slider seeks and skip buttons
update the audio player clock first, then the caption active word and renderer
analysis frame are recomputed from that same timestamp.

Mic transcription follows the same caption settings where possible. It requests
microphone and speech-recognition permission, streams partial speech recognition
results while enabled, and publishes them for the top user transcript band.
Translation remains a future speech-stage feature.

### Adapters

Harness adapters convert external events into normalized bridge events.

MVP adapters:

- simulated event adapter,
- Codex local adapter.

The Codex local adapter starts with explicit session attachment. The app reads
the local Codex session index, shows active sessions by default, keeps archived
sessions behind an explicit archived-session disclosure, persists the selected
session in app preferences, displays active watched sessions as compact
focus-session chips, and keeps the active attachment visible in the top-center
lock indicator. The active-session catalog refreshes periodically at a low
cadence, currently every eight seconds, so new Codex sessions appear without
manual refresh. Automation definitions are scheduling metadata, not watchable
targets. When an automation is running, the companion attaches to the concrete
Codex session id created or resumed by that run.

Routing depends on attachment:

- active attached session updates are live interaction and can be spoken
  immediately without becoming unread voicemail,
- if another matching attached-session update arrives while the companion is
  already speaking or paused, it stays queued and plays only after the current
  recap finishes,
- non-attached session updates are background work and become unread voicemail
  cards,
- no companion UI path sends data back into Codex.

Follow-up is companion-only. The follow-up editor accepts the user's typed or spoken
question, runs it through the companion personality and bounded context from the
selected Codex card, and produces an answer addressed to the user. The answer may
explain what instruction the user could manually give Codex, but it must not claim
to send, queue, or execute that instruction.

Live mode also has a direct attached-session question composer. It does not
require a voicemail card; The user can type a question about the locked session or
dictate, then copy the captured transcript into the question input. For direct
attached-session questions, the app builds a synthetic context card from the
selected card and recent attached-session history so short requests like "what
chapter is next" can be resolved from observed context. The composer is opened
from the message button in the top-center lock chip so the live visual surface
can stay quiet until The user wants to ask the companion something.

The first direct observation path watches the selected active Codex session
file under `~/.codex/sessions` and extracts final assistant messages. This
covers the case where Codex Desktop writes the session transcript but no bridge
hook posts to `/events`. Broader automation and non-attached session capture
should be implemented as a background adapter or explicit event bridge source,
so the app does not silently drain old archived transcripts.

The Codex transcript watcher is a background adapter and must behave like one.
It may do an initial catch-up read when a target is first attached, then it must
track file offsets and parse only appended complete JSONL records. It should
not run full-file JSON parsing on a repeating timer, because active Codex
sessions can be large and the companion may be running with no visible window.

Codex and Claude Code are both supported today by watching their local session
transcripts. Future adapters (alternative mechanisms):

- Claude Code hooks (the transcript watcher already ships),
- MCP server surface,
- generic webhook,
- terminal transcript watcher.

## One Process Now, Helper Later

Start with one process for speed and simplicity.

Keep these seams clean so an internal helper can be extracted later:

- event intake API,
- storage API,
- adapter protocol,
- renderer protocol,
- companion question API.

If the UI window crashes, reloads, or gets hidden in a future implementation,
the bridge layer should be able to keep voicemail capture running. That does not
need to be solved on day one.

## Security

The prototype is local-first.

- Bind any HTTP listener to loopback only.
- Use a random local token if exposing HTTP endpoints.
- Do not accept remote network traffic.
- Do not store API keys in plaintext if avoidable.
- Send instructions into an agent session only via supported vendor channels
  (headless resume), with explicit per-instruction confirmation and
  queue-until-idle delivery, per docs/two-way.md. Never write into agent
  session files directly.

## Packaging

The target user experience is one installable app.

- User installs one `.app`.
- User sees `Attache.app` in `/Applications`.
- User sees a normal Dock item with a Attaché app icon.
- User sees one menu bar item.
- User gets one updater.
- User does not manage a separate bridge app.

Internal helper processes are allowed later, but must stay invisible to ordinary
users.
