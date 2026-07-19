# Attaché Spec

## Goal

Build a native macOS prototype of Attaché that The user can install and
try today, moving toward a single native desktop product:

- one app install,
- one menu bar/background presence,
- one optional translucent Attaché window,
- voicemail-style agent update cards,
- spoken recaps with karaoke captions,
- Echoform-style visual presence,
- optional avatar surface,
- Attaché-side follow-up questions about observed Codex updates.

This is a clean, standalone prototype.

## Non-Goals

- Do not try to preserve every existing settings screen on day one.
- Do not build a separate user-managed bridge app.
- Do not expose unsafe one-command code mutation from casual Attaché chat.
- Do not depend on system audio capture for Attaché MVP.

## Product Model

Attaché is one app with two internal roles:

1. Background role:
   - receives harness events,
   - records voicemail cards,
   - stores generated summaries and audio,
   - manages adapter state.

2. Foreground role:
   - shows Attaché window,
   - renders Echoform visuals or avatar visuals,
   - plays voicemail cards,
   - shows captions,
   - lets the user speak, type, replay, pause, or ask Attaché about an update.

In the MVP these roles can live in the same process. The architecture should
make it possible to split out an internal helper later without changing the user
experience.

## MVP User Experience

### Launch

- Double-click the app.
- It appears in the Dock as `Attaché`.
- It appears in the menu bar.
- It can open a Attaché window.
- It can keep running when the window is closed.

### Attaché Window

- Transparent or translucent native macOS window.
- Uses a normal window level by default so it can sit behind other apps.
- Must not force itself above Codex, browsers, editors, or other work windows.
- May offer an explicit always-on-top option later, but it must not be the
  default.
- Can be moved and resized.
- Can be hidden without stopping background capture.
- The primary window surface is the Echoform visualization, not a dashboard.
- Voicemail cards, playback controls, sliders, settings, and follow-up controls
  stay out of the default visual surface until the user intentionally asks for
  them.
- A compact translucent unread badge may appear in a corner when cards need
  attention. Clicking it opens the Inbox.
- Voicemail mode is a separate review surface for missed prompts and queued
  updates. Pressing Escape returns to live interaction mode.
- In the Inbox, selecting a card and pressing Delete archives it
  immediately. Clear All archives all currently visible voicemail cards without
  a confirmation step.
- Right-click or the top-right gear opens a compact custom Settings surface
  rather than a long native menu. It groups Appearance, Audio, Personality, and
  Attaché controls.
- The top-right control cluster should expose separate Settings, Voicemail, and
  Codex focus entry points. Codex session selection belongs in the Codex focus
  entry point, not inside the general settings surface.
- Settings must remain available during playback and pause. A control overlay
  must not swallow access to Visual Mode, Theme, Codex target, voice, or caption
  settings.
- The default idle view should look close to pure Echoform with only minimal
  text overlays.
- Text overlays should be reserved and readable:
  - user speech or typed input appears near the top while active,
  - assistant response or voicemail captions appear near the bottom while
    speaking,
  - overlays should sit on top of the visualization without turning the whole
    window into a sidebar-driven app.
- Provides a compact state indicator only when controls are visible or state
  needs attention:
  - idle,
  - listening,
  - thinking,
  - speaking,
  - unread updates,
  - error or permission needed.
- The bottom Live strip is for focus sessions, not voicemail. It should
  show active Codex sessions the user can watch, let them lock Attaché to one
  session, and show small unread counts without turning the window into a
  dashboard. Automation definitions are schedules, not watchable focus targets;
  when an automation is running, the watch target is the concrete Codex session
  created or resumed by that run.
- Focus-session chips must keep a stable order while the user changes focus. The
  selected session must not jump to the first slot or be duplicated as a
  special locked bottom card. When a session is locked in the top indicator,
  remove it from the bottom strip; when the user detaches it, return it to its
  stable bottom-strip position.
- The bottom strip shows at most three active session chips at once. If more
  active sessions are available, The user can page through them with visible
  chevrons, left and right arrow keys, or horizontal mouse/trackpad scrolling.
- The locked session state belongs in a smaller top-center indicator that names
  the active focus and offers detach. While a session is locked, the bottom
  focus strip should omit that same session to avoid duplicating the selected
  target.
- Attaché History is separate from Voicemail. When a Codex session is
  attached, the live surface may show a compact history row for prior spoken
  Attaché recaps from that same session. Those history items are for quickly
  re-hearing what Attaché already said while the user was actively working in
  that thread; they are not missed-message voicemail cards.
- The history row belongs in a fixed bottom HUD tray that stays inside the
  current window bounds. Showing history, captions, or playback state must not
  change the window's ideal size, grow the window, or push the important bottom
  controls offscreen.
- History interaction is intentionally low-friction: single-click selects a
  recap, double-click or Play Selected replays it with the same audio,
  Echoform analysis, transport clock, and karaoke captions as the original
  spoken update.
- Voice-input provider expansion is deferred until the history HUD is stable.
  The existing typed and dictated direct composer remains the MVP path for
  talking back to the attached Codex session.

### Renderer Modes

MVP mode: Echoform abstract renderer.

- The renderer gets reserved full-window space and should not be treated as a
  decorative background behind dense text or controls.
- Audio bars must stay inside a protected middle band. Top status, live user
  transcript, assistant captions, cards, and transport controls may overlap
  rings or glow effects, but they must not sit on top of the bars.
- The default visual style should preserve the old Echoform feel: calm,
  translucent, audio-reactive bars and rings with rich visual interest.
- The visual surface opacity is a live user setting. The user can make the window
  more translucent or more opaque without restarting the app.
- At 100% surface opacity, Attaché window should be visually opaque. Apps
  behind it should not show through the renderer or quick action surface.
- Visual motion must be driven by audio analysis, not random or decorative time
  animation. No audio should mean near-still visuals with only minimal ambient
  presence.
- Reuse the Echoform analysis model for the MVP:
  - PCM samples,
  - RMS and peak loudness,
  - FFT magnitudes,
  - log-spaced frequency bands,
  - bass, mid, treble, and spectral centroid,
  - waveform snapshot,
  - envelope-followed render signals.
- For Attaché speech, the audio source is the generated Attaché voice asset
  rather than system capture. The rendered frame at playback time should come
  from the same audio that is being played.
- Bars, pulse, heat, or flow visuals react to assistant speech audio.
- Right-click controls should expose the old Echoform customization shape:
  Visual Mode, Theme, Brightness, Intensity, Captions, Low Latency Captions,
  Spoken Language, On-device Only, Caption Sync Offset, and Surface Opacity.
- Visual Mode includes Bars, Wave Ribbon, Spectral Heat, Pulse Field, Flow
  Field, and Combined.
- Theme includes Classic, Cyberpunk, Aurora, and Ember. Karaoke active-word
  highlighting follows the active theme accent instead of always using yellow.
  Custom colors can be a later enhancement, but the menu entry should make that
  path explicit.
- Listening state reacts to mic input level if mic is enabled.
- Thinking state uses a calm deterministic animation.
- Tool-running state has a distinct but non-distracting motion.
- Error state is visible but not noisy.

Optional stretch mode: avatar renderer.

- Build any avatar rendering natively rather than depending on external assets.
- Preserve the ability to choose between abstract Echoform and avatar surfaces.

### Voicemail Cards

When a harness update arrives while the user is away or the app is not speaking:

- create a card,
- preserve source, session id, project path, raw update, short summary, and time,
- mark it unread,
- optionally pre-generate spoken recap audio,
- persist audio and caption alignment when available,
- show unread count in the menu bar and Attaché window,
- show unread count in the menu bar and as a compact in-window badge,
- let the user play or pause from one shared transport button,
- let the user replay, mark heard, delete, or send a follow-up.
- let the user seek to any point in the spoken recap from the slider before or
  during playback.
- provide backward and forward skip controls. The default skip interval is five
  seconds and can be customized to any whole-second value from two through
  thirty seconds.
- keep the card list and card detail out of the default visual surface until
  the unread badge, Quick Actions, or keyboard intent reveals the Inbox.
- card controls should adapt to small windows without overlapping status text
  or the "listening for agent updates" surface.

This is a core MVP feature.

### Attaché Presentation

Raw Codex output is not the spoken product surface. Attaché should follow
the prior Attaché bridge lifecycle:

- preserve the full raw Codex response on the card,
- pass that full response to a Attaché-owned presentation LLM when
  configured,
- build the presentation request from separate chat roles:
  - system: Attaché's durable persona, the current
    user-configurable character prompt, and relevant Attaché memory,
  - user: the observed Codex session, project, event metadata, and full raw
    Codex response,
- let the LLM produce:
  - a short `CARD_SUMMARY` for the voicemail card,
  - the spoken Attaché update used for TTS and karaoke captions,
- make the spoken update Attaché-written and personalized. It should explain
  what matters to the user, what changed, what was confirmed, what is uncertain when
  relevant, and what the user can say or do next. It must not default to reading
  Codex verbatim,
- apply the configured model, provider, and reasoning effort for this bridge
  pass. The user's prior working setup used an OpenAI-compatible xAI/Grok assistant
  with fast reasoning, and the native app must keep that provider shape
  possible without hardcoding one vendor into storage,
- support presentation providers through an OpenAI-compatible chat-completions
  adapter, starting with:
  - xAI/Grok at `https://api.x.ai/v1`,
  - Ollama local at `http://127.0.0.1:11434/v1`, default model `qwen3:7b`,
  - LM Studio local at `http://127.0.0.1:1234/v1`,
  - Groq fast inference for legacy and smoke-test compatibility,
  - a custom OpenAI-compatible endpoint,
- expose presentation provider, base URL, model, reasoning effort, API key, and
  secret reference from the app, separate from voice engine settings,
- after a provider key or local endpoint is available, query the provider for
  available models and show discovered models as choices instead of requiring a
  guessed model string,
- do not present invented reasoning choices. Reasoning choices should come from
  provider metadata or an explicitly maintained provider-specific capability
  mapping. If the app cannot determine valid reasoning levels for the selected
  model, show Default rather than a made-up dropdown,
- presentation keys must be read through the shared secret vault. Signed builds
  store secrets in macOS Keychain. Unsigned development runs may use the local
  app-support development secrets file so rebuilds do not break Keychain ACLs.
  The first signed read/write migrates fallback secrets into Keychain and removes
  the file.
  Non-secret provider settings such as provider, base URL, model, and reasoning
  effort may live in UserDefaults. Secret reads must not block event ingestion
  behind an authentication prompt; inaccessible secrets should be reported as
  unconfigured. A UserDefaults-stored secret reference is allowed only when the
  actual secret is resolved through a secure local helper such as `op-codex` and
  not stored directly in defaults,
- if no LLM provider is configured or the request fails, fall back to a
  bounded deterministic brief of the full response rather than reading the raw
  response verbatim or truncating speech to the first sentence,
- never use the card summary as the spoken text unless the summary is all that
  is available.

The character prompt is a product setting. The user may use it to make
Attaché concise, detailed, stylistic, or otherwise personalized, and that
prompt should affect both Codex-response presentation and later follow-up
message routing.

The persona prompt is also user-editable. Presets may exist for fast switching,
but they are not the only customization surface. The app must expose an editable
personality prompt file or equivalent settings editor so the user can change
Attaché's identity, tone, relationship, and working style without rebuilding
the app.

Personality edits apply to model-written presentations. If no presentation LLM
is configured, fallback cards must clearly say that the personality prompt was
not applied rather than implying Attaché ignored the user's prompt.

Attaché has its own durable memory surface. MVP memory can start as an
editable local file in app support, but the presentation prompt must treat it
as persistent Attaché preference and routing context rather than as proof
that project files, tools, or external services were checked. The memory block
should be bounded before being sent to the provider and used quietly unless the
user asks about memory directly.

### Captions

Assistant speech should display synced captions.

- Prefer real TTS word alignment when available.
- Fallback to duration-weighted word alignment when not available.
- Captions use the Attaché karaoke style: show the whole current
  caption sentence or phrase, keep upcoming words visible, and highlight the
  word currently being spoken inline.
- Long assistant responses should be rendered as a moving caption phrase window
  around the active word, not as one giant SwiftUI text run for the whole raw
  Codex output.
- Do not show the active word as a separate pill or detached label.
- Default styling should match the prior Attaché caption surface: bottom
  centered, readable white text, translucent black rounded background, and
  `#fbbf24` active-word color.
- The active word is computed from the current audio playback clock plus
  word-level alignment using the `start_ms` to `start_ms + max(duration_ms, 80)`
  timing window.
- Captions must stay in sync during pause, resume, seek, and replay.
- Seeking with the slider or skip buttons must update the active karaoke word
  from the same playback clock used by audio and visualization.
- Caption styling should support a simple readable default first.
- Assistant captions belong in the protected lower text band. The bars should
  not draw through the caption box.

### Voice And Text Input

MVP:

- Text input to the active Attaché conversation.
- Assistant speech uses a selectable voice. If no voice has been chosen, use
  the macOS system default voice.
- The right-click settings surface should expose Assistant Voice controls and a
  Voice Engine panel.
- Voice engines are explicit. The app must not silently fall back from a chosen
  cloud provider to another provider. If ElevenLabs or xAI fails, show the
  failure and let the user choose a different engine.
- Supported voice engines:
  - on-device macOS voices under a System group, including System Default and
    installed voices,
  - ElevenLabs voices discovered from the user's ElevenLabs API key,
  - xAI/Grok voices, including known built-in voice ids such as Ara and any
    team custom voices returned by xAI voice discovery.
- Provider API keys pasted or typed in the Voice Engine panel are read through
  the shared secret vault. Signed builds store secrets in macOS Keychain.
  Unsigned development runs may use the local app-support fallback file. Keys
  must never be committed to the repo.
- Selecting a voice should immediately play a short preview phrase, about five
  words, so The user can hear the voice without creating a voicemail card.
- Optional always-listening mic transcription can be enabled explicitly from the
  right-click menu.
- While voice input is enabled, show live partial user speech in the protected
  top text band, similar to VoiceInk's real-time dictation preview.
- The top transcript is for what the user is saying; the bottom karaoke caption
  is for what the assistant is saying.
- Support spoken-language selection, low-latency partial captions, and an
  on-device-only toggle for mic recognition.
- AI can infer from context, but the UI should make transcription uncertainty
  visible enough that The user can correct it.

Stretch:

- Mic bars during speech.
- Wake phrase or global shortcut.
- Translation and translate-to language selection.

### Harness Support

MVP target:

- Codex bridge adapter.
- Codex session attachment chooser:
  - list active Codex sessions by default,
  - hide archived sessions behind an explicit Archived Sessions submenu or
    "show more" style disclosure,
  - show whether a listed session is active or archived,
  - do not show automation definitions as selectable watch targets,
  - if a saved automation id matches an active session run by name, migrate the
    attachment to that active session id,
  - let the user attach or detach Attaché from one Codex session,
  - show a compact top-center indicator for the attached session when controls
    are visible,
  - show active watched targets as stable focus-session chips in Live,
  - do not duplicate the attached session in the bottom focus-session strip
    while it is already shown in the top lock indicator,
  - show no more than three bottom focus-session chips at once and page through
    additional active sessions with chevrons, arrow keys, or horizontal scroll,
  - refresh the active-session list periodically, roughly every five to ten
    seconds, so newly created Codex sessions appear without manual refresh,
  - use the attached session as the default target for simulated Codex events
    and Attaché follow-up context,
  - when a matching active attached session emits a Codex update, treat it as a
    live interactive response that can be spoken immediately rather than an
    unread voicemail card,
  - if matching live updates arrive while another recap is already speaking or
    paused, queue them and play the next attached update only after the current
    recap finishes,
  - when a non-attached session emits a Codex update, treat it as background
    work and create an unread voicemail card,
  - send an instruction back into an agent session only through the two-way
    channel rules below, never through any other side channel.

Claude Code is already supported via its session-transcript watcher (the same
mechanism as Codex). Stretch targets (alternative delivery mechanisms):

- Claude Code hooks adapter.
- Attaché MCP server surface.
- Generic local webhook or CLI adapter.

Harness adapters are observation-first and must declare capture capabilities:

- observe updates,
- create voicemail cards,
- optionally deliver confirmed instructions (see docs/two-way.md).

Send controls exist only where the two-way channel design applies: delivery uses
supported vendor channels (headless resume), requires explicit per-instruction
confirmation, waits for the target session to be idle, and is logged. Writing
turns directly into agent session files is rejected and must not be
reintroduced.

## Data Model

Use SQLite for local state.

Suggested tables:

- `sources`
  - id
  - kind: codex, claude_code, mcp, generic
  - display_name
  - enabled
  - config_json

- `sessions`
  - id
  - source_id
  - external_session_id
  - project_path
  - title
  - last_seen_at

- `cards`
  - id
  - source_id
  - session_id
  - kind: update, error, approval, reminder
  - raw_text
  - summary
  - spoken_text
  - status: unread, heard, archived, failed
  - created_at
  - heard_at
  - metadata_json

- `audio_assets`
  - id
  - card_id
  - file_path
  - duration_ms
  - alignment_json
  - voice_provider
  - voice_id
  - created_at

- `settings`
  - key
  - value_json

## Local API

For MVP, expose a local endpoint for adapters:

- `POST /events`
  - receive normalized events from harness adapters.

- `GET /cards`
  - list voicemail cards.

- `POST /cards/{id}/play`
  - play or prepare a card.

- `POST /cards/{id}/mark-heard`
  - mark as heard.

Codex session attachment is local app state in the MVP. The app may read
`~/.codex/session_index.jsonl` directly to populate the chooser. Attachment is
used for observation, live playback, history, and Attaché-side questions, not
for sending messages into Codex.

For attached active sessions, the MVP should also observe the local Codex
session transcript file under `~/.codex/sessions`. If the loopback bridge does
not emit a normalized event, Attaché should still detect the latest final
assistant response for the attached session and play it as live interaction.
This direct watcher is for the attached active session first. Automation and
non-attached session capture should come through the local event bridge or a
separate background adapter. The chooser should still attach to concrete Codex
session ids; automation ids only describe schedules.

The direct watcher must be low overhead. It must not parse the full transcript
on every poll. After initial catch-up it should keep a file offset and parse
only appended complete JSONL records, preserving partial-line fragments until
the next poll. A hidden or background-only app should remain near idle CPU when
no Codex output is being appended.

Playback should also stay lightweight. The renderer and playback clock should
run at a bounded cadence, and karaoke caption layout must avoid recomputing the
entire raw Codex response every frame.

This API can be in-process and only bound to loopback for the prototype.

## Normalized Event Schema

```json
{
  "source": "codex",
  "event_type": "assistant.completed",
  "external_session_id": "optional-session-id",
  "project_path": "/path/to/project",
  "title": "Short human title",
  "text": "Raw completion or update text",
  "metadata": {
    "turn_id": "optional-turn-id",
    "cwd": "/path/to/project"
  }
}
```

## Adapter Rules

Adapters are not trusted to mutate code from Attaché chat. Observation and
delivery are separate capabilities: harnesses send observed updates to
Attaché, and Attaché may deliver an instruction back to a session only
under the two-way rules (design of record: docs/two-way.md):

- Delivery uses a supported vendor channel only (headless resume:
  `claude -p --resume`, `codex exec resume`). Writing turns directly into agent
  session files is rejected.
- Every instruction requires explicit per-instruction user confirmation before
  delivery. Nothing is ever auto-sent.
- Delivery waits until the target session is idle (queue-until-idle); at most
  one delivery is in flight per session.
- Attaché must never deliver an agent-side permission or tool approval
  (bare "yes"/"approve"/"allow" style payloads are refused).
- Every delivery is recorded in a persisted instruction log with its outcome,
  and the agent's subsequent response is narrated and linked to it.
- Two-way is off by default and enabled per session.
- Card follow-up and live attached-session follow-up remain Attaché-side
  question flows. They use the selected card, raw Codex output, Attaché spoken
  recap, character prompt, bounded Attaché memory, and recent attached-session
  history as context; answering Dan and sending to the agent are distinct,
  clearly labeled actions.
- Short or elliptical follow-ups such as "next chapter", "same thing", "what
  changed", or "what should I do next" should be answered from the observed
  session context when possible. If acting on it would require the agent to take
  an action, Attaché may offer the send flow, which still requires
  explicit confirmation; it must never claim to have sent something it did not.
- Attaché answer can be copied or cleared. A send control, where present,
  goes through the confirmed two-way flow above.
- Dan can ask about the focused session from Live without selecting
  or creating a voicemail card first. That composer accepts typed text and can
  copy the current voice transcript into the question input.
- If context is unknown, Attaché says what is missing instead of sending
  or inventing a target.
- Store raw adapter payloads for debugging.
- Store normalized payloads for UI and summaries.

## Behavior Contracts

Preserve these behaviors:

- visual modes and state model,
- caption settings and low-latency caption tradeoffs,
- bridge card lifecycle,
- TTS audio payload and word alignment,
- replay card handling,
- the Talk vs Codex safety boundary.

## MVP Acceptance Criteria

The first day-project prototype is acceptable when:

- The repo builds a macOS app.
- The app launches from Finder.
- The app can run with no Attaché window visible.
- The app can open a translucent Attaché window.
- The app can receive a simulated Codex event through a local endpoint or test
  command.
- The event becomes an unread voicemail card.
- The card can be played or paused with one shared transport button.
- The card can be replayed.
- The spoken text is visible with synced or fallback karaoke captions.
- The playback slider can seek within the spoken recap and captions remain
  synced after the seek.
- Backward and forward skip controls work with a configurable two to thirty
  second interval.
- Echoform theme and visual mode choices can be changed from the context menu
  while playback is active or paused.
- Attaché can attach to a recent active local Codex session and show the
  attached-target indicator.
- The attached-session watcher does not repeatedly reparse the whole Codex
  transcript and remains low CPU while idle in the background.
- Attached-session spoken updates use model-written presentation text when a
  provider is configured. Without a configured provider, they use a bounded
  deterministic brief of the full Codex response, not raw verbatim output and
  not only the first sentence of the card summary.
- Presentation LLM settings support xAI/Grok, Ollama `qwen3:7b`, LM Studio,
  Groq, and custom OpenAI-compatible endpoints from the app UI.
- Archived sessions are hidden behind an explicit archived-session disclosure.
- Automation definitions are not listed as selectable watch targets.
- The Echoform-style renderer reacts during playback.
- Heard and unread states persist across app restart.
- Escape closes voice settings and the Inbox consistently.
- Voice selection supports on-device, ElevenLabs, and xAI engines, and selecting
  a voice plays a short preview without changing card state.

## Open Design Questions

- Should the MVP use a local loopback HTTP server, Unix domain socket, or only
  app-internal test commands?
- Should the first Codex adapter read existing hooks, expose a new local webhook,
  or both?
- How much of the avatar surface should ship in the MVP versus be deferred?
- Should start-at-login ship in the first prototype or wait until after basic
  voicemail reliability is verified?

## Suggested Build Order

1. Create native macOS app shell with menu bar and Attaché window.
2. Add SQLite card storage.
3. Add simulated event intake.
4. Add voicemail card list.
5. Add speech playback and caption timing.
6. Add Echoform visual renderer during playback.
7. Add Codex adapter.
8. Add Attaché-side follow-up questions for selected cards and attached sessions.
9. Add settings for renderer, voice, and model providers.
10. Add app packaging and install instructions.
