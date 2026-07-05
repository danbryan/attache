# Attaché brand

## Name

**Attaché** (with the accent) for display, branding, and the app's user-facing
name. `attache` (ASCII) everywhere a machine reads it: repo, Swift package,
bundle id (`com.bryanlabs.attache`), CLI, and file paths.

The name is the concept. An attaché is a specialist assigned to brief their
principal: someone fluent in a domain who translates it and reports back. That
is the whole product. It is fluent in what your agents are doing, and it tells
you in plain language.

## Tagline

> **Fluent in agent. Speaks human.**

Supporting lines:
- Your AI agents, out loud.
- Stop babysitting the terminal.
- Any voice. Any personality. Even one you describe.

## Direction: native blue

Almost every AI product paints itself the same cold blue, purple, or
teal-on-black. Attaché goes the other way: native macOS blue, the same accent
the operating system already uses, on real macOS surfaces. It reads like part of
the Mac rather than another neon dashboard, which fits a product whose job is to
talk to you like a person. One confident accent (the system blue), clean type,
and a live waveform as the recurring signature.

## Colors

The default theme follows the system accent color and switches with light and
dark mode, so a fresh install already looks at home on the user's Mac. The blue
below is the brand anchor and the fallback when there is no system accent to
defer to.

| Token | Dark | Light | Use |
| --- | --- | --- | --- |
| Blue | `#0A84FF` | `#007AFF` | primary accent, buttons, waveform, links |
| Ink | `#1C1C1E` | `#F2F2F7` | primary background |
| Panel | `#2C2C2E` | `#FFFFFF` | cards, raised surfaces |
| Text | `#F2F2F7` | `#1C1C1E` | primary text |
| Muted | `#98989F` | `#6E6E73` | secondary text |

The two blues are the macOS system accent for dark and light. Accent-on-white is
darkened where needed to stay above the 4.5:1 contrast floor, which is enforced
in tests. One accent, blue, everywhere; there is no second brand color.

## Typography

- **Display / UI:** SF Pro (`system-ui`), the native macOS type. Headlines lean
  on weight and scale, not a decorative face.
- **Labels / eyebrows / code:** SF Mono, uppercase with wide tracking.

## Signature: the waveform

A blue audio waveform (a row of rounded bars) is the recurring motif. It sits
under the headline on the site, in the app icon, and in the playback UI. It ties
every surface back to the core idea: your agents, out loud.

## Logo

- `docs/assets/attache-logo.svg`, primary mark, scalable.
- `docs/assets/attache-logo.png`, 512px raster fallback.

The mark is an "A" over an audio equalizer inside a field of sound-wave rings. It
matches the macOS app icon (`scripts/generate-app-icon.swift`).

Keep at least 12% of the mark's width as clear space on all sides. Do not
restretch the mark or separate the "A" from the bars.

## Themes in the app

The **default theme follows the system accent color**, so a fresh install picks
up whatever blue (or other accent) the user already runs and tracks light and
dark mode. Cyberpunk, Paper, and High Contrast ship as built-in alternatives.
**Custom themes are a first-class feature:** users write their own in Settings,
Appearance, import and export them as JSON, and share them. Every theme,
including custom ones, is clamped to the same 4.5:1 contrast floor so it stays
legible. The native look is the starting point, not a cage.

## Voice and tone

The brand voice and the product's default personality are the same voice: a
sharp, warm colleague who briefs you and gets out of the way. Rules:

- Terse and concrete. Say the thing, then stop.
- Human, not corporate. Plain words, headline first.
- No hype adjectives, no marketing fluff, no selling.
- No em-dashes. Use commas, periods, or parentheses.
- Attaché is not an assistant-of-everything and not a sidekick. It is an
  attaché: a liaison that is fluent in your agents and reports to you.
