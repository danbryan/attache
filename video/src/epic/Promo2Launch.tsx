import React from "react";
import {
  AbsoluteFill, Audio, Sequence, interpolate, spring, staticFile,
  useCurrentFrame, useVideoConfig,
} from "remotion";
import { T } from "../theme";
import { Stage } from "../components";
import { Aurora, Particles, LightSweep, Shell } from "./components2";
import { Hook2, Title2, Pin2, Inbox2 } from "./scenes2a";
import { Ambient2, Live2, TwoWay2 } from "./scenes2b";
import { Personalities2, Brain2, Outro2 } from "./scenes2c";
import {
  SCENES2_LAUNCH, layoutScenes, OVERLAP, f, ssec,
  hook, title, pin, inbox, ambient, live, personalities, outro,
  lineup, twowayLaunch, brainLaunch,
} from "./timing2";

const clampBoth = { extrapolateLeft: "clamp" as const, extrapolateRight: "clamp" as const };

/* ------------------------------------------------------------------ */
/* BEAT A — the agent lineup: "works with the agents you already run".  */
/* Music-carried, on-screen copy only (no narration). Text-only cards,  */
/* no third-party logos, dark-with-aurora to match neighboring scenes.  */
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
          Watch them. <span style={{ color: T.text }}>Direct them.</span>
        </div>
      </AbsoluteFill>
      <LightSweep start={cardsF} dur={46} opacity={0.06} />
    </Stage>
  );
};

/* ------------------------------------------------------------------ */
/* Launch-specific scene variants. Each keeps Promo2 (baseline)         */
/* untouched by driving the shared scene through an opt-in prop:         */
/*  - Hook2 manager: agent-manager GUI + four CLI terminals              */
/*  - Ambient2 showPicker=false: the "Pick your Attaché" tail is cut     */
/*  - Personalities2 deliveryFraming: "Shape your Attaché" headline      */
/*  - TwoWay2: recut narration timing + conversation headline            */
/*  - Brain2 fourHarnesses: all four watched harnesses with real marks   */
/* ------------------------------------------------------------------ */

const HookLaunch: React.FC = () => <Hook2 manager />;
const AmbientLaunch: React.FC = () => <Ambient2 showPicker={false} />;
const PersonalitiesLaunch: React.FC = () => <Personalities2 deliveryFraming />;
const TwoWayLaunch: React.FC = () => (
  <TwoWay2
    t={twowayLaunch}
    headline="It's not a feed. It's a conversation."
    subline="Answer any update with your agent's next instruction."
    simpleStatus
  />
);
const BrainLaunch: React.FC = () => <Brain2 t={brainLaunch} fourHarnesses />;

/* ------------------------------------------------------------------ */
/* PROMO2LAUNCH — the baseline sequence plus the agent-lineup beat, with */
/* the picker tail and premium-voice beat cut and the two-way + watched- */
/* harness beats running their recut narration.                          */
/* ------------------------------------------------------------------ */

const COMPS: Record<string, React.FC> = {
  hook: HookLaunch, lineup: AgentLineup, title: Title2, pin: Pin2, inbox: Inbox2,
  ambient: AmbientLaunch, personalities: PersonalitiesLaunch,
  live: Live2, twoway: TwoWayLaunch, brain: BrainLaunch, outro: Outro2,
};

// Narration clip per scene, at that scene's narrStart offset. The lineup beat
// is intentionally absent: it is music-carried. Brain runs the recut clip.
const NARRATION: Record<string, { clip: string; at: number }> = {
  hook: { clip: "n_hook", at: f(hook.narrStart) },
  lineup: { clip: "n_lineup", at: f(lineup.narrStart) },
  title: { clip: "n_title", at: f(title.narrStart) },
  pin: { clip: "n_pin", at: f(pin.narrStart) },
  inbox: { clip: "n_inbox", at: f(inbox.narrStart) },
  ambient: { clip: "n_ambient", at: f(ambient.narrStart) },
  live: { clip: "n_live", at: f(live.narrStart) },
  personalities: { clip: "n_personalities", at: f(personalities.narrStart) },
  brain: { clip: "n_brain_launch", at: f(brainLaunch.narrStart) },
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
      {/* two-way narration is split around the confirm beat (recut clips) */}
      <Sequence from={twowayStart + f(twowayLaunch.aStart)}>
        <Audio src={a2("n_two_a_launch")} />
      </Sequence>
      <Sequence from={twowayStart + f(twowayLaunch.bStart)}>
        <Audio src={a2("n_two_b_launch")} />
      </Sequence>

      {/* ---- in-app voices ---- */}
      <Sequence from={inboxStart + f(inbox.memoStart)}>
        <Audio src={a2("va_memo")} />
      </Sequence>
      {/* hinge line — bridges the voicemail demo directly into the
          personalization beat, over the inbox tail / crossfade */}
      <Sequence from={inboxStart + f(inbox.memoStart + ssec("va_memo") + 0.2)}>
        <Audio src={a2("n_hinge")} />
      </Sequence>
      <Sequence from={liveStart + f(live.speakAt)}>
        <Audio src={a2("va_live")} />
      </Sequence>
      <Sequence from={twowayStart + f(twowayLaunch.replySpeakAt)}>
        <Audio src={a2("va_reply")} />
      </Sequence>
      <Sequence from={persStart + f(personalities.editorSpeakAt)}>
        <Audio src={a2("vs_editor")} />
      </Sequence>
      <Sequence from={persStart + f(personalities.cowboySpeakAt)}>
        <Audio src={a2("vs_cowboy")} />
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
      <Sequence from={twowayStart + f(twowayLaunch.chipFlipAt)}>
        <Audio src={a2("sfx_pop")} volume={0.5} />
      </Sequence>
      <Sequence from={twowayStart + f(twowayLaunch.confirmAt)}>
        <Audio src={a2("sfx_pop")} volume={0.5} />
      </Sequence>
      <Sequence from={twowayStart + f(twowayLaunch.deliveredAt)}>
        <Audio src={a2("sfx_flutter")} volume={0.4} />
      </Sequence>
      <Sequence from={brainStart + f(brainLaunch.toggleAt)}>
        <Audio src={a2("sfx_pop")} volume={0.5} />
      </Sequence>
      <Sequence from={brainStart + f(brainLaunch.fallbackAt)}>
        <Audio src={a2("sfx_pop")} volume={0.5} />
      </Sequence>

      {/* ---- music bed: same fade envelope as Promo2 ---- */}
      <Audio
        src={a2("music_bed")}
        loop
        volume={(frame) =>
          interpolate(
            frame,
            [0, 40, PROMO2_LAUNCH_FRAMES - 80, PROMO2_LAUNCH_FRAMES - 8],
            [0, 0.4, 0.4, 0],
            clampBoth,
          )
        }
      />
    </AbsoluteFill>
  );
};
