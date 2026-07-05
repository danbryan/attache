# MVP Build Plan

## Phase 1: Native Shell

Deliver:

- macOS app target,
- menu bar item,
- companion window,
- transparent or translucent window,
- compact Quick Actions settings surface,
- voicemail mode entered from a small unread badge and dismissed with Escape,
- quit and relaunch behavior.

Acceptance:

- The user can launch the app from Finder.
- Closing the companion window does not quit the app.
- Menu bar can reopen the companion window.

## Phase 2: Card Storage

Deliver:

- SQLite database,
- card model,
- source model,
- session model,
- local audio asset directory,
- seed or simulated card command.

Acceptance:

- A simulated event creates an unread card.
- Unread state survives app restart.
- Cards can be marked heard and archived.

## Phase 3: Voicemail Playback

Deliver:

- card detail view,
- shared play and pause transport button,
- replay and seek,
- backward and forward skip with a configurable two to thirty second interval,
- speech generation for card text,
- selectable assistant voice with the macOS system voice as the default,
- explicit on-device, ElevenLabs, and xAI voice engines with development
  provider keys stored outside the repo and no interactive Keychain prompts,
- provider voice discovery, including xAI built-in/custom voices, and short
  automatic voice previews,
- pasteable provider key fields,
- fallback caption alignment,
- caption overlay.

Acceptance:

- A card can be spoken.
- Escape exits voicemail and settings surfaces.
- Delete archives the selected voicemail card, and Clear Visible archives the
  visible voicemail list.
- Captions follow playback time during play, pause, seek, skip, and replay.
- Karaoke active-word highlighting follows the selected visual theme accent.
- Selecting a voice previews it without creating a voicemail card.
- Cloud voice engines do not silently fall back to another provider.
- Replay does not create duplicate cards.

## Phase 4: Echoform Renderer

Deliver:

- abstract visual renderer,
- idle state,
- thinking state,
- speaking state driven by playback envelope,
- unread update indicator,
- basic theme defaults.

Acceptance:

- Renderer moves during speech playback.
- Renderer changes state when cards are unread.
- Renderer remains calm and non-distracting.

## Phase 5: Codex Adapter

Deliver:

- local endpoint or hook-compatible intake for Codex events,
- local Codex session index reader,
- explicit Codex session attachment chooser,
- active-session default list,
- archived-session disclosure,
- automation-run attachment through concrete Codex session ids, not automation
  schedule ids,
- compact left-edge watch rail for watched local-agent sessions,
- unread voicemail counts on watched sessions and Command K session rows,
- fixed bottom live HUD tray that can hold the current
  karaoke caption, and attached-session history without resizing the window,
- attached-session Companion History row for prior spoken recaps in the
  currently locked Codex session,
- periodic active-session catalog refresh, roughly every five to ten seconds,
- top-center lock indicator for the attached session,
- direct watcher for the attached active Codex session transcript,
- incremental watcher polling that reads only appended JSONL after initial
  catch-up,
- normalized event conversion,
- raw payload retention,
- presentation stage that keeps raw text separate from card summary and spoken
  text,
- companion personality prompt builder that sends the provider separate system
  and user messages,
- presentation LLM settings for xAI/Grok, Ollama `qwen3:7b`, LM Studio, Groq,
  and custom OpenAI-compatible endpoints,
- editable personality prompt file for the companion's identity and working
  style,
- editable companion memory file for durable tone, routing, and preference
  context,
- card creation from Codex completion,
- project path and session id display when available.

Acceptance:

- A real or simulated Codex completion creates a voicemail card.
- The card names its source and project.
- The user can choose a recent active Codex session to attach to.
- Archived sessions stay hidden behind explicit disclosure.
- Automation definitions are not selectable watch targets.
- The app shows which Codex session is attached.
- The live surface shows watched sessions separately from voicemail.
- Selecting a watched session changes focus without removing it from the watch
  list.
- The watch rail and Command K show which sessions have unheard voicemail.
- The user can single-click a history recap to select it without playback,
  then double-click or press Play Selected to replay that recap.
- Replaying a history recap uses the same audio, Echoform visualization, and
  karaoke caption timing as normal voicemail playback.
- Showing history or captions does not cause the companion window to grow or
  push the bottom HUD offscreen.
- New active Codex sessions appear in the selectable session picker without manual
  refresh.
- A real attached Codex session response can be detected from the local session
  transcript and played live.
- Attached-session responses that arrive while playback is active are queued
  instead of interrupting the current recap.
- The watcher remains low CPU when attached to a quiet session or when the
  companion window is hidden.
- The spoken update uses the model-written presentation text when configured,
  or a bounded deterministic brief of the full response when not configured.
- The model-written presentation uses Attaché's persona, the
  selected character prompt, and bounded companion memory rather than treating
  Codex's raw response as the final spoken script.
- The user can switch the presentation LLM provider, model, base URL, reasoning
  effort, API key, and secret reference from the app.
- The user can load provider-backed model choices for xAI, Groq, Ollama,
  LM Studio, or a custom OpenAI-compatible endpoint.
- Reasoning choices are only shown when the selected model has known
  provider-backed reasoning options.
- The user can open and edit the companion personality prompt from the app.
- Playback CPU stays bounded by a low redraw cadence and by rendering only the
  current karaoke caption phrase window instead of the full raw response.
- The app does not offer native Codex send controls from companion chat.
- Expanded speech-to-text provider work remains deferred until the history HUD
  is stable; the existing typed and dictated composer remains in scope.

## Phase 6: Companion Follow-Up Questions

Deliver:

- selected-card question composer,
- live-mode question composer for the attached Codex session without requiring a
  voicemail card,
- companion-personality answer from the user's natural question plus observed Codex
  context,
- short follow-up resolution using selected-card and attached-session history so
  phrases like "what chapter is next" or "what should I do next" answer from
  context rather than producing send-status text,
- clear one-way copy: nothing is sent back to Codex.

Acceptance:

- The user can ask the companion a typed or dictated question about the attached
  session from live mode.
- The user can ask the companion about a selected voicemail/history card.
- The answer speaks to the user, not Codex.
- A short live question uses attached-session context when available and does
  not produce "got it", "sending now", or similar send narration.
- The answer can be copied or cleared.
- No follow-up is sent to Codex, silently or explicitly.

## Phase 7: Packaging

Deliver:

- app icon,
- release build instructions,
- install instructions for `/Applications/Attache.app`,
- launch smoke test.

Acceptance:

- The user can install and run the app locally.
- The README has current instructions.
- Existing Echoform and Companion repos remain untouched.
