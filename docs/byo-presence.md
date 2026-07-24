# Bring Your Own Presence

Status: shipped. This is how a user gives Attaché a custom face that mounts into
the *same* animated presence the built-in robot, Colt, and Echo use, instead of a
flat sticker.

The pitch: draw one still image, mark where its eyes and mouth are, and the app
makes it look alive. It breathes, sways while speaking, hops on a celebrate,
floats the thinking crown above its head, orbits the fleet ring around it, moves
its eyes to follow the focused session with full 360-degree gaze, blinks, sleeps,
and lip-syncs the shared equalizer mouth to the voice. You supply the *look*; the
engine supplies the *motion*.

## How the built-in robot works (and why yours can match it)

The robot is drawn entirely in code (`AttacheCharacterFigure.drawRobotFace`); it
is **not** a `.attache-character` package. It is the reference implementation, the
proof of what the pose can drive. Two of its behaviors are the ones a custom
presence reproduces:

- **Eyes: continuous 360-degree gaze, blink, and error.** The robot's eyes are two
  LED bars on a dark visor. The engine translates them by the `gaze` offset in any
  direction (full 360-degree control, not 4/8/16 fixed directions), flattens them
  to blink, and crosses them out on error. It has no eye-*whites* and no pupil,
  because it is a visor.
- **Mouth: the shared equalizer.** `EchoCharacterMouth`: seven mirrored bars in
  the navy `AttacheMascotMark.faceColor`, height riding the analyzed audio, lit by
  a fixed brand under-glow. The robot, Colt, and Echo all use it.

A custom presence reproduces **the same two behaviors and the identical mouth**,
adapted to hand-drawn art instead of code:

- **Eyes: engine-moved pupils** (same 360-degree gaze / blink / error contract).
  Because a drawn face *does* have eye-whites, the engine gets its continuous gaze
  by sliding a pupil inside each white and dropping a lid to blink, rather than
  translating a visor's LED bars. Same capability, rendered the way a drawn eye
  wants. Your eyes keep their own style (a panda's round black eyes, a cartoon's
  big whites); only the moving pupil and the lid are ours.
- **Mouth: the exact same `EchoCharacterMouth`**, drawn at the spot you mark. The
  custom mouth code is a transplant of the robot's mouth block, so a custom face
  lip-syncs identically: navy bars, same brand glow, dark-on-light legibility.

So the shared guidelines are: **drive everything from the one pose; get 360-degree
gaze, blink, sleep, and error for the eyes; and use the one shared equalizer for
the mouth.** The robot meets them in code; the panda (and any user presence) meets
them through the manifest below. The difference is only in the eyes, and only
because the robot is a visor with no whites while a drawn face has them.

The robot itself is **never** modified by any of this. It stays fully procedural,
and a pixel lock (`--render-character-poses`, `neutral-vs-mark` delta must be 0)
fails the build if the robot's neutral pose drifts by even one channel.

## The dynamic mount: what the rig gives you for free

Every presence is a *renderer* reacting to one shared contract. The app routes all
activity (idle / listening / thinking / tool-running / speaking / paused / blocked
/ error / compacting) plus live audio energy through `AttacheActivityState`
(`Sources/AttacheCore/AttacheActivity.swift`) into a per-frame `AttachePose`
(`design/attache-animation-spec.md`).

The pose splits into two layers, and a custom presence only has to worry about the
second one:

- **Outer rig (free).** `breathe`, `headTilt`, `hop`, `squash`, `sway`, the
  overhead crown symbols (thinking brain, tool gear, pause bars, sleeping z's,
  compaction), `props` (permission/greeting/farewell), celebrate confetti, the
  fleet ring of session motes, and all reduce-motion behavior. These transform and
  decorate your whole image; you draw nothing for them.
- **Face fields (yours).** `gaze` (2D focus offset, `±3` units), `eyeOpenness`,
  `dizzy` (error), `mouthOpen` + `audioBars` (the analyzed spectrum). The engine
  turns these into pupil position, lid coverage, the error cross, and the
  equalizer, all at the anchors you mark.

That is the whole mount. One image plus a few anchors gets all of the above.

## Package format

A presence is a directory `<name>.attache-character` in
`~/Library/Application Support/Attache/Characters/`:

```text
Panda.attache-character/
  manifest.json
  frames/
    neutral.png        # the single required image, a transparent 252x252 canvas
```

`neutral.png` is a transparent **252 × 252** PNG with the face inside the central
**240** box and the top area left clear for the shared crown. Draw the eye
*whites/sockets* but leave the pupils out (the engine draws them), and leave the
mouth area as a flat spot the equalizer bars sit on.

### manifest.json

```jsonc
{
  "format": 3,
  "name": "Panda",
  "canvas": 252,
  "safeArea": 240,
  "frames": { "neutral": "frames/neutral.png" },

  // Engine-moved pupils. Coordinates are normalized to the canvas (0..1),
  // top-left origin. Draw the eye WHITES in the image; the engine slides a
  // pupil inside each one for full 360-degree gaze and drops a lid to blink.
  "eyes": {
    "left":  { "x": 0.413, "y": 0.603, "eyeR": 0.056, "pupilR": 0.032 },
    "right": { "x": 0.587, "y": 0.603, "eyeR": 0.056, "pupilR": 0.032 },
    "pupilColor": [0.09, 0.09, 0.11],   // the moving pupil, linear RGB 0..1
    "lidColor":   [0.13, 0.13, 0.15]    // covers the eye when it closes
  },

  // The shared equalizer mouth, drawn at this spot. Same mouth as every
  // built-in presence.
  "mouth": { "x": 0.5, "y": 0.798, "w": 0.14, "h": 0.055 }
}
```

Field by field:

- **`eyes.left` / `eyes.right`** — `x, y` is the center of that eye white; `eyeR`
  is the radius of the white (how far the pupil can travel); `pupilR` is the pupil
  radius. The pupil moves within `eyeR - pupilR` of the center, so it never spills
  past your eye. `left` is the image-left eye.
- **`eyes.pupilColor`** — the color of the moving pupil. Match it to your presence's
  eye style (near-black for a panda, a warm brown for a person, anything).
- **`eyes.lidColor`** — the color that covers the eye when it blinks or sleeps.
  Use your eyelid, fur, or skin color so a closed eye reads naturally instead of
  looking like a hole. The panda uses its black eye-patch color.
- **`mouth`** — `x, y` centers the equalizer; `w, h` sizes it. Leave a flat area
  in the artwork here; the engine draws the navy equalizer bars directly on it
  (no box or cavity), so it needs to be a plain patch of the face.

Eyes and mouth are both optional. A `neutral`-only pack with no `eyes`/`mouth` is
valid and still gets all the rig motion (breathe, sway, crown, fleet ring); it
just can't move its eyes or lip-sync. Add the anchors to unlock those.

### Drawing the eyes (what to keep in mind)

- **Draw only the eye whites/sockets, never the pupils.** The engine paints a
  moving pupil on top; a pupil in your artwork gives you two.
- **Keep each eye-white roughly round.** The pupil travels in a circle of radius
  `eyeR - pupilR`, so for a slitted or almond eye set `eyeR` to its *shorter*
  half-extent (usually the height); the pupil then stays inside the shape and
  simply doesn't use the full width.
- **`pupilR ≈ 0.6 × eyeR` is a good start.** Smaller pupils read wide-eyed, larger
  ones sleepy. Leave enough gap (`eyeR - pupilR`) that the gaze shift is visible.
- **`pupilColor`** is the eye color you want; near-black reads best at this size.
  The engine adds a white catchlight for you, and crosses the eyes in this color
  on an error.
- **`lidColor` is the easy thing to get wrong.** Set it to the skin/fur color
  *around* the eye, not black by default, so a blink or sleep looks like a lid
  closing rather than a hole. Panda: its black eye-patch. Fox: its orange fur.
- Leave clear space between the two eyes and keep them out of the top crown zone.

### Drawing the mouth (how to use it correctly)

- **Leave the mouth area flat and plain.** Do not draw lips, teeth, or a mouth
  line; the engine draws the mouth on top of whatever is there.
- **The engine draws the literal robot mouth:** dark navy equalizer bars (no box,
  no cavity) with a soft brand under-glow, short at rest and rising with speech.
- **Dark bars need a lighter backing.** They read because they are dark-on-light
  (the robot's steel, the panda's and fox's white muzzles). If your face is dark
  where the mouth goes, give it a lighter muzzle patch there, or the bars vanish
  into it. This is the single most important mouth rule.
- **Size `mouth.w` to the width actually available** at that spot: about `0.14` on
  a wide/round muzzle, about `0.10` on a narrow/pointed one. Too wide overhangs a
  narrow muzzle; too narrow looks pinched.
- Put `mouth.y` just below the nose with a little clearance.

## Any head shape works (the framework is shape-agnostic)

The engine never looks at your silhouette. Eyes and the mouth are placed by the
explicit normalized anchors above, so the head can be any shape: the built-in
robot is square, the panda is round, and the fox
(`scripts/custom-presence/make-fox-presence.swift`) is a pointed inverted
triangle. All three use the identical machinery; only the anchors differ.

There is no "supported shapes" list. The only authoring constraints are the ones
that apply to every shape:

- Keep the whole face inside the **240** box, with the **top area clear** for the
  shared crown (thinking brain, z's, tool gear). The fox's ears and the robot's
  antenna both stay below that zone.
- Put the mouth anchor where the seven-bar equalizer has room. A **narrowing
  muzzle** (the fox) is the one real wrinkle Dan flagged, and the fix is just a
  smaller `mouth.w` (the fox uses `0.10`; the panda's rounder face uses `0.14`),
  not a shape restriction.
- Draw eye *whites* the pupil can sit in, and pick a `lidColor` that matches the
  fur/skin *around* the eyes so a blink reads naturally (the fox's lid is its
  orange fur; the panda's is its black eye-patch).

## Worked example: the panda

`scripts/custom-presence/make-panda-presence.swift` draws the bundled panda
example from scratch with Core Graphics, so the whole pipeline is reproducible:

```bash
swift scripts/custom-presence/make-panda-presence.swift \
  "$HOME/Library/Application Support/Attache/Characters/Panda.attache-character"
```

It writes `frames/neutral.png`: a white face with black ears and eye patches,
**blank white eye areas** (no pupils), a nose, and a flat spot under the nose for
the mouth. Pair it with the `manifest.json` above (its anchors match where the
script draws the eyes and mouth). Then preview every pose without launching the
app:

```bash
swift build
.build/debug/Attache --render-custom-presence \
  "$HOME/Library/Application Support/Attache/Characters/Panda.attache-character" \
  /tmp/panda-poses
```

That renders neutral, the four cardinal gazes plus a diagonal (proving 360-degree
control), half-lidded, blink, sleep, error, and three mouth-open levels, plus a
`robot-neutral-head.png` at the same size for a side-by-side placement check.

The fox (`make-fox-presence.swift`) is the same three steps with a pointed head
and a smaller `mouth.w`; run it the same way to see a non-round, non-square face
go through the identical pipeline.

## Make your own (or point an AI agent at it)

**Effort:** a custom face is one PNG plus a roughly ten-line manifest. The panda
and fox were each a single ~120-line Core Graphics script
(`make-panda-presence.swift`, `make-fox-presence.swift`) plus the manifest: a few
minutes of drawing and one or two anchor-tuning passes. You do not have to write
Swift. Any tool that exports a transparent 252×252 PNG works (an image editor, or
an image model), and the manifest is hand-editable JSON. The two example scripts
are just a reproducible, inspectable way to author the neutral image.

Two ways in:

1. **Draw it yourself.** Export a transparent 252×252 PNG (face in the 240 box,
   top clear, eye-whites drawn but pupils left out, a flat mouth spot), drop it at
   `~/Library/Application Support/Attache/Characters/<Name>.attache-character/frames/neutral.png`,
   and write `manifest.json` beside it with your eye and mouth anchors.
2. **Have an AI agent do it.** Copy the prompt below, swap the animal, and hand it
   to an agent (Claude Code, Codex, ...) working in a clone of this repo. It
   produces the same kind of script the panda and fox use, renders it, and tunes
   the anchors.

### A prompt you can hand to an agent

Replace "FROG"/"Frog" with whatever you want. This assumes the agent is running in
a checkout of the Attaché repo.

```text
I want an Attaché custom presence: a FROG. Read docs/byo-presence.md and follow it
exactly. Use scripts/custom-presence/make-panda-presence.swift and
make-fox-presence.swift as templates (round face and pointed face). Produce:

1. scripts/custom-presence/make-frog-presence.swift — a Core Graphics script that
   draws a transparent 252x252 neutral.png of a friendly frog face:
   - the whole face inside the central 240 box, with the TOP AREA LEFT CLEAR for
     the shared crown (no tall features poking into the top ~40 px)
   - eye WHITES drawn but NO pupils (the engine adds the moving pupils)
   - a flat mouth spot with no drawn mouth (the engine draws the equalizer there)
2. A Frog.attache-character/ package under
   "$HOME/Library/Application Support/Attache/Characters/" containing
   frames/neutral.png and manifest.json (format 3). In the manifest:
   - eyes.left / eyes.right {x,y,eyeR,pupilR} placed EXACTLY where you drew each
     eye white (x,y = its center; eyeR = its radius; pupilR ≈ 0.6 * eyeR)
   - eyes.pupilColor matching the eyes; eyes.lidColor matching the skin/fur
     AROUND the eyes so a blink reads as a closing lid, not a hole
   - mouth {x,y,w,h} on the mouth spot, with w sized to the muzzle width there
     (panda 0.14 on a round face; fox 0.10 on a narrow one)

Then render and inspect, iterating until it looks right:
   swift build
   .build/debug/Attache --render-custom-presence \
     "$HOME/Library/Application Support/Attache/Characters/Frog.attache-character" \
     /tmp/frog-poses
Check /tmp/frog-poses/: pupils centered at neutral, gaze tracking in all
directions (including the diagonal), blink/sleep closing cleanly, error crossing,
and the mouth bars legible (dark bars read best on a lighter mouth area). Do NOT
change the robot in any way, and keep `swift test` green — there is a repository
vocabulary guard that bans a few retired words; if it fails, rename to "presence".
```

The same prompt works for a hand-drawn or model-generated PNG: skip step 1, put
your PNG at the package's `frames/neutral.png`, and have the agent write and tune
the manifest against where the eyes and mouth actually are in your image.

## Importing an appearance

The built-in app ships only Attaché, Colt, and Echo. Everything else is imported,
not bundled. In the editor's **Appearance** section, click **Import…** and choose
a `.attache-character` folder from disk. The app validates it, copies it into
`~/Library/Application Support/Attache/Characters/`, and selects it. Sources:

- **Your own filesystem** — a folder you drew or generated (e.g. the output of a
  `make-*-presence.swift` run).
- **GitHub / someone else's repo** — clone or download the repo, then import the
  `.attache-character` folder from the checkout.

This repo ships two ready examples under `examples/appearances/`
(`Fox.attache-character`, `Panda.attache-character`). Clone the repo and import
either folder to see the flow end to end.

Import is hardened because the package is untrusted input: the manifest must
decode and validate, every referenced frame must be a normal relative path (no
absolute paths, no `..` traversal) that decodes as an image, and only the
manifest and its referenced frames are copied, never other files in the source
folder. A name collision gets a numeric suffix, so importing never overwrites an
existing appearance. A package that fails any check imports nothing and shows an
error. See `AttacheCustomPresenceStore.importPackage`.

## How the pose drives your face

Per frame, the engine reads the pose and draws over your neutral image:

| Pose field | What the engine does at your anchors |
| --- | --- |
| `gaze` (±3, x/y) | Slides both pupils continuously toward the focus. Any direction, not a fixed set. Clamped so pupils stay inside the eye white. |
| `eyeOpenness` | Drops the `lidColor` lid from the top of each eye. Full open draws no lid; a blink covers most of it; closed covers all of it. |
| `overhead == .sleeping` | Eyes fully closed and **not** tracking the cursor (a sleeping face shouldn't watch you), z's float from the crown. |
| `dizzy` (error) | Crosses out each eye in the pupil color. |
| `mouthOpen` + `audioBars` | Drives the shared equalizer bars at the mouth anchor, exactly as on the robot. |

Everything else (breathing, sway, hop, the crown, props, the fleet ring) is the
rig acting on your whole image; you don't handle it.

## Where a presence shows up

- **Animated (the real presence)** — the main live surface (`AttacheRootView` →
  `EchoformRendererView` → `AttacheCharacterView` → `AttacheCharacterFigure`) and
  the desktop mini window (`MiniAttacheWindow`). Full rig.
- **Static preview** — the personality editor preview and presence-picker chips
  (`PersonalitiesPane`, `PersonalityPresencePreview`) draw the neutral pose.
- **Emoji/thumbnail fallback** — voicemail/history thumbnails and the palette use
  `Personality.characterAvatarEmoji`, a glyph, not the figure.
- **Out of scope** — the menu bar glyph and app icon stay the brand robot
  (`AttacheMascotMark` / `AttacheAppIcon`).

## Loading and safety

- Frames load with `Bundle.main` / explicit file URLs, never `Bundle.module`
  (which `fatalError`s on a packaged build; see AGENTS.md Gotchas). User art lives
  under Application Support, outside the bundle.
- Uploaded art is untrusted input: the loader validates each frame is a decodable
  image, ignores non-image files, and treats the manifest as data, never code. A
  missing or malformed `neutral` fails the import cleanly and falls back to the
  previously selected built-in presence; it never crashes or leaves a personality
  with no face.
- A personality stores only the package *reference* (`customPresenceRef`, the
  directory name), threaded through `Personality`'s `CodingKeys`/`encode`/`decode`
  and persisted by `PersonalityStore`. An exported personality carries the
  reference only, so importing it without the art falls back to the robot/emoji.

## Design decisions of record

- **The robot is never changed.** Custom art only affects the in-app presence
  surfaces; the robot stays fully procedural and pixel-locked.
- **Eyes are engine-moved pupils, not baked directions.** This gives a custom
  presence the robot's continuous 360-degree gaze while keeping the presence's own eye
  style. The artwork draws whites; the engine owns the pupil and lid.
- **The mouth is the one shared equalizer.** Uniform across the robot, Colt, Echo,
  and every custom presence, so lip-sync is identical everywhere.
- **One image is a complete presence.** Eyes and mouth anchors are optional
  upgrades; a neutral-only pack still lives and moves through the rig.
- **Package is a directory, not a zip.** Simple to write, inspect, and hand-edit.
