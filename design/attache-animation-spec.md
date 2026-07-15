# Attaché character animation and sprite contract

Attaché is the robot head broadcasting under three voice arcs. The live app
places that character inside a two-track fleet ring. Colt implements the same
face contract, and Echo replaces the character with responsive voice bars.

These files are the linked sources of truth:

- `design/attache-logo.svg`: editable vector mark.
- `Sources/AttacheApp/Views/AttacheMascotMark.swift`: static in-app mark.
- `Sources/AttacheApp/Views/AttacheCharacterFigure.swift`: shared character,
  crown, prop, and fleet renderer.
- `Sources/AttacheApp/Views/AttacheCharacterView.swift`: phase choreography
  and motion engine.
- `Sources/AttacheApp/CharacterPoseRenderer.swift`: deterministic pose exports
  and the neutral-pose geometry lock.

The design coordinate system is 240 by 240 units inside a 252 by 252 canvas.
The 12 units of top padding are required because the outer voice arc crests one
unit above the design box. Do not crop a renderer to 240 pixels.

## Brand anatomy

The static mark contains only:

1. three blue voice arcs centered at `(120, 89)`, radii `40`, `66`, and `90`,
2. the antenna from `(120, 82)` to `(120, 73)` with a coral status bulb,
3. a `64 × 60` steel robot plate at `(88, 82)`,
4. a `52 × 34` navy face screen at `(94, 92)`,
5. cyan LED eyes, coral side lights, and a short navy mouth.

The live character uses compact arcs or a phase-specific crown above the head.
Watched sessions are motes on the fleet ring. There are no limbs or separate
agent glyphs in the character anatomy.

## Pose parameters

`AttachePose` is the implementation contract. Ranges below are the sanitized
runtime limits, not suggestions to use every extreme in ordinary motion.

| Parameter | Range | Meaning |
| --- | --- | --- |
| `breathe` | `0...1` | whole-character scale from `1.000` to `1.015` |
| `overhead` | enum | arcs, thinking, tool, preparing audio, paused, sleeping, compacting, configuring, or swarm |
| `overheadPhase` | `0...1` | animation phase for the current crown symbol |
| `overheadSeconds` | `0...` | elapsed counter for tool and audio preparation |
| `overheadCount` | `0...` | live sub-agent count for swarm |
| `headTilt` | `-30...30°` | character head rotation |
| `eyeOpenness` | `-0.2...1.2` | open LED or eyelid amount |
| `gaze` | `±3` units | eye and face focus offset |
| `browWorry` | `0...1` | worried expression blend |
| `dizzy` | `0...1` | normal eyes to error crosses |
| `mouthOpen` | `0...1` | audio-driven speaking shape |
| `smile` | `0...1.2` | resting mouth width and warmth |
| `cheekGlow` | `0...1` | status-light and cheek intensity; `0.6` is neutral |
| `hop` | `-12...26` units | vertical one-shot movement |
| `squash` | `-1...1` | ordinary squash and stretch |
| `compaction` | `0...1` | dedicated context-compaction flatten and widen |
| `sway` | `-10...10°` | speaking rock |
| `arcGlow` | `0...1` | voice-arc opacity multiplier |
| `arcRipple` | `-1.5...1.5` | inward or outward arc ripple |
| `arcPhase` | finite double | ripple phase |
| `agentSignals[*].pop` | `0...1` | agent-colored celebration confetti progress |
| `props` | array | temporary emoji or permission flag beside any character |

The other `agentSignals` fields remain an internal transition channel for
activity flavor. They are not part of the character silhouette or custom-sprite
contract. Persistent agent and session state belongs to fleet motes.

## Activity mapping

| Phase | Face and body | Crown | Fleet behavior |
| --- | --- | --- | --- |
| `sleeping` | closed eyes, slow 4.5 s breathe | sequenced z symbols | quiet motes parked |
| `idle` | soft blink, 3.2 s breathe | empty | focused mote pinned, quiet motes parked |
| `agentThinking` | gaze and slight tilt toward active agent | animated brain | working mote orbits |
| `toolRunning` | focused eyes | gear plus elapsed seconds | working mote orbits |
| `agentResponding` | wider eyes, inward arc energy | preparing-audio clock when needed | focused and working states remain visible |
| `speaking` | mouth follows analyzed audio, gentle sway | compact voice arcs | fleet stays interactive |
| `paused` | held small mouth | pause bars | fleet stops advancing with reduced motion |
| `blockedOnUser` | worried brows and pale cheeks | empty | amber outer-track mote with `?` pulses |
| `error` | crossed eyes and small mouth | empty | affected session remains identifiable |
| `compacting` | dedicated flatten-and-widen motion | compression symbol | fleet continues to show all sessions |

Celebrate is a 1.2 second one-shot layered over the next safe continuous phase:
a hop, squash-and-stretch landing, warmer status lights, arc ripple, and
agent-colored confetti. Permission, greeting, and farewell moments use `props`
so every character can express them without character-specific limbs.

## Motion rules

Use the shared spring vocabulary in `AttacheCharacterMotor`:

- standard: response `0.35`, damping `0.78`;
- snappy: response `0.22`, damping `0.70`;
- soft: response `0.60`, damping `0.90`.

Blink every 4 to 7 seconds with a 120 ms close, 90 ms hold, and 140 ms open.
Fifteen percent may double blink. Suppress blinking during strong speech.
Breathing periods are 4.5 seconds asleep, 3.2 idle, 2.8 thinking, and 2.4 during
tools. Speaking uses a fast attack and slower release envelope over analyzed
audio energy so the mouth closes visibly between words.

With Reduce Motion enabled, remove orbit advance, hops, vibration, ripples, and
pulses. Use short crossfades and snapped fleet positions. Pause the animation
clock while its window is hidden or occluded.

## Fleet ring

The ring is centered at `(120, 138)` after the live head drop. Ordinary working
and quiet motes use the inner track at radius `52`. Focused, needs-you, and
finished motes use the outer track at radius `78`. The crown reserves the outer
track sector from `-128°` through `-52°`; dragging clamps outside that zone.

- Claude sessions are rust `#D97757`.
- Codex sessions are Attaché blue `#0A84FF`.
- Other agents are green `#10A37F`.
- Needs-you is amber `#FFB020` with a question glyph.
- Finished uses a check glyph in the agent hue.
- Focused uses white on dark surfaces and near-black on light surfaces.

Working motes orbit at `0.55 rad/s`. Quiet motes park in agent clusters. The
focused mote defaults to bottom center and can be dragged around the outer
track. The character gaze follows it. A newly blocked or finished mote receives
a 0.9 second glance, then focus returns. Large quiet or working groups merge into
count badges; focused, needs-you, and finished motes never merge.

Hover reveals the session title. Click focuses that session. Drag moves the
focused mote. Clicking the character is a silent visual reaction. Audio begins
only from an explicit play control or an active live session.

## Built-in presence contract

The wardrobe has exactly three built-in presences:

- **Attaché**: the brand robot. LED eyes implement openness, worry, gaze, and
  error. The mouth is an equalizer driven by `mouthOpen`.
- **Colt**: the cowboy. Round eyes and pupils implement the same expression
  fields. His hat, mustache, and neckerchief supply the silhouette.
- **Echo**: responsive voice bars in the same compact footprint. Double-click
  expands Echo to the full-window visualizer.

Every character must express `eyeOpenness`, `gaze`, `dizzy`, `browWorry`,
`mouthOpen`, `smile`, and `cheekGlow`, and accept the shared head transform.
The outer rig supplies breathing, hop, squash, sway, crown, props, confetti,
fleet interaction, and reduced-motion behavior.

## Bring your own sprite

Custom artwork is a documented extension point, not a shipping import feature
yet. A future package will be a directory named
`<character>.attache-character`:

```text
manifest.json
sprites/
  neutral.png
  blink.png
  speaking.png
  worried.png
  error.png
```

Each PNG uses a transparent 252 by 252 canvas, keeps its silhouette inside the
central 240-unit box, and leaves the top safe area clear for the shared crown.
The manifest will name the character, format version, and five relative paths.
Packages will live in `~/Library/Application Support/Attache/Characters/` once
the loader ships.

Suggested authoring prompt: "Use Attaché's custom character template to make a
transparent 252 by 252 sprite set for [description]. Preserve every filename,
canvas size, safe area, and pose meaning exactly." Review the five frames as a
set. The neutral silhouette must not jump, and every frame must leave the crown
and fleet ring readable.

## Verification

`Attache --render-character-poses [dir]` exports the phase catalog and a 32 px
legibility strip. `Attache --render-brand-poses [dir]` exports marketing poses
and idle-loop frames. Both commands first compare the neutral
`AttacheCharacterFigure` against `AttacheMascotMark` and fail on any pixel
channel difference. Generated PNGs are outputs, never hand-edited sources.
