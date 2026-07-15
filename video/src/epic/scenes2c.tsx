import React from "react";
import { AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { T } from "../theme";
import { Stage, Capsule, Logo } from "../components";
import {
  Aurora, Particles, LightSweep, WaveBars, WordSweep, Mark2, typed as typeSlice,
} from "./components2";
import { Colt2 } from "./scenes2b";
import { personalities, brain, outro, f, karaokeEnd, ssec, stext } from "./timing2";

/* ------------------------------------------------------------------ */
/* 8: CHARACTER STUDIO. A game-style loadout joins presence,          */
/* personality, voice, model, and reasoning, then auditions the whole */
/* character with one Preview button.                                 */
/* ------------------------------------------------------------------ */

const WARDROBE = [
  { key: "attache", title: "Attaché", detail: "Robot" },
  { key: "colt", title: "Colt", detail: "Cowboy" },
  { key: "echo", title: "Echo", detail: "Voice bars" },
] as const;

const LOADOUTS = [
  {
    key: "editor",
    name: "The Editor",
    wardrobe: "attache" as const,
    prompt: "a sharp editor with strong opinions",
    voice: "Jessa",
    model: "Grok 4.3",
    reasoning: "Medium",
    sample: "vs_editor" as const,
    tint: "#0A84FF",
  },
  {
    key: "cowboy",
    name: "Colt",
    wardrobe: "colt" as const,
    prompt: "an old trail boss with a level voice",
    voice: "Grandpa Spuds",
    model: "qwen3:7b",
    reasoning: "High",
    sample: "vs_cowboy" as const,
    tint: "#FF9F0A",
  },
];

const WardrobeFace: React.FC<{ kind: "attache" | "colt" | "echo"; size: number; talking?: boolean }> = ({ kind, size, talking = false }) => {
  if (kind === "attache") return <Mark2 size={size} talking={talking} />;
  if (kind === "echo") return <WaveBars n={11} height={size * 0.52} barWidth={Math.max(5, size * 0.038)} color="#A75FFF" />;
  return (
    <div style={{ filter: talking ? "drop-shadow(0 0 20px rgba(255,159,10,0.55))" : undefined }}>
      <Colt2 size={size} />
    </div>
  );
};

const LoadoutSlot: React.FC<{ icon: string; label: string; value: string; tint: string; delay: number }> = ({ icon, label, value, tint, delay }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const p = spring({ frame: frame - delay, fps, config: { damping: 17, mass: 0.72 } });
  return (
    <div
      style={{
        display: "flex", alignItems: "center", gap: 11,
        padding: "10px 13px", borderRadius: 12,
        background: "rgba(255,255,255,0.04)", border: `1px solid ${T.stroke}`,
        opacity: p, transform: `translateX(${(1 - p) * 28}px)`,
      }}
    >
      <span style={{ fontSize: 20 }}>{icon}</span>
      <div style={{ minWidth: 70, color: T.faint, fontSize: 15, fontWeight: 700, letterSpacing: "0.08em" }}>{label}</div>
      <div style={{ color: tint, fontSize: 19, fontWeight: 700, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{value}</div>
    </div>
  );
};

export const Personalities2: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const typeDurF = f(personalities.typeDur);
  const beats = [
    { ...LOADOUTS[0], typeF: f(personalities.editorTypeAt), speakF: f(personalities.editorSpeakAt) },
    { ...LOADOUTS[1], typeF: f(personalities.cowboyTypeAt), speakF: f(personalities.cowboySpeakAt) },
  ];
  const active = frame >= beats[1].typeF ? beats[1] : beats[0];
  const typedPrompt = frame >= active.typeF ? typeSlice(active.prompt, frame, active.typeF, typeDurF) : "";
  const speakEndF = active.speakF + f(ssec(active.sample));
  const speaking = frame >= active.speakF && frame < speakEndF;
  const showResponse = frame >= active.speakF - 8;
  const caret = Math.floor(frame / 14) % 2 === 0;
  const panelP = spring({ frame: frame - f(personalities.presetsAt), fps, config: { damping: 17, mass: 0.9 } });
  const swap = spring({ frame: frame - beats[1].typeF, fps, config: { damping: 13, mass: 0.7 } });
  const selectedIndex = WARDROBE.findIndex((item) => item.key === active.wardrobe);
  return (
    <Stage>
      <Aurora accent="violet" strength={0.9} />
      <Particles count={30} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 22 }}>
        <div style={{ textAlign: "center" }}>
          <div style={{ fontSize: 52, fontWeight: 750, color: T.text, letterSpacing: "-0.025em" }}>
            Build the character <span style={{ color: T.gold }}>you want to hear</span>
          </div>
          <div style={{ marginTop: 7, color: T.dim, fontSize: 21 }}>One loadout. Presence, personality, voice, and brain.</div>
        </div>

        <div
          style={{
            width: 1320, height: 660, display: "grid", gridTemplateColumns: "390px 1fr",
            borderRadius: 28, overflow: "hidden", background: "rgba(15,16,23,0.95)",
            border: `1px solid ${active.tint}66`, boxShadow: `0 28px 90px rgba(0,0,0,0.55), 0 0 54px ${active.tint}1f`,
            opacity: panelP, transform: `translateY(${(1 - panelP) * 34}px) scale(${0.97 + panelP * 0.03})`,
          }}
        >
          <div style={{ position: "relative", padding: "30px 28px", background: `linear-gradient(160deg, ${active.tint}22, rgba(10,10,15,0.96) 72%)`, borderRight: `1px solid ${T.stroke}` }}>
            <div style={{ color: T.faint, fontSize: 16, fontWeight: 800, letterSpacing: "0.12em" }}>AUDITION STAGE</div>
            <div style={{ height: 290, display: "flex", alignItems: "center", justifyContent: "center", transform: `scale(${1 + 0.025 * Math.sin(frame / 17)}) rotate(${active.key === "cowboy" ? (1 - swap) * -4 : 0}deg)` }}>
              <WardrobeFace kind={active.wardrobe} size={220} talking={speaking} />
            </div>
            <div style={{ textAlign: "center", color: T.text, fontSize: 30, fontWeight: 750 }}>{active.name}</div>
            <div style={{ textAlign: "center", color: T.dim, fontSize: 18, marginTop: 5 }}>{WARDROBE[selectedIndex].title} · {active.voice}</div>
            <div
              style={{
                marginTop: 24, height: 48, borderRadius: 12, display: "flex", alignItems: "center", justifyContent: "center", gap: 10,
                background: speaking ? active.tint : "#0A84FF", color: "white", fontSize: 19, fontWeight: 750,
                boxShadow: speaking ? `0 0 36px ${active.tint}88` : "0 8px 24px rgba(10,132,255,0.25)",
                transform: speaking ? "scale(0.98)" : "none",
              }}
            >
              <span>{speaking ? "▮▮" : "▶"}</span>
              <span>{speaking ? "Previewing personality" : "Preview personality"}</span>
            </div>
            <div style={{ color: T.faint, textAlign: "center", fontSize: 14, marginTop: 12 }}>Preview is the only automatic greeting.</div>
          </div>

          <div style={{ padding: "24px 28px", display: "flex", flexDirection: "column", gap: 15 }}>
            <div style={{ display: "flex", alignItems: "center" }}>
              <div>
                <div style={{ color: T.text, fontSize: 27, fontWeight: 750 }}>Create a character</div>
                <div style={{ color: T.dim, fontSize: 16 }}>Choose a preset, then make every slot yours.</div>
              </div>
              <div style={{ marginLeft: "auto", color: T.gold, fontSize: 15, fontWeight: 800, letterSpacing: "0.08em" }}>CHARACTER LOADOUT</div>
            </div>

            <div>
              <div style={{ color: T.faint, fontSize: 14, fontWeight: 800, letterSpacing: "0.09em", marginBottom: 8 }}>WARDROBE</div>
              <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: 9 }}>
                {WARDROBE.map((item) => {
                  const chosen = item.key === active.wardrobe;
                  return (
                    <div key={item.key} style={{ height: 94, borderRadius: 12, display: "flex", alignItems: "center", gap: 10, padding: "0 13px", background: chosen ? `${active.tint}1f` : T.bgRaised, border: `1px solid ${chosen ? active.tint : T.stroke}`, boxShadow: chosen ? `0 0 22px ${active.tint}2f` : "none" }}>
                      <WardrobeFace kind={item.key} size={54} />
                      <div>
                        <div style={{ color: chosen ? active.tint : T.text, fontSize: 18, fontWeight: 750 }}>{item.title}</div>
                        <div style={{ color: T.faint, fontSize: 14 }}>{item.detail}</div>
                      </div>
                    </div>
                  );
                })}
              </div>
            </div>

            <div style={{ borderRadius: 13, background: T.bgRaised, border: `1px solid ${T.stroke}`, padding: "14px 16px" }}>
              <div style={{ display: "flex", alignItems: "center", marginBottom: 8 }}>
                <span style={{ color: T.faint, fontSize: 14, fontWeight: 800, letterSpacing: "0.09em" }}>PERSONALITY</span>
                <span style={{ marginLeft: "auto", color: active.tint, fontSize: 14, fontWeight: 700 }}>Write your own</span>
              </div>
              <div style={{ color: T.text, fontSize: 21, fontWeight: 600, minHeight: 28 }}>
                {typedPrompt}<span style={{ opacity: caret ? 1 : 0, color: active.tint }}>▍</span>
              </div>
            </div>

            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
              <LoadoutSlot icon="◉" label="VOICE" value={active.voice} tint={active.tint} delay={f(personalities.presetsAt) + 8} />
              <LoadoutSlot icon="◆" label="MODEL" value={active.model} tint={active.tint} delay={f(personalities.presetsAt) + 14} />
              <LoadoutSlot icon="◌" label="PACE" value="1.0x" tint={active.tint} delay={f(personalities.presetsAt) + 20} />
              <LoadoutSlot icon="✦" label="REASON" value={active.reasoning} tint={active.tint} delay={f(personalities.presetsAt) + 26} />
            </div>

          {showResponse && (
            <div style={{ borderRadius: 13, background: `${active.tint}10`, border: `1px solid ${active.tint}66`, padding: "13px 16px" }}>
              <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 7 }}>
                <span style={{ color: active.tint, fontSize: 16, fontWeight: 750 }}>{active.name} · {active.voice}</span>
                {speaking && <div style={{ marginLeft: "auto" }}><WaveBars n={14} height={20} barWidth={4} color={active.tint} /></div>}
              </div>
              <WordSweep
                text={stext(active.sample)}
                startFrame={active.speakF + 2}
                endFrame={active.speakF + karaokeEnd(ssec(active.sample))}
                fontSize={20}
              />
            </div>
          )}
          </div>
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
              <div style={{ color: frontier ? T.gold : T.dim, fontSize: 21, fontWeight: 600 }}>Frontier quality, on tap</div>
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
              Character Studio → Fallbacks
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
          <Mark2 size={290} talking />
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
