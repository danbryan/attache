# Bubbles brand poses

Marketing stills of the Attaché mascot for the site, README hero, and promo
video. Every image here is rendered from the app's own pose rig, never
hand-drawn:

```bash
swift build
.build/debug/Attache --render-brand-poses design/poses
```

The canonical-geometry rule: the mascot's anatomy is locked to
`design/attache-logo.svg` (2026-07-11) and drawn in code by
`AttacheMascotMark` / `BubblesPetFigure`. The renderer refuses to export if
the rig's neutral pose deviates from the locked mark by even one pixel
channel, so these poses can never drift from the logo. `hero.png` IS the
logo; the other poses are the same geometry with the INF-269 pose parameters
applied (`design/pet-animation-spec.md`). Do not edit these PNGs by hand and
do not add hand-drawn variants; change the rig or the pose catalog
(`BubblesPose.brandCatalog`) and re-render.

Poses: `hero` (the mark at rest), `celebrate` (hop with confetti),
`sleeping`, `thinking` (Claude's bubble lifted), `waving-bubble` (Codex's
bubble raised in greeting). All 2048 px PNG with transparency.

`hero-loop.mp4` / `hero-loop.webm` (alpha) are a seamless 6.4 s idle loop
rendered from the same rig at 30 fps: two breathing cycles, one blink, arcs
pulsing gently. Decision of record for the animated site hero: yes, use this
loop on attache.fm, as rig-rendered video rather than CSS. Re-creating the
mark in hand-written CSS or SVG animation would fork the geometry and break
the lock; a rendered loop keeps the site literally pixel-faithful to the
app. Wiring it into `bryanlabs/bare-metal` (`cluster/apps/attache/`) happens
with the next site update; the ffmpeg assembly is

```bash
.build/debug/Attache --render-brand-poses design/poses
ffmpeg -framerate 30 -i design/poses/hero-loop-frames/frame-%03d.png \
  -c:v libx264 -pix_fmt yuv420p -crf 22 -movflags +faststart design/poses/hero-loop.mp4
```

The app icon and the locked logo do not change. The pet is the logo brought
to life, so the brand needs no second mark.
