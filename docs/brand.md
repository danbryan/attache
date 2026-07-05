# Attaché brand

## Name

**Attaché** (with the accent) for display, branding, and the app's user-facing name.
`attache` (ASCII) everywhere a machine reads it: repo, Swift package, bundle id
(`com.bryanlabs.attache`), CLI, and file paths.

## Tagline

> **Your AI agents, out loud.**

Supporting lines:
- Stop babysitting the terminal.
- Any voice. Any personality. Even one you invent.
- Hear every result, in a voice and personality you choose.

## Voice of the brand

Capable, warm, and a little witty. A sharp teammate, never edgy, bratty, or
salesy. Plain language, headline first. This mirrors Attaché's own default
persona, so the marketing voice and the product voice match.

## Direction: Brass

The look is **warm, premium, and human**. Most AI tooling is cold blue, purple,
or green; Attaché owns warm amber on a tinted ink, which fits a *voice* product
and reads like the brass and leather of an actual attaché case. The base is a
warm ink, never dead black. One confident accent (amber), a serif display with
real scale, and a live waveform as the recurring signature.

## Colors

Dark is the default surface. Light is a warm cream, not a cool white.

| Token | Dark | Light | Use |
| --- | --- | --- | --- |
| Ink | `#141009` | `#F6F1E7` | primary background (warm, never dead black) |
| Panel | `#1C1710` | `#FFFFFF` | cards, raised surfaces |
| Amber | `#E8A24C` | `#996208` | primary accent, "out loud", buttons, waveform |
| Cream | `#F4ECDC` | `#231A0E` | primary text |
| Muted | `#9C8E77` | `#6E6154` | secondary text |
| Brass | `#B7772E` | `#8A5410` | gradient mid, deep accent |
| Local green | `#5AD39A` | `#0E7A44` | reserved: local / private only |

Amber accent-on-white is darkened to stay above the 4.5:1 contrast floor
(enforced by `ThemeContrastTests`). The visualizer gradient runs deep brown to
brass to amber. Green is reserved for the "local / private" meaning; it is not a
second brand accent.

## Typography

- **Display:** a serif at real scale (system `ui-serif` / New York on Apple
  platforms). Used for headlines and the wordmark's "A". This is the biggest
  lever for the premium feel; do not swap it for a grotesk.
- **Body / UI:** SF Pro (`system-ui`).
- **Labels / eyebrows / code:** SF Mono, uppercase with wide tracking.

## Signature: the waveform

An amber audio waveform (a row of rounded bars) is the recurring motif. It sits
under the headline on the site, in the app icon, and in playback UI. It ties
every surface back to the core idea: your agents, out loud.

## Logo

- `docs/assets/attache-logo.svg` — primary mark, scalable.
- `docs/assets/attache-logo.png` — 512px raster fallback.

The mark is an "A" over an audio equalizer inside a field of sound-wave rings, on
a warm-ink tile: brass-to-amber equalizer bars, a cream "A", amber rings. It
matches the macOS app icon (`scripts/generate-app-icon.swift`).

Keep at least 12% of the mark's width as clear space on all sides. Do not
recolor the tile, restretch the mark, or separate the "A" from the bars.

## Themes in the app

**Brass is the default theme** (`CompanionTheme.brass`), so a fresh install opens
in the brand look. Every builtin theme is still available, and **custom themes
are a first-class feature**: users can write their own in Settings → Appearance,
import and export them as JSON, and share them. Custom themes are clamped to the
same 4.5:1 contrast floor so any user theme stays legible. We ship Brass as the
starting point, not a cage; making Attaché yours is the point.
