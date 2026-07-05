# Contributing

Attaché is a pure SwiftPM project with zero third-party dependencies. Keep it
that way.

## Build and test

```bash
swift build          # build
swift test           # unit tests
scripts/ui-smoke.sh  # UI smoke suite (drives the real app; needs an idle Mac)
```

PRs should come with `swift build` and `swift test` green. Run the UI smoke
suite when you touched app behavior; it backs up and restores your own app
profile, and it types into the app, so run it when you are not using the
machine.

## Contribute a personality

Personalities are single prompts that define how Attaché narrates: tone,
attitude, level of detail, language. Community personalities live in
[`examples/personalities/`](examples/personalities/) and ship with the repo;
users paste them into **Settings → Personalities → New**.

To add one:

1. Create `examples/personalities/your-name.md`. The whole file is the prompt.
   Look at [`radio-dispatch.md`](examples/personalities/radio-dispatch.md) for
   the shape: a one-line identity, then concrete delivery rules.
2. Keep it under 2,000 characters. It shapes style only; Attaché injects the
   functional scaffolding (output format, what to include) around it, so don't
   restate that.
3. Test it in the app: Settings → Personalities → New, paste, play a card.
   A good personality survives ten updates in a row without getting annoying.
4. Open a PR with the file and one sentence on when someone would want it.

What makes a good one: a clear voice you can hear ("late-night radio
dispatcher"), rules about what to omit (nobody wants stack traces read aloud),
and honesty preserved (blockers and uncertainty never softened). Personalities
that are jokes for one listen, leak functional instructions, or bury the
actual update will be declined.

`swift test` validates every file in the gallery (exists, non-empty, length
cap), so a failing PR check means the file needs trimming.

## Contribute a theme

Themes are JSON specs in [`themes/`](themes/). Build yours in the app
(**Settings → Appearance → theme editor**), export it, drop the file in
`themes/`, and open a PR. The readability floor (WCAG 4.5:1) is enforced at
load, and `swift test` validates every spec in the directory.

## Code PRs

- One focused change per PR, with a test where behavior changed.
- Never weaken the security posture: event-server token auth, 0600 file
  permissions, connection caps, keychain handling.
- Match the surrounding style; comments only where the code cannot say it.

## Bugs and ideas

Open a [GitHub issue](https://github.com/danbryan/attache/issues). For bugs:
macOS version, what you did, what you heard or saw instead.
