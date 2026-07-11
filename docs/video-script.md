# Promo video

The current promo is fully generated, no screen recording: the `Promo2`
composition in `video/src/epic/` (Remotion). It is live on YouTube at
<https://youtu.be/Y-ATUf63DfQ> and embedded on <https://attache.fm>.

- Scene order and every beat derive from measured narration durations in
  `video/src/epic/manifest2.json`; regenerate audio and the choreography
  follows. Narration is Sekou (ElevenLabs), in-app voices are Titan and
  Jessa, plus Grandpa Spuds Oxley as the cowboy personality example.
- `video/generate-vo2.sh` regenerates audio. `GEN=` limits sections
  (narration, samples, sfx, music) and `ONLY=` limits to named clips so a
  known-good take is never re-rolled by accident. TTS-only respellings:
  "Attashay" and "lyve" keep pronunciation correct; display text keeps real
  spelling.
- Render: `cd video && npm run render2` (low `--concurrency` on this
  machine). The logo is `Mark2` in `video/src/epic/components2.tsx`, same
  geometry as `design/attache-logo.svg`.
- The YouTube thumbnail artwork is `design/youtube-thumb-any-voice.png`
  ("Any voice. Any personality." so the tagline is not repeated twice).

Creative constraints of record: audience skews content creators, never
dev-only; a dramatic pause before the first mention of Attaché; one voice
at a time, never overlapping narration with sample voices; no excluding
phrases; show UI states instead of narrating them.

The original screen-recorded tour script (v0.1.0 era, YouTube G0xXOal4e4U)
is retired; see git history for its shot list.
