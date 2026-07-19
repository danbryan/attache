import React from "react";
import {
  AbsoluteFill, Audio, Sequence, interpolate, spring, staticFile,
  useCurrentFrame, useVideoConfig,
} from "remotion";
import { T } from "../theme";
import { Stage } from "../components";
import {
  Aurora, Particles, LightSweep, RingPulse, Mark2, WordSweep, Shell,
} from "./components2";
import { Hook2, Title2, Pin2, Inbox2 } from "./scenes2a";
import { Ambient2, Live2, TwoWay2 } from "./scenes2b";
import { Personalities2, Brain2, Outro2 } from "./scenes2c";
import {
  SCENES2_LAUNCH, layoutScenes, OVERLAP, f, karaokeEnd, ssec, stext,
  hook, title, pin, inbox, ambient, live, twoway, personalities, brain, outro,
  lineup, voiceBeat,
} from "./timing2";

const clampBoth = { extrapolateLeft: "clamp" as const, extrapolateRight: "clamp" as const };

/* ------------------------------------------------------------------ */
/* NEW BEAT A — the agent lineup: "works with the agents you run".     */
/* Music-carried, on-screen copy only (no narration). Text-only cards, */
/* no third-party logos, dark-with-aurora to match neighboring scenes. */
/* ------------------------------------------------------------------ */

const LINEUP: { name: string; tint: string }[] = [
  { name: "Codex CLI", tint: "#8E8E93" },
  { name: "Claude Code", tint: "#D97757" },
  { name: "Grok Build", tint: "#0A84FF" },
  { name: "opencode", tint: "#30D158" },
];

const AgentCard: React.FC<{ name: string; tint: string; delay: number }> = ({ name, tint, delay }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const p = spring({ frame: frame - delay, fps, config: { damping: 16, mass: 0.82 } });
  return (
    <div
      style={{
        display: "flex", alignItems: "center", gap: 15,
        padding: "24px 32px", borderRadius: 18,
        background: "linear-gradient(160deg, rgba(255,255,255,0.075), rgba(255,255,255,0.028))",
        border: `1px solid rgba(255,255,255,0.14)`,
        boxShadow: "0 32px 74px rgba(0,0,0,0.5), inset 0 1px 0 rgba(255,255,255,0.09)",
        opacity: p, transform: `translateY(${(1 - p) * 48}px) scale(${0.92 + p * 0.08})`,
      }}
    >
      <div style={{ width: 13, height: 13, borderRadius: 7, background: tint, boxShadow: `0 0 15px ${tint}`, flexShrink: 0 }} />
      <span style={{ color: T.text, fontSize: 34, fontWeight: 700, whiteSpace: "nowrap" }}>{name}</span>
    </div>
  );
};

export const AgentLineup: React.FC = () => {
  const frame = useCurrentFrame();
  const headF = f(lineup.headlineAt);
  const cardsF = f(lineup.cardsAt);
  const line2F = f(lineup.line2At);
  const headIn = interpolate(frame, [headF, headF + 16], [0, 1], clampBoth);
  const line2In = interpolate(frame, [line2F, line2F + 16], [0, 1], clampBoth);
  return (
    <Stage>
      <Aurora accent="blue" />
      <Particles count={34} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 52 }}>
        <div
          style={{
            opacity: headIn, transform: `translateY(${(1 - headIn) * 22}px)`,
            fontSize: 62, fontWeight: 700, color: T.text, textAlign: "center",
            letterSpacing: "-0.02em", lineHeight: 1.15, textShadow: "0 8px 60px rgba(0,0,0,0.8)",
          }}
        >
          Works with the agents <span style={{ color: T.gold }}>you already run</span>
        </div>
        <div style={{ display: "flex", gap: 26 }}>
          {LINEUP.map((a, i) => (
            <AgentCard key={a.name} name={a.name} tint={a.tint} delay={cardsF + i * 8} />
          ))}
        </div>
        <div
          style={{
            opacity: line2In, transform: `translateY(${(1 - line2In) * 16}px)`,
            fontSize: 44, fontWeight: 600, color: T.gold,
          }}
        >
          Watch them. <span style={{ color: T.text }}>Reply to them.</span>
        </div>
      </AbsoluteFill>
      <LightSweep start={cardsF} dur={46} opacity={0.06} />
    </Stage>
  );
};

/* ------------------------------------------------------------------ */
/* NEW BEAT B — the bundled voice: "a premium voice, included", runs   */
/* on your Mac. Attaché speaks the Azelma preview with caption-synced   */
/* karaoke while the robot mark (and ring) are present. Music + Azelma  */
/* only; no narration overlaps the in-app voice.                        */
/* ------------------------------------------------------------------ */

export const BundledVoice: React.FC = () => {
  const frame = useCurrentFrame();
  const headF = f(voiceBeat.headlineAt);
  const subF = f(voiceBeat.sublineAt);
  const speakF = f(voiceBeat.speakAt);
  const headIn = interpolate(frame, [headF, headF + 16], [0, 1], clampBoth);
  const subIn = interpolate(frame, [subF, subF + 16], [0, 1], clampBoth);
  const speaking = frame >= speakF && frame < speakF + f(ssec("va_azelma"));
  return (
    <Stage>
      <Aurora accent="violet" strength={0.9} />
      <Particles count={28} />
      <RingPulse at={speakF} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 26 }}>
        <div
          style={{
            opacity: headIn, transform: `translateY(${(1 - headIn) * 22}px)`,
            fontSize: 64, fontWeight: 700, color: T.text, textAlign: "center", letterSpacing: "-0.02em",
            textShadow: "0 8px 60px rgba(0,0,0,0.8)",
          }}
        >
          A premium voice, <span style={{ color: T.gold }}>included</span>
        </div>
        <div style={{ opacity: subIn, fontSize: 34, fontWeight: 600, color: T.dim }}>
          Runs entirely on your Mac
        </div>
        <div style={{ filter: "drop-shadow(0 0 40px rgba(10,132,255,0.42))", marginTop: 6 }}>
          <Mark2 size={264} talking={speaking} buildFrom={headF} />
        </div>
        {frame >= speakF && (
          <div style={{ width: 1140 }}>
            <WordSweep
              text={stext("va_azelma")}
              startFrame={speakF + 2}
              endFrame={speakF + karaokeEnd(ssec("va_azelma"))}
              fontSize={36}
              align="center"
            />
          </div>
        )}
      </AbsoluteFill>
      <LightSweep start={speakF} dur={44} opacity={0.06} />
    </Stage>
  );
};

/* ------------------------------------------------------------------ */
/* PROMO2LAUNCH — the baseline sequence plus the two launch beats.      */
/* Mirrors Promo2's wiring (crossfade, narration, in-app voices, sound  */
/* design, music bed); the two new keys carry no narration.             */
/* ------------------------------------------------------------------ */

const COMPS: Record<string, React.FC> = {
  hook: Hook2, lineup: AgentLineup, title: Title2, pin: Pin2, inbox: Inbox2,
  ambient: Ambient2, personalities: Personalities2, voice: BundledVoice,
  live: Live2, twoway: TwoWay2, brain: Brain2, outro: Outro2,
};

// Narration clip per scene, at that scene's narrStart offset. The two new
// beats (lineup, voice) are intentionally absent: they are music-carried.
const NARRATION: Record<string, { clip: string; at: number }> = {
  hook: { clip: "n_hook", at: f(hook.narrStart) },
  title: { clip: "n_title", at: f(title.narrStart) },
  pin: { clip: "n_pin", at: f(pin.narrStart) },
  inbox: { clip: "n_inbox", at: f(inbox.narrStart) },
  ambient: { clip: "n_ambient", at: f(ambient.narrStart) },
  live: { clip: "n_live", at: f(live.narrStart) },
  personalities: { clip: "n_personalities", at: f(personalities.narrStart) },
  brain: { clip: "n_brain", at: f(brain.narrStart) },
  outro: { clip: "n_outro", at: f(outro.narrStart) },
};

const a2 = (name: string) => staticFile(`audio2/${name}.wav`);

const layout = layoutScenes(SCENES2_LAUNCH);
export const PROMO2_LAUNCH_FRAMES = layout.total;

export const Promo2Launch: React.FC = () => {
  const { starts, frames } = layout;
  const startOf = (key: string) => starts[SCENES2_LAUNCH.findIndex((s) => s.key === key)];
  const pinStart = startOf("pin");
  const inboxStart = startOf("inbox");
  const liveStart = startOf("live");
  const twowayStart = startOf("twoway");
  const persStart = startOf("personalities");
  const brainStart = startOf("brain");
  const voiceStart = startOf("voice");

  // Azelma window (absolute frames), for gently ducking the music under it.
  const azelmaFrom = voiceStart + f(voiceBeat.speakAt);
  const azelmaTo = azelmaFrom + f(ssec("va_azelma"));

  return (
    <AbsoluteFill style={{ backgroundColor: T.bg }}>
      {/* ---- scenes, crossfaded ---- */}
      {SCENES2_LAUNCH.map((s, i) => {
        const Comp = COMPS[s.key];
        return (
          <Sequence key={s.key} from={starts[i]} durationInFrames={frames[i]}>
            <Shell duration={frames[i]} edge={OVERLAP}>
              <Comp />
            </Shell>
          </Sequence>
        );
      })}

      {/* ---- narration ---- */}
      {SCENES2_LAUNCH.map((s, i) => {
        const n = NARRATION[s.key];
        if (!n) return null;
        return (
          <Sequence key={`n-${s.key}`} from={starts[i] + n.at}>
            <Audio src={a2(n.clip)} />
          </Sequence>
        );
      })}
      {/* two-way narration is split around the confirm beat */}
      <Sequence from={twowayStart + f(twoway.aStart)}>
        <Audio src={a2("n_two_a")} />
      </Sequence>
      <Sequence from={twowayStart + f(twoway.bStart)}>
        <Audio src={a2("n_two_b")} />
      </Sequence>

      {/* ---- in-app voices ---- */}
      <Sequence from={inboxStart + f(inbox.memoStart)}>
        <Audio src={a2("va_memo")} />
      </Sequence>
      <Sequence from={liveStart + f(live.speakAt)}>
        <Audio src={a2("va_live")} />
      </Sequence>
      <Sequence from={twowayStart + f(twoway.replySpeakAt)}>
        <Audio src={a2("va_reply")} />
      </Sequence>
      <Sequence from={persStart + f(personalities.editorSpeakAt)}>
        <Audio src={a2("vs_editor")} />
      </Sequence>
      <Sequence from={persStart + f(personalities.cowboySpeakAt)}>
        <Audio src={a2("vs_cowboy")} />
      </Sequence>
      {/* bundled-voice beat: the Azelma preview (from public/, music + voice only) */}
      <Sequence from={azelmaFrom}>
        <Audio src={staticFile("azelma-preview.wav")} />
      </Sequence>

      {/* ---- sound design ---- */}
      {starts.slice(1).map((from, i) => (
        <Sequence key={`whoosh-${i}`} from={from - 4}>
          <Audio src={a2("sfx_whoosh")} volume={0.38} />
        </Sequence>
      ))}
      <Sequence from={startOf("title") + f(title.barsAt)}>
        <Audio src={a2("sfx_hit")} volume={0.8} />
      </Sequence>
      {inbox.cardsAt.map((at, i) => (
        <Sequence key={`pop-${i}`} from={inboxStart + f(at)}>
          <Audio src={a2("sfx_pop")} volume={0.5} />
        </Sequence>
      ))}
      <Sequence from={pinStart + f(pin.pinAt)}>
        <Audio src={a2("sfx_pop")} volume={0.5} />
      </Sequence>
      <Sequence from={twowayStart + f(twoway.chipFlipAt)}>
        <Audio src={a2("sfx_pop")} volume={0.5} />
      </Sequence>
      <Sequence from={twowayStart + f(twoway.confirmAt)}>
        <Audio src={a2("sfx_pop")} volume={0.5} />
      </Sequence>
      <Sequence from={twowayStart + f(twoway.deliveredAt)}>
        <Audio src={a2("sfx_ding")} volume={0.6} />
      </Sequence>
      <Sequence from={brainStart + f(brain.toggleAt)}>
        <Audio src={a2("sfx_pop")} volume={0.5} />
      </Sequence>
      <Sequence from={brainStart + f(brain.fallbackAt)}>
        <Audio src={a2("sfx_pop")} volume={0.5} />
      </Sequence>

      {/* ---- music bed: same fade envelope as Promo2, gently ducked under
             the Azelma preview so the bundled voice reads cleanly ---- */}
      <Audio
        src={a2("music_bed")}
        loop
        volume={(frame) => {
          const env = interpolate(
            frame,
            [0, 40, PROMO2_LAUNCH_FRAMES - 80, PROMO2_LAUNCH_FRAMES - 8],
            [0, 0.4, 0.4, 0],
            clampBoth,
          );
          const duck = interpolate(
            frame,
            [azelmaFrom - 10, azelmaFrom + 6, azelmaTo - 6, azelmaTo + 12],
            [1, 0.55, 0.55, 1],
            clampBoth,
          );
          return env * duck;
        }}
      />
    </AbsoluteFill>
  );
};
