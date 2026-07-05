import React from "react";
import { AbsoluteFill, Audio, Sequence, staticFile, useCurrentFrame, interpolate } from "remotion";
import { T, FPS } from "../theme";
import { Stage, Rise, Headline, BrandMark, Logo } from "../components";
import { personalitiesTimeline, PRESETS } from "../timing";

const LOCAL_ACCENT = T.gold;

/* 5 — integrations: brains and voices, official marks, local or cloud. */
export const Integrations: React.FC = () => {
  const brain: { label: string; logo: "ollama" | "xai" | "claude" | "openai" }[] = [
    { label: "Ollama", logo: "ollama" },
    { label: "xAI", logo: "xai" },
    { label: "Claude", logo: "claude" },
    { label: "Codex", logo: "openai" },
  ];
  const voice: { label: string; logo: "macos" | "elevenlabs" | "xai" | "openai" }[] = [
    { label: "macOS", logo: "macos" },
    { label: "ElevenLabs", logo: "elevenlabs" },
    { label: "xAI", logo: "xai" },
    { label: "OpenAI", logo: "openai" },
  ];
  return (
    <Stage>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 40 }}>
        <Headline size={60}>Bring your own brain and voice</Headline>
        <div style={{ display: "flex", gap: 34 }}>
          <Rise delay={12}><LogoColumn title="🧠  The brain" items={brain} note="qwen · gpt · llama · glm" /></Rise>
          <Rise delay={22}><LogoColumn title="🔊  The voice" items={voice} note="premium & on-device" /></Rise>
        </div>
        <Rise delay={44}>
          <div style={{ marginTop: 8, padding: "14px 30px", borderRadius: 999, border: `1px solid ${T.gold}`,
            background: "rgba(10,132,255,0.12)", color: T.gold, fontSize: 30, fontWeight: 700 }}>
            Run it fully local. Nothing leaves your Mac.
          </div>
        </Rise>
      </AbsoluteFill>
    </Stage>
  );
};

const LogoColumn: React.FC<{ title: string; items: { label: string; logo: string }[]; note: string }> = ({ title, items, note }) => (
  <div style={{ width: 540, padding: "30px 32px", borderRadius: 24, background: T.bgPanel, border: `1px solid ${T.stroke}` }}>
    <div style={{ color: T.text, fontSize: 30, fontWeight: 700, marginBottom: 22 }}>{title}</div>
    <div style={{ display: "flex", flexWrap: "wrap", gap: 12 }}>
      {items.map((it) => (
        <div key={it.label} style={{ display: "flex", alignItems: "center", gap: 10, padding: "11px 18px",
          borderRadius: 12, background: T.bgRaised, border: `1px solid ${T.stroke}` }}>
          <Logo name={it.logo as never} size={26} />
          <span style={{ color: T.text, fontSize: 25, fontWeight: 600 }}>{it.label}</span>
        </div>
      ))}
    </div>
    <div style={{ color: T.dim, fontSize: 22, marginTop: 20, fontFamily: T.mono }}>{note}</div>
  </div>
);

/* 6 — private vs cloud: two recipes, a toggle sliding between them. */
export const Privacy: React.FC = () => {
  const frame = useCurrentFrame();
  // Sit on Private, slide to Cloud around the midpoint.
  const toCloud = interpolate(frame, [230, 275], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const cloud = toCloud > 0.5;
  return (
    <Stage>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 40 }}>
        <Headline size={58}>Private, or frontier</Headline>
        {/* toggle */}
        <div style={{ position: "relative", width: 360, height: 60, borderRadius: 999, background: T.bgRaised,
          border: `1px solid ${T.stroke}`, display: "flex" }}>
          <div style={{ position: "absolute", top: 5, left: 5, width: 175, height: 50, borderRadius: 999,
            background: cloud ? "rgba(10,132,255,0.18)" : "rgba(10,132,255,0.16)",
            border: `1px solid ${cloud ? T.gold : LOCAL_ACCENT}`,
            transform: `translateX(${toCloud * 175}px)` }} />
          {["🔒 Private", "☁ Cloud"].map((t, i) => (
            <div key={t} style={{ flex: 1, display: "flex", alignItems: "center", justifyContent: "center", zIndex: 1,
              fontSize: 24, fontWeight: 700, color: (i === 0) !== cloud ? T.text : T.dim }}>{t}</div>
          ))}
        </div>
        {/* two recipe cards */}
        <div style={{ display: "flex", gap: 30 }}>
          <RecipeCard accent={LOCAL_ACCENT} on={!cloud} icon="🔒" name="Private"
            rows={[["Voice", "Ava · on-device"], ["Model", "Ollama · GLM-5.2"]]}
            foot="Nothing ever leaves your Mac" />
          <RecipeCard accent={T.gold} on={cloud} icon="☁" name="Cloud"
            rows={[["Voice", "ElevenLabs · xAI"], ["Model", "frontier models"]]}
            foot="For non-sensitive, frontier work" />
        </div>
      </AbsoluteFill>
    </Stage>
  );
};

const RecipeCard: React.FC<{ accent: string; on: boolean; icon: string; name: string; rows: string[][]; foot: string }> = ({ accent, on, icon, name, rows, foot }) => (
  <div style={{ width: 470, padding: "28px 30px", borderRadius: 22, boxSizing: "border-box",
    background: on ? "rgba(255,255,255,0.05)" : T.bgPanel,
    border: `1px solid ${on ? accent : T.stroke}`,
    boxShadow: on ? `0 0 40px ${accent}33` : "none", opacity: on ? 1 : 0.6, transition: "none" }}>
    <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
      <span style={{ fontSize: 30 }}>{icon}</span>
      <span style={{ color: T.text, fontSize: 30, fontWeight: 700 }}>{name}</span>
    </div>
    <div style={{ marginTop: 20, display: "flex", flexDirection: "column", gap: 12 }}>
      {rows.map(([k, v]) => (
        <div key={k} style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline" }}>
          <span style={{ color: T.dim, fontSize: 22, fontFamily: T.mono }}>{k}</span>
          <span style={{ color: T.text, fontSize: 25, fontWeight: 600 }}>{v}</span>
        </div>
      ))}
    </div>
    <div style={{ marginTop: 22, color: on ? accent : T.dim, fontSize: 22, fontWeight: 600 }}>{foot}</div>
  </div>
);

/* 5+6 combined — local vs frontier: one toggle, brains + voices both sides. */
export const LocalFrontier: React.FC = () => {
  const frame = useCurrentFrame();
  const toFrontier = interpolate(frame, [168, 205], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const frontier = toFrontier > 0.5;
  return (
    <Stage>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 42 }}>
        <Headline size={58}>Fully local, or frontier</Headline>
        {/* toggle */}
        <div style={{ position: "relative", width: 380, height: 60, borderRadius: 999, background: T.bgRaised, border: `1px solid ${T.stroke}`, display: "flex" }}>
          <div style={{ position: "absolute", top: 5, left: 5, width: 185, height: 50, borderRadius: 999,
            background: frontier ? "rgba(10,132,255,0.18)" : "rgba(10,132,255,0.16)",
            border: `1px solid ${frontier ? T.gold : LOCAL_ACCENT}`, transform: `translateX(${toFrontier * 185}px)` }} />
          {["🔒 Local", "☁ Frontier"].map((t, i) => (
            <div key={t} style={{ flex: 1, display: "flex", alignItems: "center", justifyContent: "center", zIndex: 1,
              fontSize: 24, fontWeight: 700, color: (i === 0) !== frontier ? T.text : T.dim }}>{t}</div>
          ))}
        </div>
        <div style={{ display: "flex", gap: 30 }}>
          {/* Local */}
          <div style={{ width: 486, minHeight: 232, boxSizing: "border-box", padding: "28px 30px", borderRadius: 22,
            background: !frontier ? "rgba(255,255,255,0.05)" : T.bgPanel, border: `1px solid ${!frontier ? LOCAL_ACCENT : T.stroke}`,
            boxShadow: !frontier ? `0 0 40px ${LOCAL_ACCENT}33` : "none", opacity: !frontier ? 1 : 0.6 }}>
            <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 20 }}>
              <span style={{ fontSize: 28 }}>🔒</span><span style={{ color: T.text, fontSize: 28, fontWeight: 700 }}>Local</span>
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
              <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
                <Logo name="ollama" size={26} /><span style={{ color: T.text, fontSize: 24, fontWeight: 600 }}>Open models</span>
                <span style={{ color: T.dim, fontSize: 20, fontFamily: T.mono }}>qwen · llama · glm</span>
              </div>
              <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
                <Logo name="macos" size={26} /><span style={{ color: T.text, fontSize: 24, fontWeight: 600 }}>On-device voices</span>
              </div>
            </div>
            <div style={{ marginTop: 20, color: !frontier ? LOCAL_ACCENT : T.dim, fontSize: 22, fontWeight: 600 }}>Nothing leaves your Mac</div>
          </div>
          {/* Frontier */}
          <div style={{ width: 486, minHeight: 232, boxSizing: "border-box", padding: "28px 30px", borderRadius: 22,
            background: frontier ? "rgba(255,255,255,0.05)" : T.bgPanel, border: `1px solid ${frontier ? T.gold : T.stroke}`,
            boxShadow: frontier ? `0 0 40px ${T.gold}33` : "none", opacity: frontier ? 1 : 0.6 }}>
            <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 20 }}>
              <span style={{ fontSize: 28 }}>☁</span><span style={{ color: T.text, fontSize: 28, fontWeight: 700 }}>Frontier</span>
            </div>
            <div style={{ display: "flex", gap: 12, flexWrap: "wrap" }}>
              {([["claude", "Claude"], ["openai", "Codex"], ["xai", "xAI"]] as const).map(([lg, label]) => (
                <div key={label} style={{ display: "flex", alignItems: "center", gap: 9, padding: "11px 18px", borderRadius: 12, background: T.bgRaised, border: `1px solid ${T.stroke}` }}>
                  <Logo name={lg} size={24} /><span style={{ color: T.text, fontSize: 23, fontWeight: 600 }}>{label}</span>
                </div>
              ))}
            </div>
            <div style={{ marginTop: 22, color: frontier ? T.gold : T.dim, fontSize: 22, fontWeight: 600 }}>Frontier quality, on tap</div>
          </div>
        </div>
      </AbsoluteFill>
    </Stage>
  );
};

/* 9 — personalities: a quick nod to the presets, then the hero — write your own,
   and Attaché talks like that. Two custom prompts type in and speak the update. */
const CUSTOM_LINES: Record<string, string> = {
  vs_editor: "Five clips, captioned and queued. But clip two's hook is weak. Want me to recut it?",
  vs_hype: "High five on those clips! That's a week of content before lunch. Let's go!",
};

export const Personalities: React.FC = () => {
  const frame = useCurrentFrame();
  const { items } = personalitiesTimeline();
  const active = items.reduce((acc, it) => (frame >= it.typeStart * FPS ? it : acc), items[0]);
  const revealed = Math.max(0, Math.min(1, (frame - active.typeStart * FPS) / (1.1 * FPS)));
  const typed = active.prompt.slice(0, Math.round(revealed * active.prompt.length));
  const speaking = frame >= active.sampleStart * FPS && frame < active.activeEnd * FPS;
  const showResponse = frame >= active.sampleStart * FPS - 4;
  const caret = Math.floor(frame / 14) % 2 === 0;
  return (
    <Stage>
      {items.map((it) => (
        <Sequence key={it.key} from={Math.round(it.sampleStart * FPS)}>
          <Audio src={staticFile(`audio/${it.sample}.wav`)} />
        </Sequence>
      ))}
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 32 }}>
        <Headline size={56}>Or write your own personality</Headline>
        <div style={{ display: "flex", gap: 12, alignItems: "center" }}>
          <span style={{ color: T.dim, fontSize: 22, marginRight: 4 }}>Presets</span>
          {PRESETS.map((p) => (
            <span key={p} style={{ padding: "8px 16px", borderRadius: 999, background: T.bgPanel, border: `1px solid ${T.stroke}`, color: T.dim, fontSize: 22 }}>{p}</span>
          ))}
          <span style={{ color: T.faint, fontSize: 24, margin: "0 4px" }}>or</span>
          <span style={{ padding: "8px 18px", borderRadius: 999, background: T.goldSoft, border: `1px solid ${T.gold}`, color: T.gold, fontSize: 22, fontWeight: 700 }}>+ your own</span>
        </div>
        <div style={{ width: 1060, display: "flex", flexDirection: "column", gap: 18 }}>
          <div style={{ borderRadius: 16, background: T.bgRaised, border: `1px solid ${active.tint}`, boxShadow: `0 0 34px ${active.tint}33`, padding: "22px 26px", display: "flex", alignItems: "center", gap: 14 }}>
            <span style={{ fontSize: 30 }}>{active.emoji}</span>
            <span style={{ color: T.dim, fontSize: 26 }}>Personality:</span>
            <span style={{ color: T.text, fontSize: 28, fontWeight: 600 }}>
              {typed}<span style={{ opacity: caret ? 1 : 0, color: active.tint }}>▍</span>
            </span>
          </div>
          {showResponse && (
            <div style={{ borderRadius: 18, background: T.bgPanel, border: `1px solid ${T.stroke}`, padding: "26px 30px" }}>
              <div style={{ color: active.tint, fontSize: 20, fontWeight: 600, marginBottom: 12 }}>voice · {active.voice}</div>
              <div style={{ color: T.text, fontSize: 31, lineHeight: 1.4 }}>“{CUSTOM_LINES[active.sample]}”</div>
              {speaking && (
                <div style={{ display: "flex", gap: 4, alignItems: "flex-end", height: 24, marginTop: 20 }}>
                  {Array.from({ length: 20 }).map((_, b) => (
                    <div key={b} style={{ width: 4, borderRadius: 3, background: active.tint, height: 6 + 16 * Math.abs(Math.sin(frame / 4 + b)) }} />
                  ))}
                </div>
              )}
            </div>
          )}
        </div>
        <div style={{ color: T.dim, fontSize: 26 }}>Any voice. Any personality. <span style={{ color: T.gold, fontWeight: 600 }}>Even one you invent.</span></div>
      </AbsoluteFill>
    </Stage>
  );
};

/* 13 — live mode: a back-and-forth voice conversation. */
const TURNS: { who: "you" | "a"; at: number; text: string }[] = [
  { who: "you", at: 12, text: "Which tests were still flaky?" },
  { who: "a", at: 70, text: "Two: the payment retry and the S3 upload. Want me to re-run them?" },
  { who: "you", at: 210, text: "Yeah, re-run them, and keep an eye on the error rate." },
  { who: "a", at: 300, text: "On it. I'll speak up the moment either one settles." },
];

export const Live: React.FC = () => {
  const frame = useCurrentFrame();
  return (
    <Stage>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 34 }}>
        <Headline size={60}>Go live</Headline>
        <div style={{ display: "flex", flexDirection: "column", gap: 18, width: 1240, marginTop: 4 }}>
          {TURNS.map((t, i) => {
            if (frame < t.at) return null;
            const enter = interpolate(frame, [t.at, t.at + 18], [26, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
            const op = interpolate(frame, [t.at, t.at + 18], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
            const you = t.who === "you";
            return (
              <div key={i} style={{ alignSelf: you ? "flex-end" : "flex-start", opacity: op, transform: `translateY(${enter}px)` }}>
                <div style={{ display: "flex", alignItems: "center", gap: 14, flexDirection: you ? "row" : "row" }}>
                  {!you && (
                    <div style={{ width: 50, height: 50, borderRadius: 999, background: T.goldSoft, border: `1px solid ${T.gold}`, display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0 }}>
                      <BrandMark size={28} />
                    </div>
                  )}
                  <div style={{ padding: "18px 26px", fontSize: 29, maxWidth: 900,
                    borderRadius: you ? "20px 20px 6px 20px" : "20px 20px 20px 6px",
                    background: you ? T.bgRaised : T.goldSoft,
                    border: `1px solid ${you ? T.stroke : T.gold}`, color: T.text }}>
                    “{t.text}”
                  </div>
                  {you && <div style={{ fontSize: 32, flexShrink: 0 }}>🎙️</div>}
                </div>
              </div>
            );
          })}
        </div>
        <Rise>
          <div style={{ color: T.dim, fontSize: 27, marginTop: 6 }}>ask anything · push direction to your agents · by voice</div>
        </Rise>
      </AbsoluteFill>
    </Stage>
  );
};
