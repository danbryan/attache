import React from "react";
import { AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { T } from "../theme";
import { Stage, KeyCap } from "../components";
import {
  Aurora, Particles, LightSweep, Camera, Terminal, TermLine, MiniSession,
  AppWindow, SourceChip, WaveBars, MediaControls, WordSweep, Mark2,
} from "./components2";
import { hook, title, pin, inbox, f, karaokeEnd, ssec, stext } from "./timing2";

/* ------------------------------------------------------------------ */
/* 1 — HOOK: one agent finishes something… then the wall floods in.    */
/* ------------------------------------------------------------------ */

const TERM_A: TermLine[] = [
  { at: 6, text: "▸ cutting silence from episode 14…" },
  { at: 34, text: "▸ 5 strong segments found" },
  { at: 70, text: "▸ writing captions (3/5)…" },
  { at: 108, text: "✓ clips cut, captioned, queued", color: "#30D158" },
];

const WALL: { title: string; line: string }[] = [
  { title: "codex — newsletter draft", line: "▸ drafting section 3…" },
  { title: "claude — sponsor research", line: "▸ comparing 12 offers…" },
  { title: "codex — invoice reconciliation", line: "▸ matching 84 receipts…" },
  { title: "claude — shorts captions", line: "▸ captioning 9 clips…" },
  { title: "codex — thumbnail variants", line: "▸ rendering option C…" },
  { title: "claude — community replies", line: "▸ drafting 17 replies…" },
  { title: "codex — course outline", line: "▸ structuring module 4…" },
  { title: "claude — market brief", line: "▸ summarizing filings…" },
  { title: "codex — site refresh", line: "▸ rebuilding pages…" },
  { title: "claude — b-roll tagging", line: "▸ tagging 212 clips…" },
  { title: "codex — travel itinerary", line: "▸ holding two options…" },
  { title: "claude — inbox triage", line: "▸ sorting 63 threads…" },
];

export const Hook2: React.FC = () => {
  const frame = useCurrentFrame();
  const wallF = f(hook.wallAt);
  const lineF = f(hook.lineAt);
  const line2F = f(hook.line2At);
  const collapseF = f(hook.collapseAt);
  const collapse = interpolate(frame, [collapseF, collapseF + 30], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const dim = interpolate(frame, [lineF, lineF + 20], [1, 0.26], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const lineIn = interpolate(frame, [lineF + 6, lineF + 24], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  // The payoff line — Attaché's first mention — holds back through the
  // narration's dramatic pause, then lands on its own beat.
  const line2In = interpolate(frame, [line2F, line2F + 14], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  // The wall floods in: the hero terminal shrinks toward the top-left as the
  // grid fills the frame — "and it's not the only one."
  const shrink = interpolate(frame, [wallF, wallF + 26], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return (
    <Stage>
      <Aurora accent="blue" />
      <Particles count={38} />
      <Camera from={1} to={1.05} over={collapseF}>
        <AbsoluteFill style={{ opacity: dim * (1 - collapse), transform: `scale(${1 - collapse * 0.22})`, filter: collapse > 0 ? `blur(${collapse * 14}px)` : undefined }}>
          {/* hero session */}
          <div
            style={{
              position: "absolute",
              left: interpolate(shrink, [0, 1], [120, 480]),
              top: interpolate(shrink, [0, 1], [86, 300]),
              transform: `scale(${interpolate(shrink, [0, 1], [0.62, 1])})`,
              transformOrigin: "top left",
              zIndex: 2,
            }}
          >
            <Terminal width={860} title="claude — episode 14 clips" lines={TERM_A} tilt={shrink > 0.5 ? 5 : 0} minHeight={230} />
          </div>
          {/* the wall */}
          <AbsoluteFill style={{ padding: "308px 90px 64px", zIndex: 1 }}>
            <div style={{ display: "grid", gridTemplateColumns: "repeat(4, 1fr)", gap: 20, alignContent: "space-between", height: "100%" }}>
              {WALL.map((w, i) => (
                <MiniSession key={w.title} title={w.title} line={w.line} delay={wallF + 6 + i * 4} tint={i % 3 === 0 ? "122,92,255" : "10,132,255"} />
              ))}
            </div>
          </AbsoluteFill>
        </AbsoluteFill>
        <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", opacity: 1 - collapse }}>
          <div style={{ fontSize: 66, fontWeight: 700, color: T.text, textAlign: "center", letterSpacing: "-0.02em", lineHeight: 1.25, textShadow: "0 8px 60px rgba(0,0,0,0.9)" }}>
            <div style={{ opacity: lineIn }}>Your agents are talking.</div>
            <div style={{ opacity: line2In, transform: `scale(${0.94 + line2In * 0.06})`, color: T.gold, fontSize: 76, marginTop: 14, textShadow: `0 0 ${50 * line2In}px rgba(10,132,255,0.5), 0 8px 60px rgba(0,0,0,0.9)` }}>
              Attaché is listening.
            </div>
          </div>
        </AbsoluteFill>
      </Camera>
    </Stage>
  );
};

/* ------------------------------------------------------------------ */
/* 2 — TITLE: bars burst, the name blooms, the new tagline lands.      */
/* ------------------------------------------------------------------ */

export const Title2: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const barsF = f(title.barsAt);
  const nameF = f(title.nameAt);
  const tagF = f(title.tagAt);
  const nameP = spring({ frame: frame - nameF, fps, config: { damping: 15, mass: 1.1 } });
  const tagIn = interpolate(frame, [tagF, tagF + 16], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const glow = interpolate(frame, [nameF, nameF + 24, nameF + 70], [0, 1, 0.55], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return (
    <Stage>
      <Aurora accent="violet" />
      <Particles count={52} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 26 }}>
        <div style={{ filter: `drop-shadow(0 0 ${34 * glow}px rgba(10,132,255,0.45))` }}>
          <Mark2 size={330} buildFrom={barsF} talking />
        </div>
        <div
          style={{
            fontSize: 150, fontWeight: 700, color: T.text, letterSpacing: "-0.02em", lineHeight: 1,
            opacity: nameP,
            transform: `translateY(${(1 - nameP) * 46}px) scale(${0.94 + nameP * 0.06})`,
            textShadow: `0 0 ${80 * glow}px rgba(10,132,255,${0.55 * glow}), 0 10px 70px rgba(0,0,0,0.8)`,
          }}
        >
          Attaché
        </div>
        <div style={{ opacity: tagIn, transform: `translateY(${(1 - tagIn) * 18}px)`, fontSize: 44, color: T.gold, fontWeight: 600 }}>
          Gives your agents a voice.
        </div>
      </AbsoluteFill>
      <LightSweep start={nameF + 6} dur={34} opacity={0.14} />
    </Stage>
  );
};

/* ------------------------------------------------------------------ */
/* 3 — PIN: ⌘K, pin what it may speak about.                           */
/* ------------------------------------------------------------------ */

const PIN_ROWS = [
  { name: "episode 14 clips", src: "Claude Code", picked: true },
  { name: "newsletter draft", src: "Codex", picked: false },
  { name: "sponsor research", src: "Claude Code", picked: false },
];

export const Pin2: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const keysF = f(pin.keysAt);
  const paletteF = f(pin.paletteAt);
  const pinF = f(pin.pinAt);
  const paletteP = spring({ frame: frame - paletteF, fps, config: { damping: 16, mass: 0.8 } });
  const pinned = frame >= pinF;
  return (
    <Stage>
      <Aurora accent="blue" />
      <Particles count={28} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 52 }}>
        <div style={{ display: "flex", gap: 20 }}>
          <KeyCap label="⌘" pressAt={keysF + 8} wide />
          <KeyCap label="K" pressAt={keysF + 8} />
        </div>
        <div style={{ width: 940, borderRadius: 20, background: T.bgPanel, border: `1px solid ${T.stroke}`, overflow: "hidden", boxShadow: "0 40px 90px rgba(0,0,0,0.6)", opacity: paletteP, transform: `translateY(${(1 - paletteP) * 36}px)` }}>
          <div style={{ padding: "20px 28px", borderBottom: `1px solid ${T.stroke}`, color: T.dim, fontSize: 28 }}>
            Find a session… <span style={{ color: T.text }}>ep▍</span>
          </div>
          {PIN_ROWS.map((r, i) => (
            <div
              key={r.name}
              style={{
                display: "flex", justifyContent: "space-between", alignItems: "center",
                padding: "19px 28px", fontSize: 28,
                background: r.picked && frame > pinF - 16 ? T.goldSoft : "transparent",
                borderTop: i ? `1px solid ${T.stroke}` : "none",
              }}
            >
              <div style={{ color: T.text }}>
                {r.name}
                <span style={{ color: T.faint, fontSize: 22, marginLeft: 16 }}>{r.src}</span>
              </div>
              {r.picked && pinned && (
                <div style={{ display: "flex", alignItems: "center", gap: 9, color: T.gold, fontSize: 26 }}>
                  <svg width="19" height="21" viewBox="0 0 24 24" fill="currentColor"><path d="M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z"/></svg>
                  pinned
                </div>
              )}
            </div>
          ))}
        </div>
        <div style={{ color: T.dim, fontSize: 29 }}>
          Attaché only speaks about sessions <span style={{ color: T.gold, fontWeight: 600 }}>you pin</span>.
        </div>
      </AbsoluteFill>
      <LightSweep start={pinF} dur={44} opacity={0.06} />
    </Stage>
  );
};

/* ------------------------------------------------------------------ */
/* 4 — VOICEMAIL: cards, playback, real media controls, Recap.         */
/* ------------------------------------------------------------------ */

const MEMOS2 = [
  { title: "Episode 14 cut into five clips", sub: "claude — episode 14 clips", time: "just now", chip: "Claude Code", color: "#D97757" },
  { title: "Newsletter draft ready for review", sub: "codex — newsletter draft", time: "9m", chip: "Codex", color: "#8E8E93" },
  { title: "Q3 invoices reconciled, one flag", sub: "codex — invoice reconciliation", time: "24m", chip: "Codex", color: "#8E8E93" },
];

export const Inbox2: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const memoF = f(inbox.memoStart);
  const speedF = f(inbox.speedAt);
  const scrubF = f(inbox.scrubAt);
  const recapF = f(inbox.recapAt);
  const playing = frame >= memoF;
  const memoDurF = f(ssec("va_memo"));
  // The scrub jumps the progress bar forward — a visible seek.
  const baseProgress = interpolate(frame, [memoF, memoF + memoDurF], [0, 74], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const scrubBoost = interpolate(frame, [scrubF, scrubF + 6], [0, 14], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const progress = Math.min(96, baseProgress + scrubBoost);
  const speedActive = frame >= speedF;
  const recapGlow = frame >= recapF;
  const recapP = spring({ frame: frame - recapF, fps, config: { damping: 13, mass: 0.7 } });
  return (
    <Stage>
      <Aurora accent="teal" />
      <Particles count={26} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
        <AppWindow width={1220}>
          <div style={{ padding: "24px 30px 30px" }}>
            <div style={{ display: "flex", alignItems: "center", marginBottom: 20 }}>
              <span style={{ color: T.text, fontSize: 30, fontWeight: 700 }}>Inbox</span>
              <span style={{ marginLeft: 14, padding: "3px 13px", borderRadius: 999, background: T.goldSoft, border: `1px solid ${T.gold}`, color: T.gold, fontSize: 19, fontWeight: 700 }}>3 new</span>
              <div style={{ marginLeft: "auto", display: "flex", gap: 12 }}>
                <span style={{ padding: "7px 18px", borderRadius: 11, background: "rgba(255,255,255,0.07)", color: T.text, fontSize: 21, fontWeight: 600 }}>▶ Play all</span>
                <span
                  style={{
                    padding: "7px 18px", borderRadius: 11, fontSize: 21, fontWeight: 700,
                    background: recapGlow ? T.goldSoft : "rgba(255,255,255,0.07)",
                    border: `1px solid ${recapGlow ? T.gold : "transparent"}`,
                    color: recapGlow ? T.gold : T.text,
                    boxShadow: recapGlow ? `0 0 ${30 * Math.min(1, recapP)}px rgba(10,132,255,0.45)` : "none",
                    transform: recapGlow ? `scale(${1 + 0.06 * Math.min(1, recapP)})` : "none",
                  }}
                >
                  ✦ Recap
                </span>
              </div>
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
              {MEMOS2.map((mm, i) => {
                const inP = spring({ frame: frame - f(inbox.cardsAt[i]), fps, config: { damping: 17, mass: 0.8 } });
                const isPlaying = i === 0 && playing;
                return (
                  <div
                    key={mm.title}
                    style={{
                      padding: "20px 24px", borderRadius: 16,
                      background: isPlaying ? "rgba(10,132,255,0.10)" : "rgba(255,255,255,0.035)",
                      border: `1px solid ${isPlaying ? T.gold : T.stroke}`,
                      boxShadow: isPlaying ? "0 0 44px rgba(10,132,255,0.16)" : "none",
                      opacity: inP,
                      transform: `translateX(${(1 - inP) * 90}px)`,
                    }}
                  >
                    <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
                      <div style={{ width: 11, height: 11, borderRadius: 6, background: isPlaying ? T.gold : "rgba(10,132,255,0.85)", flexShrink: 0 }} />
                      <span style={{ color: T.text, fontSize: 26, fontWeight: 650 }}>{mm.title}</span>
                      <SourceChip label={mm.chip} color={mm.color} />
                      <span style={{ marginLeft: "auto", color: T.faint, fontSize: 20 }}>{mm.time}</span>
                    </div>
                    {!isPlaying && <div style={{ color: T.faint, fontSize: 20, marginTop: 6, marginLeft: 25, fontFamily: T.mono }}>{mm.sub}</div>}
                    {isPlaying && (
                      <div style={{ marginTop: 16 }}>
                        <div style={{ display: "flex", alignItems: "center", gap: 16 }}>
                          <div style={{ flex: 1, height: 6, borderRadius: 4, background: "rgba(255,255,255,0.1)" }}>
                            <div style={{ width: `${progress}%`, height: "100%", borderRadius: 4, background: T.gold }} />
                          </div>
                          <WaveBars n={12} height={22} barWidth={4} />
                        </div>
                        <div style={{ marginTop: 14, display: "flex", alignItems: "center", justifyContent: "space-between", gap: 20 }}>
                          <MediaControls playing speed={speedActive ? "1.5×" : "1.0×"} speedActive={speedActive} />
                        </div>
                        <div style={{ marginTop: 14 }}>
                          <WordSweep text={stext("va_memo")} startFrame={memoF + 2} endFrame={memoF + karaokeEnd(ssec("va_memo"))} fontSize={25} />
                        </div>
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          </div>
        </AppWindow>
      </AbsoluteFill>
      <LightSweep start={f(inbox.cardsAt[0])} dur={50} opacity={0.06} />
    </Stage>
  );
};
