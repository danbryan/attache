# Bubbles pet v1 animation spec

The pet is the logo brought to life. Everything here animates the exact
geometry of `design/attache-logo.svg` (the locked 2026-07-11 mark, drawn in
code by `AttacheMascotMark.swift` in a 240-unit design box): the cream head,
the two arc eyes, the pink cheeks, the smiling mouth, three limbs, three voice
arcs overhead, and three typing agent bubbles at hand and foot. No new
anatomy. A pose is a set of parameter values over that geometry; an animation
is a spring between poses plus a few continuous loops.

The runtime rig lives in `Sources/AttacheApp/Views/BubblesPetFigure.swift`
(`BubblesPose` is the parameter set, `BubblesPetFigure` draws one pose).
Renders in `design/pet/` come from that rig via `Attache --render-poses`, so
the mockups can never drift from what ships.

## Anatomy notes

- The design box is 240 units, padded to 252 like every other renderer of the
  mark (the outer voice arc crests above y=0).
- Bubble identity is already brand-true: the left rust bubble (`#d97757`) is
  Anthropic clay, so it is **Claude's bubble**; the right green bubble
  (`#10a37f`) is OpenAI green, so it is **Codex's bubble**; the center blue
  bubble is the app's own accent blue and stands for **everything else**
  (`activeAgent == .none`, MCP, demo sources). This mapping is load-bearing:
  choreography lights the bubble whose agent acted.
- The face is the emotional channel, the bubbles are the activity channel,
  and the arcs are the voice channel. A phase should never need more than one
  change per channel to read.

## Pose parameters (the bones)

| Parameter | Range | What it moves |
| -- | -- | -- |
| `breathe` | 0-1 phase | whole-figure scale 1.000-1.015, arcs drift 1 unit |
| `headTilt` | degrees, -8..8 | head + face rotate around the head center |
| `eyeOpenness` | 0-1 | 1 = the mark's happy arcs; 0 = closed flat lines |
| `gaze` | unit offset, ±3 | eyes and mouth shift together (glances) |
| `browWorry` | 0-1 | worry brows fade in above the eyes, eye arcs flatten |
| `dizzy` | 0-1 | eyes crossfade to little X strokes |
| `mouthOpen` | 0-1 | smile morphs to a round open mouth (speech tracks audio) |
| `smile` | 0-1 | mouth width and curve; low = small worried mouth |
| `cheekGlow` | 0-1 | cheek opacity; 0.6 is the mark's resting value |
| `hop` | units, 0-16 | vertical body offset, with squash on landing |
| `sway` | degrees, -2..2 | gentle whole-body rock while speaking |
| `arcGlow` | 0-1 | arc opacity multiplier over the mark's 1.0/0.62/0.30 |
| `arcRipple` | -1..1 | arc radius phase; positive ripples outward, negative inward |
| `bubbles[3].lift` | units, -4..14 | bubble rises off its resting spot |
| `bubbles[3].wobble` | phase | small rotation/x jitter while lifted |
| `bubbles[3].brightness` | 0-1 | 1 lit, 0.35 dimmed; identity never changes hue |
| `bubbles[3].dotPhase` | phase or nil | typing dots cycle; nil freezes them |
| `bubbles[3].pop` | 0-1 | confetti burst progress (celebrate only) |

## State table

Every `CompanionActivityPhase` plus the celebrate one-shot. "Active bubble"
means the bubble for `activeAgent` (center when `.none`).

| Phase | Face | Body | Arcs | Bubbles |
| -- | -- | -- | -- | -- |
| `sleeping` | eyes closed, mouth small | slow breathe, 4.5 s cycle | dimmed to 0.25, still | all resting, dots frozen, dimmed |
| `idle` | soft blink loop, occasional glance | breathe 3.2 s | faint pulse, 0.30-0.45 slow sine | independent gentle bob ±1.5 u, all at full brightness (the static idle pose is exactly the logo; dimming only ever marks another bubble as active) |
| `agentThinking` | head tilts 6° toward the active bubble, gaze follows | breathe 2.8 s | soft | active bubble lifts 8 u, wobbles, dots cycle at 0.9 s; others dim to 0.45 |
| `toolRunning` | eyes narrow slightly (focus) | breathe 2.4 s | soft | active bubble vibrates per `toolKind`: shell = 9 Hz x-shake, edit = dot scribble jitter, read = slow side-to-side scan, web = dots orbit the bubble, other = plain wobble |
| `agentResponding` | eyes wide, brows up | slight lean toward the bubble | ripple inward, glow up to 0.8 | active bubble springs 12 u toward the head, dots solid |
| `speaking` | mouth opens on `audio.level`, blink suppressed above level 0.5 | sway ±1.2° at 0.6 Hz | ripple outward, glow follows level | speaking agent's bubble lit 1.0, others 0.4 |
| `paused` | mouth held mid-closed, eyes soft | breathe only | held at 0.5, no ripple | held in place |
| `blockedOnUser` | worry brows 1.0, cheeks pale to 0.2, small flat mouth | shallow breathing | stopped, static 0.15 | active bubble jumps 14 u every 1.6 s, urgent; others 0.3 |
| `error` | dizzy X eyes, small round mouth | tiny wobble | flicker, 2-4 Hz opacity noise | active bubble droops 4 u below rest, dots dim |
| celebrate (one-shot, 1.2 s) | happy arcs, big smile, cheeks 1.0 | hop 16 u, squash-and-stretch landing | double outward ripple | active bubble pops 6 confetti dots in its own color |

Celebrate is not a contract phase: it is a one-shot the choreography layer
(INF-271) queues on turn completion, played over whatever continuous phase
follows, and dropped if a higher-priority phase (blocked, speaking) arrives
first.

`userTyping` is not a phase either: when the contract reports typing and the
phase is `idle` or `sleeping`, the pet may tap its bubbles like keys (the
INF-273 "types along with you" delight). It must never override an agent
phase.

## Motion rules

Springs, one vocabulary everywhere (SwiftUI `spring(response:dampingFraction:)`):

- `standard` 0.35 / 0.78: most pose transitions.
- `snappy` 0.22 / 0.70: blocked jumps, responding bounce, celebrate takeoff.
- `soft` 0.60 / 0.90: entering sleep, arc dims, cheek fades.

Loops:

- Blink: every 4-7 s (uniform jitter), 120 ms close, 90 ms hold, 140 ms open;
  15 percent of blinks double. Suppressed while `mouthOpen > 0.5`.
- Breathing period by arousal: sleeping 4.5 s, idle 3.2 s, thinking 2.8 s,
  toolRunning 2.4 s. Amplitude constant so the tempo carries the mood.
- Mouth: `audio.level` through a 40 ms attack / 90 ms release envelope, plus
  8 percent noise so held vowels still feel alive. The smile and the open
  mouth are separate shapes that swap at `mouthOpen == 0.15` (no crossfade;
  overlapped translucent fills read as a gray plate), so the mouth visibly
  closes back to a smile between words.
- Typing dots cycle at 0.9 s per sweep, the same cadence in every bubble.

Renderer hygiene:

- Minimum visible dwell per phase is 700 ms; faster upstream flips wait
  (INF-271 owns upstream debounce; the renderer still self-protects).
- Reduced motion (`accessibilityReduceMotion`): every spring becomes a 0.25 s
  crossfade; no hop, no vibration, no ripple; dots animate opacity only.
- The animation clock pauses when the window is occluded or hidden; the idle
  blink scheduler must not keep a timer hot between blinks (CPU target: under
  2 percent on Apple Silicon at idle).

## Fleet ring (INF-275, ring form INF-280)

The live companion draws the head anatomy: face, cheeks, mouth, and compact
voice arcs (34/46/58 radii), no limbs and no typing bubbles, so a
bring-your-own pet only ever replaces the character in the middle. The
canonical mark keeps the full anatomy everywhere brand assets render; the
neutral-vs-mark geometry lock guards it unchanged.

Every watched session is one mote on a single ring around the head (center
120,138 after the head drop, radii 68 x 50 in design units). Harness reads
through mote color: Claude Code rust `#D97757` (the official Claude brand
color, including claude-oss sessions running non-Anthropic models), Codex
the mark's blue `#0A84FF` (the official Codex mark is monochrome; no brand
color exists), green reserved for a future open-source harness.

States, per session:

- **Working** orbits the ring, lit, phase advancing 0.55 rad/s with a
  per-session seed so layouts never shuffle.
- **Quiet** stops orbiting and settles into its agent's bottom-arc cluster
  (Claude left of the focus rest spot, Codex right), dimmed to 0.4.
- **Needs-you** (blocked) freezes where it is, turns amber `#FFB020`, shows
  a ? glyph, and pulses its radius on a calm 1.6 s cycle. Never merges.
- **Finished** (turn complete) freezes with a check glyph in its agent hue
  until the session goes active again. Never merges.
- **Focused** wears the theme signature fill, a white halo, and a larger
  radius. It does not orbit: it sits pinned at a stored angle (default
  bottom center, in front of the gaze) and only moves when the user drags
  it along the ring; the angle persists (`attache.petFocusAngle`).
  Focusing another session pins that mote where it currently sits and the
  old one rejoins the ring from the pin.
- **Sub-agents** emit expanding ripple rings from the mote; cadence scales
  with the square root of the count (floor 0.45 s). At most 2 ripplers stay
  individual per agent.

Gaze:

- The eyes rest on the focused mote continuously; dragging it drags the
  gaze along.
- A mote flipping to needs-you or finished steals a 0.9 s glance with an
  expression (worried brows for ?, a warmer cheek glow for a check), then
  the eyes return to the focused stare.
- The hover-follow delight yields to the stare whenever a focused session
  exists.

Depth and crowds:

- Motes on the ring's far half draw behind the arcs and head; the path
  reads as passing around the pet.
- Up to 4 plain working motes per agent orbit individually; more merge into
  one orbiting count badge in the agent hue (numeral capped at 999). More
  than 4 quiet sessions merge into a dim parked badge at the cluster spot.
  Needs-you, finished, and focused motes never merge.
- Membership changes animate: a leaver spawns at the badge and decelerates
  to its spot; a joiner flies into the badge as a short transient.

Interaction:

- Hover shows the session title in a capsule tooltip; hit target is at
  least 13 px regardless of mote size.
- Click focuses that session (same as picking it in ⌘K); clicking a badge
  opens the session switcher. The mini companion window does the same and
  raises the main window for the switcher.
- Dragging the focused mote slides it along the ring (clockwise or counter,
  the hand wins); grabbing anything else is a plain window drag.
- Clicking the pet body is a silent visual reaction (the click squash).
  Audio only ever starts from explicit play controls; the INF-273 status
  line speech on click was removed (2026-07-12 feedback).
- In the main window the pet reserves a constant bottom band (floor 80,
  growing with the caption/composer stack) so the ring is never covered and
  never shifts when the auto-hiding dock wakes under the pointer. Full-bleed
  visualizer modes keep drawing under the controls by design.

Data:

- Sub-agent counts are pending `Task`/`Agent` tool calls in the Claude main
  chain (`SessionAttentionClassifier.assess`); stale sessions report zero.
  Codex transcripts have no sub-agent signal, so Codex motes never ripple.
- `turnComplete` maps to the finished state; erroredRecently stays quiet.
- Reduced motion: no orbit advance, no ripples, no pulse; positions snap.
- Cadence: fleet activity holds the calm-phase frame interval at 1/30 s
  (instead of 1/12 s) only while some mote is non-quiet, and 1/40 s while
  the focused mote is being dragged.

## Degradation and theming

- **Monochrome / menu bar**: the template mark stays a static solid
  silhouette (existing `monochrome` rule in `AttacheMascotMark`); the pet
  never animates there in v1. No state may be encoded in color alone: blocked
  reads through motion (jumping) and shape (brows), so the mapping survives
  monochrome, colorblindness, and dim brightness.
- **Theme accents**: the head, face, cheeks, and bubble hues are brand-fixed
  (they are the logo). The voice arcs take the theme's energy color exactly
  as `EchoformRendererView` tints the idle mark today, and bubble dim/glow
  levels follow the theme's brightness setting. High Contrast raises the dim
  floor for inactive bubbles from 0.35 to 0.5.
- **Light / dark**: geometry identical. In light mode arc and cheek
  opacities gain +0.1 so they hold on a bright canvas (the same trick
  `energyColor` uses), and the figure keeps its soft glow shadow from the
  idle screen so the cream head separates from white backgrounds.

## Legibility floors

- **480 px** (companion window): every row in the state table must be
  distinguishable at a glance. Verified by the rendered pose set.
- **32 px** (menu bar scale): at least sleeping (dark eye band), celebrate
  (hop silhouette), and blockedOnUser (raised bubble) must read. Face detail
  is allowed to vanish; silhouette and bubble position carry the state.
  Verified by the 32 px strip render in `design/pet/`.

## Naming

"Bubbles" is the working name. Candidates proposed on INF-269 (final pick is
Dan's): Bubbles, Envoy, Pip, Echo, Herald. The chosen name should read as the
character's name, not the feature's; the renderer setting stays "Pet" either
way.
