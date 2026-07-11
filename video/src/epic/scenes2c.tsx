import React from "react";
import { AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { T } from "../theme";
import { Stage, BrandMark, Capsule, Logo } from "../components";
import {
  Aurora, Particles, LightSweep, WaveBars, WordSweep, SourceChip, typed as typeSlice,
} from "./components2";
import { personalities, brain, outro, f, karaokeEnd, ssec, stext } from "./timing2";

/* ------------------------------------------------------------------ */
/* 8 — PERSONALITIES: presets, then write your own and hear it.        */
/* ------------------------------------------------------------------ */

const PRESETS = ["Explainer", "Big Picture", "Inquisitive"] as const;
const CUSTOMS = [
  { key: "editor", prompt: "a sharp editor with strong opinions", emoji: "🎬", voice: "Jessa", sample: "vs_editor" as const, tint: "#0A84FF" },
  { key: "hype", prompt: "an over-caffeinated hype coach", emoji: "🔥", voice: "Titan", sample: "vs_hype" as const, tint: "#FF9F0A" },
];

export const Personalities2: React.FC = () => {
  const frame = useCurrentFrame();
  const typeDurF = f(personalities.typeDur);
  const beats = [
    { ...CUSTOMS[0], typeF: f(personalities.editorTypeAt), speakF: f(personalities.editorSpeakAt) },
    { ...CUSTOMS[1], typeF: f(personalities.hypeTypeAt), speakF: f(personalities.hypeSpeakAt) },
  ];
  const active = frame >= beats[1].typeF ? beats[1] : beats[0];
  const typedPrompt = frame >= active.typeF ? typeSlice(active.prompt, frame, active.typeF, typeDurF) : "";
  const speakEndF = active.speakF + f(ssec(active.sample));
  const speaking = frame >= active.speakF && frame < speakEndF;
  const showResponse = frame >= active.speakF - 5;
  const caret = Math.floor(frame / 14) % 2 === 0;
  const promptVisible = frame >= beats[0].typeF;
  return (
    <Stage>
      <Aurora accent="violet" strength={0.9} />
      <Particles count={30} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 30 }}>
        <div style={{ fontSize: 58, fontWeight: 700, color: T.text, letterSpacing: "-0.02em" }}>
          It talks <span style={{ color: T.gold }}>your way</span>
        </div>
        <div style={{ display: "flex", gap: 12, alignItems: "center", opacity: interpolate(frame, [f(personalities.presetsAt), f(personalities.presetsAt) + 14], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" }) }}>
          <span style={{ color: T.dim, fontSize: 22, marginRight: 4 }}>Presets</span>
          {PRESETS.map((p) => (
            <span key={p} style={{ padding: "8px 16px", borderRadius: 999, background: T.bgPanel, border: `1px solid ${T.stroke}`, color: T.dim, fontSize: 22 }}>{p}</span>
          ))}
          <span style={{ color: T.faint, fontSize: 24, margin: "0 4px" }}>or</span>
          <span style={{ padding: "8px 18px", borderRadius: 999, background: T.goldSoft, border: `1px solid ${T.gold}`, color: T.gold, fontSize: 22, fontWeight: 700 }}>+ your own</span>
        </div>
        <div style={{ width: 1080, display: "flex", flexDirection: "column", gap: 18, minHeight: 300 }}>
          {promptVisible && (
            <div style={{ borderRadius: 16, background: T.bgRaised, border: `1px solid ${active.tint}`, boxShadow: `0 0 34px ${active.tint}33`, padding: "22px 26px", display: "flex", alignItems: "center", gap: 14 }}>
              <span style={{ fontSize: 30 }}>{active.emoji}</span>
              <span style={{ color: T.dim, fontSize: 26 }}>Personality:</span>
              <span style={{ color: T.text, fontSize: 28, fontWeight: 600 }}>
                {typedPrompt}<span style={{ opacity: caret ? 1 : 0, color: active.tint }}>▍</span>
              </span>
            </div>
          )}
          {showResponse && (
            <div style={{ borderRadius: 18, background: T.bgPanel, border: `1px solid ${T.stroke}`, padding: "26px 30px" }}>
              <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 12 }}>
                <span style={{ color: active.tint, fontSize: 20, fontWeight: 600 }}>voice · {active.voice}</span>
                {speaking && <div style={{ marginLeft: "auto" }}><WaveBars n={14} height={20} barWidth={4} color={active.tint} /></div>}
              </div>
              <WordSweep
                text={stext(active.sample)}
                startFrame={active.speakF + 2}
                endFrame={active.speakF + karaokeEnd(ssec(active.sample))}
                fontSize={28}
              />
            </div>
          )}
        </div>
      </AbsoluteFill>
      <LightSweep start={beats[0].typeF} dur={46} opacity={0.06} />
    </Stage>
  );
};

/* ------------------------------------------------------------------ */
/* 9 — ITS OWN BRAIN: watches your agents, thinks for itself,          */
/*     local or frontier, with a visible fallback.                     */
/* ------------------------------------------------------------------ */

export const Brain2: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const watchF = f(brain.watchAt);
  const brainF = f(brain.brainAt);
  const toggleF = f(brain.toggleAt);
  const fallbackF = f(brain.fallbackAt);

  const watchP = spring({ frame: frame - watchF, fps, config: { damping: 16, mass: 0.8 } });
  const brainP = spring({ frame: frame - brainF, fps, config: { damping: 16, mass: 0.8 } });
  const toFrontier = interpolate(frame, [toggleF, toggleF + 24], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const frontier = toFrontier > 0.5;
  const bannerIn = spring({ frame: frame - fallbackF, fps, config: { damping: 15, mass: 0.8 } });
  const fallbackOn = frame >= fallbackF;
  const fallbackSettled = frame >= fallbackF + 34;

  return (
    <Stage>
      <Aurora accent="teal" strength={0.9} />
      <Particles count={30} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 30 }}>
        {/* watched agents */}
        <div style={{ display: "flex", alignItems: "center", gap: 16, opacity: watchP, transform: `translateY(${(1 - watchP) * 26}px)` }}>
          <span style={{ color: T.dim, fontSize: 24, fontWeight: 600 }}>Watches your agents</span>
          {([["claude", "Claude Code"], ["openai", "Codex"]] as const).map(([lg, label]) => (
            <div key={label} style={{ display: "flex", alignItems: "center", gap: 10, padding: "10px 18px", borderRadius: 12, background: T.bgRaised, border: `1px solid ${T.stroke}` }}>
              <Logo name={lg} size={24} />
              <span style={{ color: T.text, fontSize: 23, fontWeight: 600 }}>{label}</span>
            </div>
          ))}
        </div>

        <div style={{ color: T.faint, fontSize: 30, opacity: brainP }}>·</div>

        {/* its own brain */}
        <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 22, opacity: brainP, transform: `translateY(${(1 - brainP) * 26}px)` }}>
          <div style={{ fontSize: 52, fontWeight: 700, color: T.text, letterSpacing: "-0.02em" }}>
            But it brings <span style={{ color: T.gold }}>its own brain</span>
          </div>
          {/* toggle */}
          <div style={{ position: "relative", width: 380, height: 58, borderRadius: 999, background: T.bgRaised, border: `1px solid ${T.stroke}`, display: "flex" }}>
            <div style={{ position: "absolute", top: 5, left: 5, width: 185, height: 48, borderRadius: 999, background: "rgba(10,132,255,0.17)", border: `1px solid ${T.gold}`, transform: `translateX(${toFrontier * 185}px)` }} />
            {["🔒 Local", "☁ Frontier"].map((t, i) => (
              <div key={t} style={{ flex: 1, display: "flex", alignItems: "center", justifyContent: "center", zIndex: 1, fontSize: 23, fontWeight: 700, color: (i === 0) !== frontier ? T.text : T.dim }}>{t}</div>
            ))}
          </div>
          <div style={{ display: "flex", gap: 26 }}>
            {/* local */}
            <div style={{ width: 470, boxSizing: "border-box", padding: "24px 28px", borderRadius: 20, background: !frontier ? "rgba(255,255,255,0.05)" : T.bgPanel, border: `1px solid ${!frontier ? T.gold : T.stroke}`, boxShadow: !frontier ? `0 0 40px ${T.gold}33` : "none", opacity: !frontier ? 1 : 0.6 }}>
              <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 14 }}>
                <Logo name="ollama" size={26} />
                <span style={{ color: T.text, fontSize: 25, fontWeight: 700 }}>Open models, on-device voices</span>
              </div>
              <div style={{ color: !frontier ? T.gold : T.dim, fontSize: 21, fontWeight: 600 }}>Nothing ever leaves your Mac</div>
            </div>
            {/* frontier */}
            <div style={{ width: 470, boxSizing: "border-box", padding: "24px 28px", borderRadius: 20, background: frontier ? "rgba(255,255,255,0.05)" : T.bgPanel, border: `1px solid ${frontier ? T.gold : T.stroke}`, boxShadow: frontier ? `0 0 40px ${T.gold}33` : "none", opacity: frontier ? 1 : 0.6 }}>
              <div style={{ display: "flex", gap: 10, flexWrap: "wrap", marginBottom: 14 }}>
                {([["xai", "Grok"], ["claude", "Claude"], ["openai", "GPT"]] as const).map(([lg, label]) => (
                  <div key={label} style={{ display: "flex", alignItems: "center", gap: 8, padding: "8px 14px", borderRadius: 10, background: T.bgRaised, border: `1px solid ${T.stroke}` }}>
                    <Logo name={lg} size={20} />
                    <span style={{ color: T.text, fontSize: 20, fontWeight: 600 }}>{label}</span>
                  </div>
                ))}
              </div>
              <div style={{ color: frontier ? T.gold : T.dim, fontSize: 21, fontWeight: 600 }}>Or the subscriptions you already pay for</div>
            </div>
          </div>
        </div>

        {/* fallback banner */}
        {fallbackOn && (
          <div
            style={{
              display: "flex", alignItems: "center", gap: 16, padding: "16px 26px", borderRadius: 16,
              background: "rgba(255,159,10,0.09)", border: "1px solid rgba(255,159,10,0.5)",
              opacity: bannerIn, transform: `translateY(${(1 - bannerIn) * 30}px)`,
            }}
          >
            <span style={{ color: "#FF9F0A", fontSize: 22, fontWeight: 700 }}>Grok: out of credits</span>
            <span style={{ color: T.faint, fontSize: 22 }}>→</span>
            <span style={{ color: fallbackSettled ? "#30D158" : T.text, fontSize: 22, fontWeight: 700 }}>
              {fallbackSettled ? "Continuing on Ollama (local)" : "Falling back to Ollama…"}
            </span>
            <span style={{ marginLeft: 10, padding: "5px 14px", borderRadius: 999, background: "rgba(255,255,255,0.06)", border: `1px solid ${T.stroke}`, color: T.dim, fontSize: 18, fontWeight: 600 }}>
              Settings → Model → Fallbacks
            </span>
          </div>
        )}
      </AbsoluteFill>
      <LightSweep start={toggleF} dur={44} opacity={0.06} />
    </Stage>
  );
};

/* ------------------------------------------------------------------ */
/* 10 — OUTRO: rays, the mark, the new tagline, where to get it.       */
/* ------------------------------------------------------------------ */

export const Outro2: React.FC = () => {
  const frame = useCurrentFrame();
  const breathe = 0.94 + 0.05 * Math.sin(frame / 20);
  const raysIn = interpolate(frame, [0, 40], [0, 0.5], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return (
    <Stage>
      <Aurora accent="blue" />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", opacity: raysIn }}>
        <div
          style={{
            width: 1700, height: 1700, borderRadius: 999,
            background: `conic-gradient(from ${frame * 0.12}deg, transparent 0deg, rgba(10,132,255,0.05) 12deg, transparent 26deg, transparent 60deg, rgba(122,92,255,0.05) 74deg, transparent 90deg, transparent 130deg, rgba(10,132,255,0.05) 145deg, transparent 160deg, transparent 210deg, rgba(0,199,190,0.045) 226deg, transparent 245deg, transparent 300deg, rgba(10,132,255,0.05) 315deg, transparent 330deg)`,
            maskImage: "radial-gradient(circle, black 0%, transparent 62%)",
            WebkitMaskImage: "radial-gradient(circle, black 0%, transparent 62%)",
          }}
        />
      </AbsoluteFill>
      <Particles count={44} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 42 }}>
        <div style={{ transform: `scale(${breathe})` }}>
          <BrandMark size={250} animate barColor={(i) => `rgba(10,132,255,${0.4 + 0.05 * i})`} />
        </div>
        <div style={{ fontSize: 70, fontWeight: 700, color: T.text, letterSpacing: "-0.02em", textAlign: "center" }}>
          Give your agents <span style={{ color: T.gold }}>a voice.</span>
        </div>
        <div style={{ display: "flex", gap: 18, alignItems: "center" }}>
          <Capsule active fontSize={30}>attache.fm</Capsule>
          <Capsule fontSize={30}>github.com/danbryan/attache</Capsule>
        </div>
        <div style={{ color: T.faint, fontSize: 24, fontFamily: T.mono }}>brew install danbryan/tap/attache</div>
      </AbsoluteFill>
      <LightSweep start={30} dur={60} opacity={0.06} />
    </Stage>
  );
};
