# AGENTS.md

This is the source of truth for both Codex (`AGENTS.md`) and Claude Code, which
reads it through a `CLAUDE.md` symlink in this directory. Edit this file, not the
symlink.

## Scope

Attaché is a standalone Swift package (pure SwiftPM, no `.xcodeproj`). Its only
external dependency is Sparkle (in-app updates); it depends on no other local
repositories. It has shipped publicly; see Status.

## Status

Attaché has shipped publicly. The current release is `v0.4.0`.

- `origin` is the public repo `github.com/danbryan/attache`; releases and the
  Homebrew cask (`danbryan/tap`) live there. `archive`
  (`github.com/bryanlabs/attache`) is the frozen private development history.
- The public site is `attache.fm` (Homebrew one-liner, DMG download, and the
  Sparkle appcast). See Landing Page.
- Users update three ways, all kept in lockstep by a single release: re-download,
  `brew upgrade`, or in-app Check for Updates (Sparkle). See Updates.
- Keep `swift build && swift test` and `scripts/ui-smoke.sh` green before cutting
  a release. Release work commits to `main` directly (see Release And
  Distribution); day-to-day feature work can still branch per change.
- Launch tracking lived under Linear umbrella INF-174 (project "Attaché Launch
  Readiness").

## Product Direction

Build one user-facing macOS app, not two user-managed apps.

The app runs in the background like a menu bar utility and optionally shows a
translucent Attaché window. The background bridge and the visible Attaché surface
may be separate internal modules or helper processes later, but the app starts as
one app process.

## Priority

1. Preserve voicemail-style agent update cards.
2. Preserve spoken recaps with replay.
3. Preserve karaoke captions.
4. Add Echoform-style abstract visual presence.
5. Keep reverse-send behavior safe and explicit.
6. Keep the app installable and easy to run on a developer Mac.

## Architecture Map

- `Sources/AttacheCore`: testable logic. Transcript parsing, narration
  coalescing, pipeline ordering and dedup, the card store, the instruction and
  two-way reply engine, diagnostics.
- `Sources/AttacheApp`: the SwiftUI/AppKit app. Session watchers, the local event
  server, speech playback, two-way delivery adapters and coordinator, views.
- `docs/two-way.md`: two-way channel design of record.
- MCP tools (INF-373): config, permission policy, and namespacing are pure
  Core (`MCPServerConfig`, `MCPConfigEditor`, `MCPToolPolicy`,
  `MCPToolDescriptor`, `MCPToolPermission`); the client, registry, and
  per-call coordinator are App (`MCPClient`, `MCPServerRegistry`,
  `MCPToolCall`). UI surfaces are the Settings "MCP Servers" pane, the
  personality editor's Tools picker, and the ask-first approval sheet.
  Harness import (INF-376) adds read-only detection of servers configured in
  other tools (`MCPHarnessImport` + `MinimalTOML` in Core, `MCPHarnessProber`
  in App) and a per-server Test button. See `docs/mcp-tools.md`.
- `Sources/AttacheApp/Personality.swift`: a personality is one first-class unit
  that owns its brain (`prompt`), voice (`PersonalityVoiceRef`), visual presence
  (`visualMode` plus `AttacheCharacter`), and explicit preferred main model
  (`PersonalityModelRef`). `PersonalityStore` persists the set, migrates a
  pre-unification user's separate voice/character onto their active personality, and
  imports/exports JSON. Its ordered live-call fallback providers and playback
  speed travel with the personality; advanced per-task overrides remain
  app-wide policy. `AttachePersonality.anotherTakePrompt` (Core) is the pure
  "another take" re-narration engine. See Decisions of Record.
- New logic that can be unit-tested belongs in `AttacheCore`.

## Build Rules

- Prefer native macOS APIs.
- Use SwiftUI for ordinary UI.
- Use AppKit where window behavior requires it.
- Use SQLite for persistent local app state.
- Keep source adapters isolated from UI rendering.
- Keep renderer adapters isolated from event storage.
- Add tests where storage, event normalization, and caption timing can regress.

## Build And Test

```bash
swift build
swift test
```

- The full test suite must pass before any merge to `main`.
- Test packaging: `SIGN_APP=0 scripts/package-app.sh` produces an unsigned
  `dist/Attache.app` for local UI work.
- `dist/` may hold the signed and notarized release candidate. Test packaging
  overwrites it; rebuild the candidate afterward with the release command in
  Release And Distribution.

## Testing Affordances

- `ATTACHE_COMPACT_VOICES_ONLY=1` hides premium and enhanced voices from the
  app's catalog to preview the compact-only onboarding experience without
  deleting installed voices.
- `ATTACHE_UI_TEST=1` makes the app skip the notification permission request so
  automation is not interrupted by the OS prompt. Use
  `launchctl setenv ATTACHE_UI_TEST 1` when launching via `open`, and unset it
  afterward.
- `scripts/send-event.sh` posts a demo event to the local event server. The
  server requires the per-launch bearer token written to
  `~/Library/Application Support/Attache/event-token` (mode 0600).
- `scripts/simulate-fresh-user.sh fresh` backs up and clears local app state;
  `restore` puts it back. Always pair them, and never run `restore` twice in a
  row: a double restore clobbers the backup with current state.
- `ATTACHE_FORCE_PLAIN_READBACK=1` skips LLM presentation and speaks events
  verbatim. `scripts/codex-personality-two-way-smoke.sh` sets it so success
  depends on Codex's watched answer, not a presentation-model paraphrase.
  Reply correlation itself is positional (INF-245/B2), not exact-text, so
  `scripts/codex-two-way-smoke.sh` (the f7 gate) leaves presentation at its
  default rather than forcing plain readback.
- `ATTACHE_DISABLE_TOPIC_TAGGING=1` turns off background topic tagging; most
  smoke scripts set it to keep runs deterministic and avoid stray LLM calls.
- `scripts/codex-personality-routing-canary.sh` proves that legacy Codex
  personality settings fail before compilation, subprocess launch, or app-tool
  execution. Codex remains available as an agent source and reverse-send target.
- `SMOKE_POSE=inbox|settings|live` (comma-separated, applied in order) poses the
  packaged app for screenshots via the smoke harness; `SMOKE_TEXTSCALE` sets
  text size and `SMOKE_POSE_SECONDS` the hold time.
- `ATTACHE_ACTIVITY_SIMULATOR=1` shows a debug panel that overrides
  `AttacheActivityState` (INF-268): pick any phase/agent/tool kind or cycle
  through all phases, with a readout of what `attacheActivity` actually
  publishes. Drives every renderer that consumes the contract.
- `Attache --render-character-poses [dir]` exports the Attaché character pose catalog
  (`design/attache-animation-spec.md`) as PNGs and fails if the rig's neutral
  pose deviates by even one pixel channel from `AttacheMascotMark` (the
  geometry lock, INF-269). `--render-brand-poses [dir]` is the marketing
  variant (2048 px set plus the idle hero loop frames, INF-274).
- `ATTACHE_CHARACTER_RARE_IDLE_SECONDS=<n>` shrinks the character's rare-idle cadence
  (INF-273, normally minutes) so reels and QA runs can catch one quickly.
  `attache.characterShinySeed` set to 0 via defaults forces the shiny variant.
- `ATTACHE_TWO_WAY_EXPIRY_SECONDS=<n>` overrides the two-way instruction expiry
  window (docs/two-way.md's 30-minute default) to `<n>` seconds, so
  `scripts/two-way-negative-path-smoke.sh` can drive a real expiry against the
  packaged app in seconds. Inert unless `ATTACHE_UI_TEST=1` is ALSO set (the
  harness always sets it), so this can never shrink a real user's window by
  itself; see `InstructionReplyEngine.expiryWindow(fromEnvironment:)` and its
  tests for the explicit non-bypass proof (INF-256/E4).
- `CLAUDE_CONFIG_DIR=<dir>` is the real Claude Code CLI's own override for
  `~/.claude` (verified against the real CLI on this machine, INF-257/E2), the
  Claude analog of `CODEX_HOME`. `ClaudePaths.home()` is the one place
  Attaché resolves it, and `ClaudeCodeSessionScanner`, `CodexSessionWatcher`,
  `SessionActivityWatcher`, and `AttacheSessionReader.sessionFileURL` all
  read Claude Code session state through it, so a disposable
  `CLAUDE_CONFIG_DIR` set on the app's own environment is honored end to end:
  session discovery, the live watcher, and the two-way delivery adapter's
  readiness/transcript lookup all agree with whatever `claude` itself is
  using. `scripts/claude-two-way-smoke.sh` (the f21 gate) sets it to a
  disposable directory holding only an extracted `claudeAiOauth` credential,
  never the real `~/.claude`.
- `ATTACHE_FAKE_PREMIUM_VOICE=1` makes the `.attachePremium` synthesize path
  write a deterministic ~1.5s tone WAV (nonzero energy, correct header via the
  E1 wav writer) instead of dlopen'ing the runtime, loading the model, or
  reading weights, and makes `AttachePremiumVoiceAvailability.isReady()` report
  ready, so UI flows can drive premium-voice playback with no runtime or weights
  present. Inert unless `ATTACHE_UI_TEST=1` is ALSO set, so it can never fake
  audio for a real user; the gate is the pure `PremiumVoiceFakeGate.isActive`
  with the same non-bypass proof as `expiryWindow(fromEnvironment:)` (INF-385/E5;
  see `PremiumVoiceFakeGateTests`).
- `ATTACHE_PREMIUM_VOICE_TEST_WEIGHTS=<dir>` points the real premium-voice
  integration test and `scripts/premium-voice-smoke.sh` at a weights directory
  holding `models/` and `voices/` (defaulting to the E1 integration test's
  convention). Absent it, the guarded test skips cleanly.
- `scripts/mock-mcp-server.py` is a dependency-free stdio MCP server (a
  read-only `echo` tool and an effectful `write_note` tool) for exercising the
  MCP client, registry, and permission surfaces locally without a real server;
  point an `mcp.json` stdio entry at it.

## Safety Rules

- Do not silently send messages into Codex, Claude Code, or any other harness.
- A reverse-send action must identify the target source and session.
- If a harness cannot guarantee reverse-send support, create a draft or show a
  blocked state instead.
- Do not put API keys or tokens in the repo.
- Do not weaken the local event server hardening (per-launch token, connection
  caps, request size limits) or on-disk file permissions to make testing easier.
- Screen capture in any automation must be window-scoped: resolve the app's
  CGWindowID and pass it to `screencapture -l`, as
  `scripts/call-phase-screenshot-matrix.sh` does. Never full-screen or
  display-level capture; it can grab unrelated windows containing personal
  data (2026-07-10 incident).
- Never point automation at the real user profile except through
  `scripts/simulate-fresh-user.sh`'s fresh/restore backup pairing.
  `restore()` hard-fails, leaving the live profile untouched, if the target
  backup has no `Attache` folder to restore, and `fresh`/`restore` take a
  process lock so concurrent invocations hard-fail instead of racing
  (2026-07-10 incident: a stray kill mid-capture left the live profile
  cleared until the backup was recovered; 2026-07-17 incident: two
  overlapping `ui-smoke.sh` runs raced `restore()`, which deleted the live
  profile unconditionally before checking whether the backup had anything to
  restore, wiping the real profile until it was recovered from a Time
  Machine snapshot). `scripts/simulate-fresh-user-restore-guard-smoke.sh`
  proves both guards against a throwaway directory. `ui-smoke.sh` runs are
  single-flight: run them yourself as the orchestrating agent, never
  delegate one to a subagent, and never run two at once.

## Git And Commits

- Commits must be GPG-signed. Signing is pre-warmed on this machine. If a commit
  fails to sign, stop and ask Dan to unlock the login keychain and 1Password.
  Never disable signing or work around it.
- Commit messages are concise: what changed and why. No metadata sections, no
  co-authored-by lines, no em dashes.
- Never commit secrets, tokens, or key material.

## Release And Distribution

Attaché ships publicly; releases go out. The primary artifact is the notarized
**DMG** (`Attache.dmg`) that `install.sh`, the Homebrew cask, and the Sparkle
appcast all point at. The zip + `SHA256SUMS` are secondary release assets.

Facts:

- Public app name `Attaché`, SwiftPM product `Attache`, bundle id
  `com.bryanlabs.attache`.
- Signing identity `Developer ID Application: Bryanlabs LLC (VS4G53Q3JB)` in the
  login keychain. Notary keychain profile `bryanlabs-notary`. The notary
  app-specific password lives in 1Password and loads through the profile; never
  print or commit it.
- `CFBundleShortVersionString` is the marketing version (e.g. `0.1.3`).
  `CFBundleVersion` MUST increase every release; `package-app.sh` sets it to a
  unix-timestamp `BUILD_NUMBER`. Sparkle compares `CFBundleVersion`, so a
  non-increasing value silently breaks in-app updates. See Updates.

Full pipeline for a release (replace `X.Y.Z`):

1. Bump `APP_VERSION` in `scripts/package-app.sh` and the `VERSION` default in
   `scripts/create-github-release.sh`. Add `docs/releases/vX.Y.Z.md` notes.
   Commit (clean tree, GPG-signed) and `git push origin main`.
2. Build + sign + notarize the app:
   ```bash
   scripts/build-premium-voice-runtime.sh   # once per machine/update; stages the voice dylibs
   VERSION=X.Y.Z NOTARIZE_APP=1 NOTARY_PROFILE=bryanlabs-notary EMBED_PREMIUM_VOICE=1 scripts/package-app.sh
   ```
   Produces `dist/Attache.app` (stapled), `dist/Attache.zip`, `dist/SHA256SUMS`.
   `EMBED_PREMIUM_VOICE=1` is REQUIRED for release builds (INF-379): it embeds
   and signs the Attaché Premium voice dylibs; without it the shipped app has
   no premium voice and Azelma falls back to the system voice.
3. Wrap + notarize the DMG (prints its sha256, needed for the cask):
   ```bash
   NOTARY_PROFILE=bryanlabs-notary SRC_APP=dist/Attache.app scripts/make-dmg.sh
   ```
4. Create the GitHub release (tags `vX.Y.Z`, pushes the tag, uploads zip +
   checksums), then upload the DMG separately (the script does NOT):
   ```bash
   VERSION=X.Y.Z scripts/create-github-release.sh
   gh release upload vX.Y.Z dist/Attache.dmg
   ```
   `create-github-release.sh` fails closed if the app is unsigned, unstapled,
   not Gatekeeper-accepted, unchecksummed, or the worktree is dirty. GitHub marks
   the newest release `Latest`, so `releases/latest/download/Attache.dmg` (what
   `install.sh` uses) resolves automatically.
5. Regenerate + publish the Sparkle appcast. See Updates.
6. Bump the Homebrew cask (`danbryan/homebrew-tap` -> `Casks/attache.rb`): set
   `version` and `sha256` (the DMG's), commit, push. Sanity check: the released
   DMG's sha256 must equal the cask's.

Verify a candidate before publishing:

```bash
codesign --verify --strict --verbose=2 dist/Attache.app
xcrun stapler validate dist/Attache.app
spctl --assess --type execute --verbose=4 dist/Attache.app   # accepted, source=Notarized Developer ID
```

Apple reference: notarizing macOS software
<https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>.

## Updates (Sparkle)

Decision: use Sparkle 2.x for in-app auto-updates IN ADDITION to Homebrew and
re-download, so a user who installed by DMG is not stranded. One release feeds
all three paths.

- Feed `SUFeedURL` = `https://attache.fm/appcast.xml`; the public key
  `SUPublicEDKey` and `SUEnableAutomaticChecks` are in the Info.plist written by
  `package-app.sh`. `Sparkle.framework` is embedded and re-signed inside-out in
  `package-app.sh` (XPC services, Autoupdate, Updater.app, then the framework) so
  the whole bundle notarizes.
- The appcast is generated + EdDSA-signed by Sparkle's `generate_appcast`
  (`.build/artifacts/sparkle/Sparkle/bin/generate_appcast`). The private key is
  in the login keychain; the first run per machine raises a one-time "Always
  Allow" keychain prompt that needs a human click (do not bypass it). Regenerate:
  ```bash
  mkdir -p /tmp/ac && cp dist/Attache.dmg /tmp/ac/
  .build/artifacts/sparkle/Sparkle/bin/generate_appcast \
    --download-url-prefix "https://github.com/danbryan/attache/releases/download/vX.Y.Z/" \
    --link "https://attache.fm" /tmp/ac/
  ```
  Then copy `/tmp/ac/appcast.xml` into the bare-metal `attache` app dir and
  publish it via the ConfigMap step in Landing Page.
- `CFBundleVersion` must strictly increase (see Release And Distribution); it is
  what Sparkle compares between the installed app and the appcast. In-app, the
  menu-bar dropdown shows the version and a Check for Updates item; the app menu
  adds About.

## Landing Page (attache.fm)

The marketing site, install one-liner, and Sparkle appcast are NOT in this repo.
They live in `bryanlabs/bare-metal` at `cluster/apps/attache/`: `index.html`,
`install.sh`, `appcast.xml`, `favicon.png`, `apple-touch-icon.png`, plus
`deployment.yaml` / `service.yaml` / `namespace.yaml`.

- Served by nginx from a ConfigMap `attache-site` in the `attache` namespace.
  The NodePort, pfSense HAProxy backend, and Route 53 records that expose it are
  documented in the bare-metal repo's `cluster/apps/attache/README.md` (kept in
  that private repo, not here, since this one is public). `attache.bryanlabs.net`
  was retired 2026-07-05; `attache.fm` is the only public name.
- To update the site OR the appcast, recreate the ConfigMap with ALL FIVE files
  and roll out. The repo README's single-file `--from-file=index.html` example
  WILL drop the others (appcast, installer, favicons) and break the site:
  ```bash
  cd .../bare-metal/cluster/apps/attache
  kubectl create configmap attache-site -n attache \
    --from-file=index.html --from-file=appcast.xml --from-file=install.sh \
    --from-file=favicon.png --from-file=apple-touch-icon.png \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl rollout restart deploy/attache-web -n attache
  ```
- `install.sh` downloads `releases/latest/download/Attache.dmg`, mounts it to a
  KNOWN path (`-mountpoint`, never parsing `hdiutil` output), removes any old
  `/Applications/Attache.app`, copies the new one, and `open`s it.

## Decisions of Record

- **No "companion" in user-facing text.** Current code uses Attaché naming.
  Frozen metadata, environment variables, preference keys, and migration paths
  may retain older strings solely so existing users and stored cards keep
  working. Never surface those compatibility strings to users.
- **Tagline: "Give your agents a voice."** (2026-07-11). Retires "Fluent in
  agent. Speaks human." and the older "Your AI agents, out loud" everywhere
  (README, brand, site, video).
- **The brand is Attaché the robot** (2026-07-13, INF-291): the robot head
  broadcasting under three voice arcs.
  Sources of truth: `AttacheMascotMark` (in-app mark/idle/menu bar),
  `AttacheAppIcon` plus `scripts/generate-app-icon.swift` (icon, kept
  identical), `Volt2`/`Mark2` in `video/src/epic` (promo). The default character
  is the robot, named **Attaché** in the picker; **Colt** the cowboy is the only
  other character. Older limb-and-agent-glyph artwork is fully retired. The
  outer voice arc still crests above the 240-unit design box; every renderer
  pads to 252 or it clips.
- **Built-in themes are exactly four:** macOS (default AND first in the list),
  High Contrast, Paper, Cyberpunk. Brass / classic / ember / ocean / slate-mono /
  violet-dusk were removed. Users can still author custom themes.
- **The built-in personalities are exactly Attaché, Colt, and Echo.** Attaché uses
  the domain-agnostic big-picture temperament and the robot presence. Colt uses
  the weathered cowboy temperament and cowboy presence. Echo is voice-only and
  keeps the original visual bars in a compact character-sized presence;
  double-click expands the visualizer. All three default to the Attaché Premium
  voice (Azelma, INF-379), falling back to the system voice until the weights
  are installed. No other built-in personality is shown.
- **The user-facing noun is "Attaché" / "your Attaché" (2026-07-18, INF-389).**
  A single unit in the picker is an Attaché ("New Attaché", "Create your Attaché",
  "Save changes"); "personality" / "personalities" stays acceptable vocabulary
  and is the generic noun where a count is needed (the grid is "Your
  personalities"). Both "character" and "wardrobe" are retired from user-VISIBLE
  text (labels, titles, menu items, tooltips, confirmations, AX labels heard via
  VoiceOver). Internal identifiers may keep their names: the `AttacheCharacter`
  type, the `character`/`visualMode` properties, the `attache.openCharacterSwitcher`
  notification, the "Character Studio" AX identifier, `--render-character-poses`,
  `ATTACHE_CHARACTER_RARE_IDLE_SECONDS`, and personality prompts (which may tell
  the model to "stay in character") are all unchanged.
- **A personality is one unit: brain, voice, presence, and model**
  (2026-07-14, INF-293..302, "Personality Manager"). `Personality` owns a
  `voiceRef` (engine + voice), a visual presence, and an explicit `modelRef`
  including model-specific reasoning effort, ordered live-call fallbacks, and
  playback speed. Legacy personalities with any field missing are filled from
  the user's current configuration on load.
  Switching applies the unit together. The original Voice Bars visual is a
  first-class no-character presence. The preferred model replaces the app's main
  model; Advanced per-task overrides still win for their role, and the
  personality's ordered live-call fallback list starts after its preferred
  provider fails.
  Ordinary personality switches animate the presence without speaking; greetings
  are explicit previews in the creator. Off-call audio may only begin from an
  explicit Play, Preview, or catch-up action. **"Another take"** lets any
  voicemail card or live turn be re-narrated by a different personality that
  briefly reacts to the prior take then gives its own spin, in its own voice and
  character. Another-take is narration only: it never triggers a reverse-send and never
  touches the frozen agent destinations.
- **Private Call means no Attaché conversation record.** A private call keeps
  recent turns and rolling continuity only in memory, writes no history cards or
  direct-chat capsules, offers no memory proposal, rename, or agent-send effects,
  and clears the temporary state at hangup. It is a local app-storage guarantee,
  not a cloud-provider retention guarantee. Saved calls carry a conversation id
  so History can permanently delete every linked reply and alternate take.
- **Model utilization stays evidence-bound.** An unchanged Ollama digest may
  retain stale last-known capability while offline; mutable or unfingerprinted
  model identities fall back to the unknown-capacity envelope after staleness.
  Provider-reported token usage may reduce conservative estimates only after
  twenty consistent samples, with a 25 percent maximum reduction. It never
  changes Custom policy, unknown-capacity plans, or provider hard limits.
- **Recap length is dynamic.** The recap prompt scales a sentence ceiling by item
  count, clusters related items, compresses solved problems to their outcome, and
  preserves decisions.
- **Never emit em dashes in spoken output.** Personalities are instructed to
  avoid them AND `AttachePersonality.stripDashes` removes them deterministically
  on the spoken path, because the model ignores the instruction often enough to
  matter.
- **No hidden phrase routing for agent sends.** Live conversation has explicit
  destinations: Ask Attaché goes to the personality, Tell Agent sends the raw turn
  through the two-way send-to-agent pipeline. Do not infer destination with
  English phrase matching before the personality sees the turn. That approach is
  brittle across languages and unsafe on false positives; personality-driven
  delegation remains available through `stage_agent_instruction`.
- **No implicit work-session context.** A direct Ask Attaché conversation may
  read only the session the user explicitly focused. Recency, watched sessions,
  a selected voicemail, prior call turns, and the local session index are not
  authorization to inject a title, transcript, working directory, file, or
  tool. With no focused session the character can still chat, but the request
  is context-free apart from the character prompt and explicit durable memory;
  session-reading, rename, and agent-send tools are absent. Hang-up starts a
  new context boundary, so the next call never inherits the prior call's turns.
- **Agent destinations are frozen and explicit.** Agent sends require a focused
  session. A live call freezes that session's ID, source, title, and working
  directory for tool calls, confirmation, and delivery until hang-up. Tell Agent
  applies to one turn and then resets to Ask Attaché before listening resumes.
  Freeze the structured instruction payload separately and fail closed if it or
  the stored target differs before delivery.

## Gotchas

- **Never use `Bundle.module`.** Its generated accessor calls `fatalError` when
  it cannot resolve the SwiftPM resource bundle. This app is hand-packaged and
  its nested `Attache_AttacheApp.bundle` is not independently code-signed, so on a
  fresh quarantined install (macOS 26) the lookup fails and crashes the app. It
  shipped as a ⌘K crash in 0.1.1. Load bundled resources via `Bundle.main` or an
  explicit path with a graceful fallback; `Sources/AttacheApp/Views/SourceBadge.swift`
  is the reference. Localized `Text` / `NSLocalizedString` are safe because
  `package-app.sh` promotes the `.lproj`s into `Contents/Resources` (Bundle.main).
- **`CFBundleVersion` must stay monotonic** or Sparkle updates silently stop.
- **`install.sh` mounts to a known `-mountpoint`,** never grepping `hdiutil`
  output; a `-quiet` race once left the DMG mounted and the install half-failed.

## Verification

Test-time discipline (2026-07-17, after a suite deadlocked silently for ~50
minutes against a stale concurrent xctest):

- Run the suite through `scripts/test.sh`, which enforces a wall-clock cap
  (`ATTACHE_TEST_TIMEOUT`, default 900s; a warm run is ~60s) and refuses to
  start while another AttachePackageTests run is active. Suites are
  single-flight per machine. If the cap fires, investigate the hang; do not
  just raise the cap.
- Every wait a test performs must be bounded and must FAIL on expiry, sized
  at roughly 1.5-2x the operation's normal cost: `semaphore.wait(timeout:)`,
  `XCTWaiter` timeouts, subprocess deadlines. Never an unbounded
  `semaphore.wait()` or an await with no cancellation path. The `runAsync`
  helper in HistoricSessionSummarizerTests is the reference.
- A test that talks to a subprocess or socket owns its cleanup: kill the
  child in `defer`/`tearDown` so a failure cannot strand a process that
  wedges the next run.

Before claiming a change works, verify:

- `swift build && swift test` pass,
- `scripts/ui-smoke.sh` passes.
- Before a release candidate, run `scripts/release-readiness-smoke.sh` as the
  eleven-gate pre-release suite. Set `ATTACHE_RELEASE_READINESS_WITH_CODEX=1`
  when the candidate also needs the real Codex f7/f8 round trips in the same
  run, and `ATTACHE_RELEASE_READINESS_WITH_CLAUDE=1` when it also needs the
  real Claude Code f21 round trip (`scripts/claude-two-way-smoke.sh`,
  INF-257/E2), and `ATTACHE_RELEASE_READINESS_WITH_PREMIUM_VOICE=1` when it also
  needs the real Attaché Premium voice synthesis gate
  (`scripts/premium-voice-smoke.sh`, INF-385/E5); all three are opt-in and
  independent of each other.

The UI smoke harness (INF-156) is the standard UI verification step. It builds
and packages an unsigned app, switches to a fresh-user profile (backing up real
state and restoring it afterward), launches the app headed, and drives flows
through the accessibility API via the `AttacheUISmoke` target:

1. launch reaches the idle dock,
2. a demo event posts through the token-guarded server, shows as an unread card,
   and plays on demand,
3. pause, seek, and resume work and captions stay visible,
4. Command-K opens, search filters to a match, Escape closes, and reopening puts
   the cursor back in search with no focus fallback,
5. Command-comma opens the in-window Settings overlay (there is no separate
   Settings window); theme, voice engine, and text size changes persist across a
   relaunch and are restored to what the user had, and Escape closes the overlay,
6. the ⌘I inbox and ⌘Y history palettes open, filter as you type, and close on
   Escape.

Under `ATTACHE_UI_TEST=1` the secret vault never touches the real keychain, so
smoke runs cannot churn keychain ACLs or hang on authorization dialogs.

Harness notes:

- The process running the harness needs a one-time Accessibility grant (System
  Settings > Privacy & Security > Accessibility).
- Iterate with `SMOKE_ONLY=f2,f3 SMOKE_KEEP_STATE=1 scripts/ui-smoke.sh` to run a
  subset against current state without the fresh/restore cycle.
- A failure names the step and the missing or mismatched AX element and dumps the
  nearby AX tree; fix missing labels in the app rather than weakening the harness
  (drive controls by label, never by pixel coordinates).

Still manual: menu bar state changes. The visualizer reacting to playback is
now asserted by f3, which requires nonzero analyzed energy during muted
playback.

## Repository History

The public history (`origin`, `github.com/danbryan/attache`) starts at the single
commit `Attaché 0.1.0` (2026-07-05), a deliberate clean slate for the public
launch. The full prior development history lives in the private archive
`github.com/bryanlabs/attache`. The `archive` remote is not present in a fresh
clone (check `git remote -v`); add it once per clone. For archaeology (why a
decision was made, when a regression appeared):

```bash
git remote add archive git@github.com:bryanlabs/attache.git   # once per clone
git fetch archive
git log archive/main   # browse the pre-launch history
```

Code signing is unaffected by the move: the app keeps the `com.bryanlabs.attache`
bundle identifier and the Bryanlabs LLC Developer ID certificate.
