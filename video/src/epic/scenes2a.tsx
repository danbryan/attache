import React from "react";
import { AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { T, FPS } from "../theme";
import { Stage, BrandMark, Capsule } from "../components";
import {
  Particles, LightSweep, Camera, RingPulse, Terminal, TermLine,
  AppWindow, SourceChip, WaveBars, StatusRow, Composer, WordSweep,
} from "./components2";
import { hook, title, inbox, live, f, karaokeEnd, ssec, stext, ntext } from "./timing2";

/* ------------------------------------------------------------------ */
/* 1 — HOOK: three agent terminals grinding away in the dark.          */
/* ------------------------------------------------------------------ */

const TERM_A: TermLine[] = [
  { at: 6, text: "▸ refactoring payments/retry.ts …" },
  { at: 34, text: "▸ 214 files scanned, 3 candidates" },
  { at: 70, text: "▸ running tests (147/211)…" },
  { at: 130, text: "▸ tests green — writing summary" },
  { at: 190, text: "✓ turn complete", color: "#30D158" },
];
const TERM_B: TermLine[] = [
  { at: 20, text: "▸ building docs site…" },
  { at: 80, text: "▸ 42 pages rendered" },
  { at: 150, text: "▸ deploying preview…" },
];
const TERM_C: TermLine[] = [
  { at: 40, text: "▸ migrating schema, step 3/7" },
  { at: 110, text: "▸ backfilling rows (12%)…" },
];

export const Hook2: React.FC = () => {
  const frame = useCurrentFrame();
  const collapseF = f(hook.collapseAt);
  const collapse = interpolate(frame, [collapseF, collapseF + 30], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  // The reframe line lands as the narration turns ("Your agents are talking…").
  const dimF = f(hook.narrStart + 7.2);
  const dim = interpolate(frame, [dimF, dimF + 20], [1, 0.3], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const lineIn = interpolate(frame, [dimF + 8, dimF + 26], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const drift = frame * 0.14;
  return (
    <Stage>
      <Particles count={40} />
      <Camera from={1} to={1.07} over={collapseF}>
        <AbsoluteFill style={{ opacity: dim * (1 - collapse), transform: `scale(${1 - collapse * 0.24})`, filter: collapse > 0 ? `blur(${collapse * 14}px)` : undefined }}>
          <div style={{ position: "absolute", left: 130, top: 190 - drift * 0.4 }}>
            <Terminal width={780} title="codex — payments-refactor" lines={TERM_A} tilt={7} minHeight={260} />
          </div>
          <div style={{ position: "absolute", right: 120, top: 120 - drift * 0.7, opacity: 0.82 }}>
            <Terminal width={640} title="claude — docs sweep" lines={TERM_B} tilt={-9} minHeight={200} fontSize={20} />
          </div>
          <div style={{ position: "absolute", right: 300, bottom: 110 + drift * 0.3, opacity: 0.62 }}>
            <Terminal width={560} title="codex — schema migration" lines={TERM_C} tilt={-5} minHeight={150} fontSize={19} />
          </div>
        </AbsoluteFill>
        <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", opacity: lineIn * (1 - collapse) }}>
          <div style={{ fontSize: 66, fontWeight: 700, color: T.text, textAlign: "center", letterSpacing: "-0.02em", lineHeight: 1.25, textShadow: "0 8px 60px rgba(0,0,0,0.9)" }}>
            Your agents are talking.
            <br />
            <span style={{ color: T.dim }}>You're just not listening.</span>
          </div>
        </AbsoluteFill>
      </Camera>
    </Stage>
  );
};

/* ------------------------------------------------------------------ */
/* 2 — TITLE: equalizer bars burst up, the name blooms with a sweep.   */
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
  const barHs = [0.36, 0.58, 0.78, 0.5, 0.95, 0.68, 1.0, 0.62, 0.85, 0.48, 0.34];
  return (
    <Stage>
      <Particles count={52} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 40 }}>
        <div style={{ display: "flex", alignItems: "flex-end", gap: 13, height: 200 }}>
          {barHs.map((h, i) => {
            const p = spring({ frame: frame - barsF - i * 2, fps, config: { damping: 12, mass: 0.7 } });
            const wave = 0.72 + 0.28 * Math.sin(frame / 5 + i * 1.1);
            return (
              <div
                key={i}
                style={{
                  width: 22, borderRadius: 12,
                  height: Math.max(10, 200 * h * p * wave),
                  background: `linear-gradient(180deg, rgba(10,132,255,${0.55 + 0.04 * i}), rgba(10,132,255,0.16))`,
                  boxShadow: `0 0 ${26 * p}px rgba(10,132,255,0.4)`,
                }}
              />
            );
          })}
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
        <div style={{ opacity: tagIn, transform: `translateY(${(1 - tagIn) * 18}px)`, fontSize: 42, color: T.gold, fontWeight: 600 }}>
          Fluent in agent. Speaks human.
        </div>
      </AbsoluteFill>
      <LightSweep start={nameF + 6} dur={34} opacity={0.14} />
    </Stage>
  );
};

/* ------------------------------------------------------------------ */
/* 3 — VOICEMAIL: the inbox fills, one memo plays with captions.       */
/* ------------------------------------------------------------------ */

const MEMOS2 = [
  { title: "Payments refactor complete", sub: "codex — payments-refactor", time: "just now", chip: "Codex", color: "#8E8E93" },
  { title: "Docs preview deployed", sub: "claude — docs sweep", time: "6m", chip: "Claude Code", color: "#D97757" },
  { title: "Schema migration checkpoint", sub: "codex — schema migration", time: "18m", chip: "Codex", color: "#8E8E93" },
];

export const Inbox2: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const memoF = f(inbox.memoStart);
  const playing = frame >= memoF;
  const memoDurF = f(ssec("va_memo"));
  const progress = interpolate(frame, [memoF, memoF + memoDurF], [0, 100], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const zoom = interpolate(frame, [memoF - 10, memoF + 25], [1, 1.045], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return (
    <Stage>
      <Particles count={30} />
      <Camera from={1} to={1.03} over={f(inbox.len)}>
        <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", transform: `scale(${zoom})` }}>
          <AppWindow width={1180}>
            <div style={{ padding: "24px 30px 30px" }}>
              <div style={{ display: "flex", alignItems: "center", marginBottom: 20 }}>
                <span style={{ color: T.text, fontSize: 30, fontWeight: 700 }}>Inbox</span>
                <span style={{ marginLeft: 14, padding: "3px 13px", borderRadius: 999, background: T.goldSoft, border: `1px solid ${T.gold}`, color: T.gold, fontSize: 19, fontWeight: 700 }}>3 new</span>
                <div style={{ marginLeft: "auto", display: "flex", gap: 12 }}>
                  <span style={{ padding: "7px 18px", borderRadius: 11, background: "rgba(255,255,255,0.07)", color: T.text, fontSize: 21, fontWeight: 600 }}>▶ Play all</span>
                  <span style={{ padding: "7px 18px", borderRadius: 11, background: "rgba(255,255,255,0.07)", color: T.text, fontSize: 21, fontWeight: 600 }}>✦ Recap</span>
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
                            <span style={{ color: T.gold, fontSize: 24 }}>▶</span>
                            <div style={{ flex: 1, height: 6, borderRadius: 4, background: "rgba(255,255,255,0.1)" }}>
                              <div style={{ width: `${progress}%`, height: "100%", borderRadius: 4, background: T.gold }} />
                            </div>
                            <WaveBars n={14} height={22} barWidth={4} />
                            <span style={{ color: T.dim, fontSize: 19, fontVariantNumeric: "tabular-nums" }}>1.0×</span>
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
      </Camera>
      <LightSweep start={f(inbox.cardsAt[0])} dur={50} opacity={0.06} />
    </Stage>
  );
};

/* ------------------------------------------------------------------ */
/* 4 — LIVE: go live; the composer walks the real call phases.         */
/* ------------------------------------------------------------------ */

export const Live2: React.FC = () => {
  const frame = useCurrentFrame();
  const composerF = f(live.composerAt);
  const listenF = f(live.listenAt);
  const thinkF = f(live.thinkAt);
  const prepF = f(live.prepAt);
  const speakF = f(live.speakAt);
  const thinkSecs = Math.max(1, Math.floor((frame - thinkF) / FPS) + 1);
  const windowIn = interpolate(frame, [0, 14], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });

  let status: React.ReactNode = null;
  if (frame >= speakF) status = <StatusRow icon="speaker" text="Speaking…" />;
  else if (frame >= prepF) status = <StatusRow icon="waveform" text="Preparing audio…" />;
  else if (frame >= thinkF) status = <StatusRow icon="spinner" text={`Thinking… ${thinkSecs}s`} />;
  else if (frame >= listenF) status = <StatusRow icon="mic" text="Listening…" />;

  const speaking = frame >= speakF;
  return (
    <Stage>
      <Particles count={30} />
      <RingPulse at={composerF} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", opacity: windowIn }}>
        <AppWindow width={1180} live={frame >= composerF}>
          <div style={{ padding: "30px 34px 30px", display: "flex", flexDirection: "column", gap: 26, minHeight: 430, justifyContent: "space-between" }}>
            <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 24, paddingTop: 16 }}>
              <BrandMark size={110} animate={speaking} barColor={speaking ? (i) => `rgba(10,132,255,${0.45 + 0.05 * i})` : undefined} />
              {frame >= listenF && frame < thinkF && (
                <div style={{ display: "flex", alignItems: "center", gap: 14, color: T.dim, fontSize: 23 }}>
                  <WaveBars n={26} height={30} color="rgba(242,242,245,0.75)" />
                </div>
              )}
              {frame >= listenF && frame < thinkF && (
                <div style={{ color: T.text, fontSize: 27, fontWeight: 600 }}>“Which tests were still flaky?”</div>
              )}
              {speaking && (
                <div style={{ width: 900 }}>
                  <WordSweep
                    text={stext("va_live")}
                    startFrame={speakF + 2}
                    endFrame={speakF + karaokeEnd(ssec("va_live"))}
                    fontSize={30}
                    align="center"
                  />
                </div>
              )}
            </div>
            <div style={{ display: "flex", justifyContent: "center" }}>
              {frame >= composerF && (
                <Composer width={1050} destination="attache" status={status} />
              )}
            </div>
          </div>
        </AppWindow>
      </AbsoluteFill>
      <LightSweep start={composerF} dur={44} opacity={0.07} />
    </Stage>
  );
};

export const HOOK_TEXT = ntext("n_hook");
