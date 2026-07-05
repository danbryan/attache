import React from "react";
import { AbsoluteFill, Img, staticFile, useCurrentFrame, useVideoConfig, interpolate } from "remotion";
import { T } from "../theme";
import { Stage, Rise, Headline, MacWindow, KeyCap, BrandMark, Capsule } from "../components";

/* 1 — hook: a terminal grinding away, then the reframe. */
export const Hook: React.FC = () => {
  const frame = useCurrentFrame();
  const lines = [
    "▸ Running tests (147/211)…",
    "▸ Refactoring the export module…",
    "▸ Retrying flaky integration case…",
    "▸ Building… this may take a while",
    "▸ Reading 43 files…",
  ];
  const visible = Math.min(lines.length, Math.floor(frame / 14) + 1);
  return (
    <Stage>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 60 }}>
        <MacWindow width={980} style={{ opacity: 0.85 }}>
          <div style={{ padding: "26px 32px 34px", fontFamily: T.mono, fontSize: 26, color: T.dim, minHeight: 250 }}>
            {lines.slice(0, visible).map((l, i) => (
              <div key={i} style={{ marginBottom: 12, opacity: i === visible - 1 ? 1 : 0.45 }}>
                {l}
                {i === visible - 1 && Math.floor(frame / 12) % 2 === 0 ? " ▍" : ""}
              </div>
            ))}
          </div>
        </MacWindow>
        <Headline delay={62} size={72}>
          Let it <span style={{ color: T.gold }}>come to you.</span>
        </Headline>
      </AbsoluteFill>
    </Stage>
  );
};

/* 2 — intro: the real idle window, name, tagline. */
export const Intro: React.FC = () => {
  const frame = useCurrentFrame();
  const drift = interpolate(frame, [0, 200], [0, -14]);
  return (
    <Stage>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
        <Rise>
          <div style={{ transform: `translateY(${drift}px)`, borderRadius: 16, overflow: "hidden", border: `1px solid ${T.stroke}`, boxShadow: "0 50px 110px rgba(0,0,0,0.65)" }}>
            <Img src={staticFile("stills/idle.png")} style={{ width: 1150, display: "block" }} />
          </div>
        </Rise>
        <Rise delay={18}>
          <div style={{ marginTop: 44, textAlign: "center" }}>
            <div style={{ fontSize: 92, fontWeight: 700, color: T.text, letterSpacing: "-0.02em" }}>Attaché</div>
            <div style={{ fontSize: 38, color: T.gold, fontWeight: 600, marginTop: 6 }}>Fluent in agent. Speaks human.</div>
          </div>
        </Rise>
      </AbsoluteFill>
    </Stage>
  );
};

/* 3 — install: one download glides into Applications. Every surface is
   fully opaque so nothing ghosts through, and the graphic fills the frame. */
export const Install: React.FC = () => {
  const frame = useCurrentFrame();
  const glide = interpolate(frame, [30, 74], [0, 410], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const drop = interpolate(frame, [66, 84], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const landed = frame > 80;
  const tile: React.CSSProperties = {
    width: 340, height: 400, borderRadius: 30, boxSizing: "border-box",
    display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 18,
    boxShadow: "0 44px 90px rgba(0,0,0,0.62)",
  };
  return (
    <Stage>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 76 }}>
        <Rise>
          <Capsule fontSize={32}>github.com/danbryan/attache/releases</Capsule>
        </Rise>
        <div style={{ display: "flex", alignItems: "center", gap: 60, height: 420 }}>
          <Rise delay={8}>
            <div
              style={{
                ...tile, background: "#1C1C24", border: `1px solid ${T.stroke}`,
                transform: `translateX(${glide}px)`, opacity: drop,
              }}
            >
              <BrandMark size={150} />
              <div style={{ color: T.text, fontSize: 34, fontWeight: 700, marginTop: 8 }}>Attache.app</div>
              <div style={{ color: T.dim, fontSize: 24 }}>Signed · Notarized</div>
            </div>
          </Rise>
          <div style={{ fontSize: 96, fontWeight: 300, color: landed ? T.gold : T.faint, paddingBottom: 40 }}>→</div>
          <Rise delay={14}>
            <div
              style={{
                ...tile,
                background: landed ? "#23232D" : "#1C1C24",
                border: `1px solid ${landed ? T.gold : T.stroke}`,
              }}
            >
              <div style={{ fontSize: 150, lineHeight: 1 }}>📁</div>
              <div style={{ color: T.text, fontSize: 34, fontWeight: 700 }}>Applications</div>
            </div>
          </Rise>
        </div>
        <Rise delay={22}>
          <div style={{ color: T.dim, fontSize: 32 }}>One download · No account · No sign-up</div>
        </Rise>
      </AbsoluteFill>
    </Stage>
  );
};

/* 4 — onboarding: four choices, equal-height cards. */
export const Onboard: React.FC = () => {
  const steps = [
    { icon: "🗣️", title: "Voice", sub: "macOS · ElevenLabs · xAI" },
    { icon: "🎭", title: "Personality", sub: "Concise · Big Picture · yours" },
    { icon: "🧠", title: "Model", sub: "Ollama · Grok · Claude" },
    { icon: "📌", title: "Sources", sub: "Codex · Claude Code" },
  ];
  return (
    <Stage>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 74 }}>
        <Headline size={66}>Two minutes of setup</Headline>
        <div style={{ display: "flex", gap: 30, alignItems: "stretch" }}>
          {steps.map((s, i) => (
            <Rise key={s.title} delay={18 + i * 20}>
              <div
                style={{
                  width: 372, height: 300, boxSizing: "border-box", padding: "40px 28px",
                  borderRadius: 24, textAlign: "center", background: T.bgPanel,
                  border: `1px solid ${T.stroke}`,
                  display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 14,
                }}
              >
                <div style={{ fontSize: 62 }}>{s.icon}</div>
                <div style={{ fontSize: 38, fontWeight: 700, color: T.text }}>{s.title}</div>
                <div style={{ fontSize: 24, color: T.dim, lineHeight: 1.4 }}>{s.sub}</div>
              </div>
            </Rise>
          ))}
        </div>
        <Rise delay={110}>
          <div style={{ color: T.gold, fontSize: 32, fontWeight: 600 }}>
            Nothing runs until you turn a source on.
          </div>
        </Rise>
      </AbsoluteFill>
    </Stage>
  );
};

/* 5 — pin a session with ⌘K. */
export const Pin: React.FC = () => {
  const frame = useCurrentFrame();
  const rows = [
    { name: "payments-refactor", src: "Claude Code", picked: true },
    { name: "media-center deploy", src: "Codex", picked: false },
    { name: "docs sweep", src: "Claude Code", picked: false },
  ];
  const pinned = frame > 80;
  return (
    <Stage>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 60 }}>
        <div style={{ display: "flex", gap: 22 }}>
          <KeyCap label="⌘" pressAt={14} wide />
          <KeyCap label="K" pressAt={14} />
        </div>
        <Rise delay={26}>
          <div style={{ width: 900, borderRadius: 20, background: T.bgPanel, border: `1px solid ${T.stroke}`, overflow: "hidden", boxShadow: "0 40px 90px rgba(0,0,0,0.6)" }}>
            <div style={{ padding: "22px 28px", borderBottom: `1px solid ${T.stroke}`, color: T.dim, fontSize: 30 }}>
              Find a session… <span style={{ color: T.text }}>pay▍</span>
            </div>
            {rows.map((r, i) => (
              <div
                key={r.name}
                style={{
                  display: "flex", justifyContent: "space-between", alignItems: "center",
                  padding: "20px 28px", fontSize: 30,
                  background: r.picked && frame > 56 ? T.goldSoft : "transparent",
                }}
              >
                <div style={{ color: T.text }}>
                  {r.name}
                  <span style={{ color: T.faint, fontSize: 24, marginLeft: 16 }}>{r.src}</span>
                </div>
                <div style={{ display: "flex", alignItems: "center", gap: 9, color: r.picked && pinned ? T.gold : T.faint, fontSize: 30 }}>
                  {r.picked && pinned ? (
                    <>
                      <svg width="20" height="22" viewBox="0 0 24 24" fill="currentColor"><path d="M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z"/></svg>
                      pinned
                    </>
                  ) : ""}
                </div>
              </div>
            ))}
          </div>
        </Rise>
        <Rise delay={96}>
          <div style={{ color: T.dim, fontSize: 31 }}>
            Attaché only speaks about sessions <span style={{ color: T.gold, fontWeight: 600 }}>you pin</span>.
          </div>
        </Rise>
      </AbsoluteFill>
    </Stage>
  );
};
