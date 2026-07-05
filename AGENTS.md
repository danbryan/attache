# AGENTS.md

## Scope

Attaché is a standalone Swift package (pure SwiftPM, no .xcodeproj) with no
dependencies on other local repositories. It is being driven from prototype to
a shareable release; see Current Phase.

## Current Phase: Launch Readiness

Work is tracked in Linear under umbrella ticket INF-174 (project "Attaché
Launch Readiness"). The working agreement for all agents in this phase:

- Work entirely locally. Do not push to origin, do not open PRs, do not create
  GitHub releases. GitHub is reserved for external feedback.
- One branch per ticket off `main`. Merge to local `main` only after
  `swift build && swift test` is green and the ticket's acceptance criteria
  hold. Roll back with `git reset`.
- Update the Linear ticket as work progresses when Linear access exists;
  otherwise report changes so Dan can update it.

## Product Direction

Build one user-facing macOS app, not two user-managed apps.

The app should run in the background like a menu bar utility and optionally show
a translucent Attaché window. The background bridge and the visible Attaché
surface may be separate internal modules or helper processes later, but the MVP
should start as one app process.

## Priority

1. Preserve voicemail-style agent update cards.
2. Preserve spoken recaps with replay.
3. Preserve karaoke captions.
4. Add Echoform-style abstract visual presence.
5. Keep reverse-send behavior safe and explicit.
6. Keep the prototype installable and easy to run on a developer Mac.

## Architecture Map

- `Sources/AttacheCore`: testable logic. Transcript parsing, narration
  coalescing, pipeline ordering and dedup, the card store, the instruction and
  two-way reply engine, diagnostics.
- `Sources/AttacheApp`: the SwiftUI/AppKit app. Session watchers, the local
  event server, speech playback, two-way delivery adapters and coordinator,
  views.
- `docs/two-way.md`: two-way channel design of record.
- New logic that can be unit-tested belongs in `AttacheCore`.

## Build Rules

- Prefer native macOS APIs for the MVP.
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

## Safety Rules

- Do not silently send messages into Codex, Claude Code, or any other harness.
- A reverse-send action must identify the target source and session.
- If a harness cannot guarantee reverse-send support, create a draft or show a
  blocked state instead.
- Do not put API keys or tokens in the repo.
- Do not weaken the local event server hardening (per-launch token, connection
  caps, request size limits) or on-disk file permissions to make testing
  easier.

## Git And Commits

- Commits must be GPG-signed. Signing is pre-warmed on this machine. If a
  commit fails to sign, stop and ask Dan to unlock the login keychain and
  1Password. Never disable signing or work around it.
- Commit messages are concise: what changed and why. No metadata sections, no
  co-authored-by lines, no em dashes.
- Never commit secrets, tokens, or key material.

## Release And Distribution

During the launch-readiness phase, do not publish releases and do not push.
The commands below are the canonical release path for when Dan cuts a release.

- The public-facing app name is `Attaché`, packaged from the SwiftPM
  product `Attache`.
- The bundle identifier is `com.bryanlabs.attache`.
- Set the Apple Developer team ID with your own `<TEAM_ID>`.
- The direct-distribution signing identity is
  `Developer ID Application: <YOUR NAME> (<TEAM_ID>)`.
- The local notarytool keychain profile is `bryanlabs-notary`.
- Store the app-specific notary credential in your password manager and load it
  through the keychain profile. Do not print, commit, or paste the password.
- The canonical release command is:

```bash
NOTARIZE_APP=1 NOTARY_PROFILE=bryanlabs-notary scripts/package-app.sh
```

- That command should produce:

```text
dist/Attache.app
dist/Attache.zip
dist/SHA256SUMS
```

- Before claiming a release is ready, verify all of:

```bash
codesign --verify --strict --verbose=2 "dist/Attache.app"
xcrun stapler validate "dist/Attache.app"
spctl --assess --type execute --verbose=4 "dist/Attache.app"
(cd dist && shasum -a 256 -c SHA256SUMS)
```

- `spctl` must report `accepted` with `source=Notarized Developer ID`.
- Publish GitHub release assets with:

```bash
VERSION=0.1.2 scripts/create-github-release.sh
```

- `scripts/create-github-release.sh` intentionally fails closed if the app is
  not signed, stapled, Gatekeeper-accepted, checksummed, or if the git worktree
  is dirty.
- Use `ALLOW_PRIVATE_RELEASE=1` only for a private or internal test release. For
  a public user to download from GitHub, the repository or release asset must be
  publicly accessible.
- Current release: `v0.1.2`.
- A zip-wrapped `.app` is the current release artifact. A `.dmg` is optional
  polish for a later installer-style experience, not required for notarized
  GitHub downloads.
- Relevant Apple docs:
  - <https://developer.apple.com/help/account/create-certificates/create-developer-id-certificates/>
  - <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>
  - <https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow>

## Verification

Before claiming a change works, verify:

- `swift build && swift test` pass,
- `scripts/ui-smoke.sh` passes.

The UI smoke harness (INF-156) is the standard UI verification step. It builds
and packages an unsigned app, switches to a fresh-user profile (backing up real
state and restoring it afterward), launches the app headed, and drives five
flows through the accessibility API via the `AttacheUISmoke` target:

1. launch reaches the idle dock,
2. a demo event posts through the token-guarded server, shows as an unread
   card, and plays on demand,
3. pause, seek, and resume work and captions stay visible,
4. Command-K opens, search filters to a match, Escape closes, and reopening
   puts the cursor back in search with no focus fallback,
5. theme, voice engine, and text size changes persist across a relaunch and
   are restored to what the user had, and Escape closes Settings,
6. the ⌘I inbox and ⌘Y history palettes open, filter as you type, and close
   on Escape.

Under `ATTACHE_UI_TEST=1` the secret vault never touches the real keychain,
so smoke runs cannot churn keychain ACLs or hang on authorization dialogs.

Harness notes:

- The process running the harness needs a one-time Accessibility grant
  (System Settings > Privacy & Security > Accessibility).
- Iterate with `SMOKE_ONLY=f2,f3 SMOKE_KEEP_STATE=1 scripts/ui-smoke.sh` to run
  a subset against current state without the fresh/restore cycle.
- A failure names the step and the missing or mismatched AX element and dumps
  the nearby AX tree; fix missing labels in the app rather than weakening the
  harness (drive controls by label, never by pixel coordinates).
- Flow 3 asserts caption text via the caption layer's AX value; flow 1 gains an
  onboarding assertion once INF-153 lands.

Still manual: menu bar state changes and the visualizer reacting to playback.

## Repository History

The public history of this repo starts at v0.3.0 (2026-07-03) as a single
initial commit, a deliberate clean slate for the public release. The full
development history up to that point (about 140 commits of build-up, dead
ends, and reversals) lives in the private archive `bryanlabs/attache`,
frozen at the squash point. If you need archaeology (why a decision was
made, when a regression appeared, what an older design looked like), add it
as a remote and fetch:

```bash
git remote add archive git@github.com:bryanlabs/attache.git
git fetch archive
```

Code signing is unaffected by the move: the app keeps the
`com.bryanlabs.attache` bundle identifier and the Bryanlabs LLC Developer ID
certificate. Only the repository home changed.
