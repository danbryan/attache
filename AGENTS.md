# AGENTS.md

This is the source of truth for both Codex (`AGENTS.md`) and Claude Code, which
reads it through a `CLAUDE.md` symlink in this directory. Edit this file, not the
symlink.

## Scope

Attaché is a standalone Swift package (pure SwiftPM, no `.xcodeproj`). Its only
external dependency is Sparkle (in-app updates); it depends on no other local
repositories. It has shipped publicly; see Status.

## Status

Attaché has shipped publicly. The current release is `v0.1.3`.

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
- `ATTACHE_LIVE_CODEX_ROUTING_TEST=1` un-skips the real Codex routing canary in
  `swift test` (wrapped by `scripts/codex-personality-routing-canary.sh`).
- `SMOKE_POSE=inbox|settings|live` (comma-separated, applied in order) poses the
  packaged app for screenshots via the smoke harness; `SMOKE_TEXTSCALE` sets
  text size and `SMOKE_POSE_SECONDS` the hold time.
- `ATTACHE_TWO_WAY_EXPIRY_SECONDS=<n>` overrides the two-way instruction expiry
  window (docs/two-way.md's 30-minute default) to `<n>` seconds, so
  `scripts/two-way-negative-path-smoke.sh` can drive a real expiry against the
  packaged app in seconds. Inert unless `ATTACHE_UI_TEST=1` is ALSO set (the
  harness always sets it), so this can never shrink a real user's window by
  itself; see `InstructionReplyEngine.expiryWindow(fromEnvironment:)` and its
  tests for the explicit non-bypass proof (INF-256/E4).

## Safety Rules

- Do not silently send messages into Codex, Claude Code, or any other harness.
- A reverse-send action must identify the target source and session.
- If a harness cannot guarantee reverse-send support, create a draft or show a
  blocked state instead.
- Do not put API keys or tokens in the repo.
- Do not weaken the local event server hardening (per-launch token, connection
  caps, request size limits) or on-disk file permissions to make testing easier.

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
   VERSION=X.Y.Z NOTARIZE_APP=1 NOTARY_PROFILE=bryanlabs-notary scripts/package-app.sh
   ```
   Produces `dist/Attache.app` (stapled), `dist/Attache.zip`, `dist/SHA256SUMS`.
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

- **No "companion" in user-facing text.** Historical internal names still say
  Companion (`CompanionPersonality`, `CompanionTheme`, etc.); those are code, not
  copy. Never surface the word to users.
- **Tagline: "Fluent in agent. Speaks human."** The old "Your AI agents, out
  loud" slogan is retired everywhere (README, brand, site, video).
- **Built-in themes are exactly four:** macOS (default AND first in the list),
  High Contrast, Paper, Cyberpunk. Brass / classic / ember / ocean / slate-mono /
  violet-dusk were removed. Users can still author custom themes.
- **The three built-in personalities are domain-agnostic.** Explainer, Big
  Picture, and Inquisitive must read for any profession (finance, medicine, law,
  athletics, content), not just developers. No build/log/ship/deploy specifics.
- **Recap length is dynamic.** The recap prompt scales a sentence ceiling by item
  count, clusters related items, compresses solved problems to their outcome, and
  preserves decisions.
- **Never emit em dashes in spoken output.** Personalities are instructed to
  avoid them AND `CompanionPersonality.stripDashes` removes them deterministically
  on the spoken path, because the model ignores the instruction often enough to
  matter.
- **No hidden phrase routing for agent sends.** Live conversation has explicit
  destinations: Ask Attaché goes to the personality, Tell Agent sends the raw turn
  through the two-way send-to-agent pipeline. Do not infer destination with
  English phrase matching before the personality sees the turn. That approach is
  brittle across languages and unsafe on false positives; personality-driven
  delegation remains available through `stage_agent_instruction`.
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

Before claiming a change works, verify:

- `swift build && swift test` pass,
- `scripts/ui-smoke.sh` passes.
- Before a release candidate, run `scripts/release-readiness-smoke.sh` as the
  ten-gate pre-release suite. Set `ATTACHE_RELEASE_READINESS_WITH_CODEX=1`
  when the candidate also needs the real Codex f7/f8 round trips in the same run.

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
5. theme, voice engine, and text size changes persist across a relaunch and are
   restored to what the user had, and Escape closes Settings,
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
