# Bring Your Own Presence — artwork-manifest spec

Status: design of record for the custom-artwork feature. Expands the "Bring your
own artwork" stub in `design/attache-animation-spec.md` into a buildable spec.
Not shipped yet; this is the plan the MVP is built against.

## Goal

Let a user supply their own artwork (starting with a single image of a face) that
mounts into the *same* animated presence the built-in Attaché robot, Colt, and
Echo use, rather than being a flat, static picture. The user opts into as much
fidelity as they care to draw: one image is already a believable presence; more
frames make the eyes and mouth move.

Two things were settled up front:

1. A single uploaded image is the **neutral tier** and is a complete, shippable
   presence on its own.
2. The built-in robot is **not** changed. It stays fully procedural and fluid.
   The image-frame approach in this doc applies **only** to custom presences,
   which cannot be re-posed procedurally the way vector art can.

## The dynamic mount: what a presence actually has to do

Every presence in Attaché is a *renderer* that reacts to one shared contract.
The app already routes all activity, idle / listening / thinking / tool-running /
speaking / paused / blocked / error / compacting, plus live audio energy, through
`AttacheActivityState` (`Sources/AttacheCore/AttacheActivity.swift`) into a
per-frame `AttachePose` (`design/attache-animation-spec.md:36-68`).

Crucially, the pose splits into two layers:

- **Outer rig (supplied for free by the shared renderer).** `breathe`, `headTilt`,
  `hop`, `squash`, `sway`, the overhead crown symbols (thinking brain, tool gear,
  pause bars, sleeping z's, compaction), `props` (permission/greeting/farewell),
  celebrate confetti, the fleet ring of session motes, and all reduce-motion
  behavior. These apply to the presence as a whole transform and as decorations
  layered around it.
- **Face fields (what a presence must express itself).** `eyeOpenness`
  (`-0.2...1.2`), `gaze` (a 2D focus offset, `±3` units), `browWorry` (`0...1`),
  `dizzy` (`0...1`, error crosses), `mouthOpen` (`0...1`, audio-driven),
  `smile` (`0...1.2`), and `cheekGlow` (`0...1`). Plus accepting the shared head
  transform. (`design/attache-animation-spec.md:143-146`.)

So a "bring your own presence" is nothing more than **a function from those seven
face fields to an image.** The rig does the rest: it breathes the image, sways it
while speaking, hops it on a celebrate, floats the thinking-brain crown above it,
and orbits the fleet motes around it. That is the "mount." A neutral-only image
gets all of that motion and decoration without a single extra frame, which is why
one photo already looks alive.

## Core idea: continuous fields → discrete frames → crossfade

The robot maps the seven fields to continuous vector drawing. A photo can't be
redrawn, so a custom presence maps the same fields to the **nearest available
still frame** and crossfades between frames as the fields change. Fidelity is a
function of how many frames exist:

- With one frame, every field maps to it. Motion comes entirely from the rig.
- With a handful of expression frames, the presence blinks, speaks, worries, and
  shows errors.
- With a gaze grid and mouth-open levels, the eyes track the focused session and
  the mouth follows speech smoothly.

Missing frames never break anything: selection always falls back to the nearest
frame it does have (see *Frame selection*). This is what makes it **progressive**.

## Package format

A presence is a directory `<name>.attache-character`, stored in
`~/Library/Application Support/Attache/Characters/` (per
`design/attache-animation-spec.md:167`):

```text
Dan.attache-character/
  manifest.json
  frames/
    neutral.png        # required; the only required frame
    blink.png          # optional
    speaking.png       # optional
    worried.png        # optional
    error.png          # optional
    gaze/…             # optional, progressive tier
    visemes/…          # optional, progressive tier
```

Every PNG is a transparent **252 × 252** canvas with the silhouette inside the
central **240** box and the top safe area left clear for the shared crown
(`design/attache-animation-spec.md:164-165`). Frames must register: the neutral
silhouette must not jump between frames.

### manifest.json

```jsonc
{
  "format": 2,
  "name": "Dan",
  "canvas": 252,
  "safeArea": 240,

  // Tier 1 — the expression set. Only `neutral` is required; any omitted
  // frame falls back per the selection table below.
  "frames": {
    "neutral":  "frames/neutral.png",
    "blink":    "frames/blink.png",
    "speaking": "frames/speaking.png",
    "worried":  "frames/worried.png",
    "error":    "frames/error.png"
  },

  // Tier 2 (optional) — gaze grid. Each entry is a normalized eye/face offset
  // in [-1, 1] on each axis (mapped from the pose's ±3 gaze units). Used mostly
  // while idle/thinking, when the eyes track the focused fleet mote.
  "gaze": [
    { "x": -1, "y":  0, "path": "frames/gaze/left.png" },
    { "x":  1, "y":  0, "path": "frames/gaze/right.png" },
    { "x":  0, "y": -1, "path": "frames/gaze/up.png" },
    { "x":  0, "y":  1, "path": "frames/gaze/down.png" }
  ],

  // Tier 3 (optional) — mouth-open levels (visemes), sorted by openness in
  // [0, 1]. Smooths speech beyond the single `speaking` frame.
  "visemes": [
    { "open": 0.0, "path": "frames/visemes/closed.png" },
    { "open": 0.5, "path": "frames/visemes/mid.png" },
    { "open": 1.0, "path": "frames/visemes/open.png" }
  ]
}
```

`format: 1` is the five-frame expression set only (the version already sketched in
the animation spec). `format: 2` adds the optional `gaze` and `visemes` arrays.
A loader for a higher format must read a lower one; unknown keys are ignored so
the format can grow.

## Fidelity tiers (progressive)

| Tier | Frames provided | What the user gets |
| --- | --- | --- |
| 0 — Neutral | `neutral` only | A living presence: breathing, idle sway, hops on celebrate, the crown symbols, props, and the fleet ring, all from the rig. Speaking is shown by the voice arcs and a soft cheek/scale pulse rather than a mouth change. |
| 1 — Expression | + `blink`, `speaking`, `worried`, `error` | Blinks on the 4–7 s cadence, opens the mouth while speaking, worries when blocked on the user, crosses out on error. The documented baseline. |
| 2 — Gaze | + `gaze/*` | Eyes track the focused session mote and glance at a newly blocked/finished session, then return. Reads as attentive. |
| 3 — Viseme | + `visemes/*` | Mouth follows analyzed audio through intermediate open levels with the fast-attack / slow-release envelope, so it closes between words instead of a binary open/closed. |
| 4 — Full grid | dense `gaze` × `visemes` (+ blink) | Approaches robot-like fluidity. This is the upper bound, not a requirement (see below). |

## Frame selection and blending

Per rendered frame, given the pose's face fields, pick a target frame, then
crossfade from the current frame over ~120–160 ms (matching the blink/motion
timings in the animation spec) so state changes never pop.

Priority (first match wins), each rule degrades to `neutral` if its frame is
absent:

1. `dizzy > 0.5` → `error`
2. `browWorry > 0.4` → `worried`
3. `eyeOpenness < 0.15` → `blink` (or the nearest low-openness gaze frame)
4. `mouthOpen > threshold` → nearest `viseme` by `open`, else `speaking`
5. otherwise → nearest `gaze` frame to the current `gaze` offset, else `neutral`

Gaze selection picks the atlas entry with the smallest Euclidean distance to the
normalized `(x, y)`; with only a coarse grid this snaps, with a dense grid it
reads as continuous. Because every rule ends in "else neutral," a one-frame pack
is valid and a partial pack (say neutral + speaking only) simply skips the rules
it can't satisfy.

Tier 0 speaking, without a mouth frame: drive `cheekGlow` and a small breathe/scale
pulse from the analyzed audio energy, and let the voice arcs above the head carry
the "talking" read. This keeps a single photo from looking frozen while it speaks.

## The "512" number

The full grid is an upper bound, not a target. If you wanted the densest useful
atlas, roughly: an 8×8 gaze grid (64 directions) × 4 mouth-open levels × 2 blink
states ≈ **512** frames. Nobody needs that: nearest-frame fallback plus crossfade
means a 3×3 gaze grid (9) and 3 visemes already read as fluid, and eyes only need
a few directions to convince. The number was the ceiling of what the format can
express, so authors understand the format never caps them, not a bar to entry.

## Surfaces a presence must satisfy

The same renderer must serve every place the character appears (to be confirmed
against the code map, but per the animation spec's linked sources these are the
mount points):

- The main live surface presence (`AttacheCharacterView` phase choreography over
  `AttacheCharacterFigure`).
- The mini window (`MiniAttacheWindow.swift`).
- Voicemail / history card thumbnails and the personality-editor preview.
- The menu bar and app icon use the static `AttacheMascotMark` and are **out of
  scope** for custom art (they remain the brand robot).

Because all of these already render through the shared character view, a custom
presence that satisfies the face-field contract appears in each automatically.

## Loading and safety

- Load images with `Bundle.main` / explicit file URLs, never `Bundle.module`
  (see the Gotchas in AGENTS.md; `Bundle.module` `fatalError`s on a packaged
  build). User art lives outside the bundle entirely, under Application Support.
- Uploaded images are untrusted input: validate that each is a decodable image at
  the declared canvas size, cap file size and pixel dimensions, ignore non-image
  files in the directory, and never execute anything from the package. The
  manifest is data, not code.
- A malformed or missing `neutral` frame fails the import with a clear message and
  falls back to the previously selected built-in presence; it never crashes or
  leaves a personality with no presence.
- Persist the reference the way `visualMode` already persists on `Personality`
  (`Personality.swift:137`) via `PersonalityStore`, storing the package directory
  name so a personality remembers its custom presence across launches and
  export/import.

## MVP: from one image to a working presence

The first attempt, given a single face photo:

1. Add a custom case to the presence selection (alongside robot / Colt / Echo)
   that renders through a new `CustomPresenceView` mounted in the shared rig, so
   it inherits breathing, sway, hop, crown, props, and the fleet ring.
2. Import flow: drop or pick an image; the app writes
   `~/Library/Application Support/Attache/Characters/<name>.attache-character/`
   with `frames/neutral.png` and a `format: 1` manifest naming just neutral.
3. Render Tier 0: neutral image transformed by the pose's head transform, with the
   Tier-0 speaking treatment (arc + cheek/scale pulse from audio energy). Blink,
   gaze, and mouth are inert until frames exist.
4. Validate it appears on the live surface, the mini window, and the editor
   preview, and that it survives a relaunch.

Then climb the tiers by dropping in more frames (blink/speaking/worried/error,
then gaze/visemes). An authoring convenience worth adding later: generate the
five-frame set from the one neutral image via an image model ("same face, eyes
closed / mouth open / worried brows / X eyes"), so a user gets Tier 1 without
drawing.

## Decisions I defaulted (redirect any of these)

- **Package = a directory, not a zip.** Simpler to write, inspect, and hand-edit;
  matches the animation-spec stub. A zip import can wrap it later.
- **Neutral is the only required frame.** Everything else degrades to it.
- **Menu bar / app icon stay the brand robot.** Custom art is for the in-app
  presence surfaces only.
- **Gaze is normalized to [-1, 1] per axis** in the manifest, decoupling the art
  from the internal ±3 pose units.
- **No mouth animation is faked from a single image.** Tier 0 speaking uses the
  arcs + a pulse rather than a warped jaw, which looks worse than honest stillness.
```
