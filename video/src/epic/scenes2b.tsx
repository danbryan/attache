import React from "react";
import { AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { T, FPS } from "../theme";
import { Stage, BrandMark, Capsule } from "../components";
import {
  Particles, LightSweep, Camera, Terminal, TermLine, AppWindow, StatusRow,
  Composer, WordSweep, GlassChip, IconLock, IconCheck, IconCycle, WaveBars, typed as typeSlice,
} from "./components2";
import { twoway, trust, outro, f, karaokeEnd, ssec, stext } from "./timing2";

/* ------------------------------------------------------------------ */
/* 5 — TWO-WAY: tell the agent its next move; every indicator is real. */
/* ------------------------------------------------------------------ */

const INSTRUCTION = "Rerun both flaky tests and pin the error rate to the dashboard.";
const TARGET = "Codex · payments-refactor";

export const TwoWay2: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const chipFlipF = f(twoway.chipFlipAt);
  const typedF = f(twoway.typedAt);
  const typedDurF = f(twoway.typedDur);
  const confirmF = f(twoway.confirmAt);
  const sendPressF = f(twoway.sendPressAt);
  const queuedF = f(twoway.queuedAt);
  const quietF = f(twoway.quietAt);
  const deliverTypeF = f(twoway.deliverTypeAt);
  const deliveredF = f(twoway.deliveredAt);
  const waitingF = f(twoway.waitingAt);
  const replyPrintF = f(twoway.replyPrintAt);
  const replyCardF = f(twoway.replyCardAt);
  const replySpeakF = f(twoway.replySpeakAt);

  // The left terminal: busy, then quiet, then the instruction lands, then the reply.
  const termLines: TermLine[] = [
    { at: 0, text: "▸ codex — payments-refactor" },
    { at: 8, text: "▸ tidying retry helpers…" },
    { at: Math.round(quietF * 0.55), text: "▸ formatting + lint pass…" },
    { at: quietF, text: "✓ turn complete — session quiet", color: "#30D158" },
    { at: deliverTypeF, text: `> attaché: ${INSTRUCTION}`, color: "#FF9F0A", type: true },
    { at: replyPrintF, text: "▸ rerunning payment_retry … PASS", color: T.dim },
    { at: replyPrintF + 12, text: "▸ rerunning s3_upload … PASS", color: T.dim },
    { at: replyPrintF + 24, text: "codex: Both green. Error rate pinned to the dashboard.", color: "#30D158" },
  ];

  const composerTyped = typeSlice(INSTRUCTION, frame, typedF, typedDurF);
  const agentMode = frame >= chipFlipF;

  // Status row: the real CallPhase walk, including the counters.
  const queuedSecs = Math.max(1, Math.floor((frame - queuedF) / FPS) + 1);
  const waitingSecs = Math.max(1, Math.floor((frame - deliveredF) / FPS) + 1);
  let status: React.ReactNode = null;
  if (frame >= queuedF && frame < deliveredF) {
    status = <StatusRow icon="spinner" text={`Sending to Codex when the session is quiet… ${queuedSecs}s`} />;
  } else if (frame >= deliveredF && frame < waitingF) {
    status = <StatusRow icon="check" emphasis text="Sent to Codex · watching for the reply" />;
  } else if (frame >= waitingF && frame < replyCardF + 10) {
    status = <StatusRow icon="spinner" text={`Waiting for Codex to reply… ${waitingSecs}s`} />;
  }
  // After the reply is linked, the row goes idle — exactly like the app.

  const confirmP = spring({ frame: frame - confirmF, fps, config: { damping: 16, mass: 0.8 } });
  const confirmGone = interpolate(frame, [sendPressF + 8, sendPressF + 18], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const pressed = frame >= sendPressF && frame < sendPressF + 10;
  const replyP = spring({ frame: frame - replyCardF, fps, config: { damping: 15, mass: 0.9 } });
  const replySpeaking = frame >= replySpeakF;

  return (
    <Stage>
      <Particles count={26} />
      <Camera from={1} to={1.035} over={f(twoway.len)}>
        <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
          <div style={{ display: "flex", gap: 46, alignItems: "stretch" }}>
            {/* Left: the real session receiving the send */}
            <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
              <Terminal width={840} title="codex — payments-refactor" lines={termLines} tilt={4} minHeight={430} fontSize={21} />
            </div>

            {/* Right: Attaché mid-call */}
            <AppWindow width={880} live style={{ alignSelf: "center" }}>
              <div style={{ padding: "26px 28px 28px", display: "flex", flexDirection: "column", gap: 20, minHeight: 470, justifyContent: "flex-end" }}>
                {/* Confirmation card */}
                {frame >= confirmF && confirmGone > 0 && (
                  <div
                    style={{
                      borderRadius: 16, padding: "22px 26px",
                      background: "rgba(255,159,10,0.08)", border: "1px solid rgba(255,159,10,0.5)",
                      opacity: confirmP * confirmGone,
                      transform: `translateY(${(1 - confirmP) * 36}px)`,
                    }}
                  >
                    <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 12 }}>
                      <IconLock size={20} color="#FF9F0A" />
                      <span style={{ color: "#FF9F0A", fontSize: 22, fontWeight: 700 }}>Send to {TARGET}?</span>
                    </div>
                    <div style={{ color: T.text, fontSize: 24, lineHeight: 1.45, marginBottom: 18 }}>“{INSTRUCTION}”</div>
                    <div style={{ display: "flex", gap: 12, justifyContent: "flex-end" }}>
                      <span style={{ padding: "9px 22px", borderRadius: 11, background: "rgba(255,255,255,0.07)", color: T.dim, fontSize: 21, fontWeight: 600 }}>Cancel</span>
                      <span
                        style={{
                          padding: "9px 26px", borderRadius: 11, fontSize: 21, fontWeight: 700,
                          background: pressed ? "#FFB84D" : "#FF9F0A", color: "#1A1104",
                          transform: pressed ? "scale(0.94)" : "none",
                          boxShadow: pressed ? "0 0 30px rgba(255,159,10,0.7)" : "0 4px 18px rgba(255,159,10,0.35)",
                        }}
                      >
                        Send
                      </span>
                    </div>
                  </div>
                )}

                {/* Reply card */}
                {frame >= replyCardF && (
                  <div
                    style={{
                      borderRadius: 16, padding: "22px 26px",
                      background: "rgba(10,132,255,0.09)", border: `1px solid ${T.gold}`,
                      boxShadow: "0 0 46px rgba(10,132,255,0.18)",
                      opacity: replyP,
                      transform: `translateY(${(1 - replyP) * 36}px)`,
                    }}
                  >
                    <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 12 }}>
                      <span style={{ color: T.gold, fontSize: 21, fontWeight: 700 }}>Reply from Codex</span>
                      <span style={{ color: T.faint, fontSize: 18 }}>· just now</span>
                      {replySpeaking && <div style={{ marginLeft: "auto" }}><WaveBars n={12} height={20} barWidth={4} /></div>}
                    </div>
                    <WordSweep
                      text={stext("va_reply")}
                      startFrame={replySpeakF + 2}
                      endFrame={replySpeakF + karaokeEnd(ssec("va_reply"))}
                      fontSize={25}
                    />
                  </div>
                )}

                <Composer
                  width={820}
                  destination={agentMode ? "agent" : "attache"}
                  target={TARGET}
                  typed={frame >= sendPressF + 14 ? "" : composerTyped}
                  caret={frame >= typedF && frame < sendPressF}
                  status={status}
                />
              </div>
            </AppWindow>
          </div>
        </AbsoluteFill>
      </Camera>
      <LightSweep start={deliveredF} dur={36} opacity={0.08} />
    </Stage>
  );
};

/* ------------------------------------------------------------------ */
/* 6 — TRUST: three glass chips, the reliability story.                */
/* ------------------------------------------------------------------ */

export const Trust2: React.FC = () => {
  return (
    <Stage>
      <Particles count={40} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 54 }}>
        <div style={{ fontSize: 60, fontWeight: 700, color: T.text, letterSpacing: "-0.02em" }}>
          Built to be <span style={{ color: T.gold }}>trusted</span>
        </div>
        <div style={{ display: "flex", gap: 34 }}>
          <GlassChip
            delay={f(trust.chipsAt[0])}
            icon={<IconLock size={40} color="#FF9F0A" />}
            title="Locked targets"
            sub="Every send is confirmed and frozen to one session. On any mismatch, it fails closed."
          />
          <GlassChip
            delay={f(trust.chipsAt[1])}
            icon={<IconCheck size={40} />}
            title="Proven delivery"
            sub="Delivery isn't assumed. It's parsed, verified, and visible at every step."
          />
          <GlassChip
            delay={f(trust.chipsAt[2])}
            icon={<IconCycle size={40} />}
            title="Live fallback"
            sub="A model taps out mid call? A backup steps in, and the conversation keeps moving."
          />
        </div>
      </AbsoluteFill>
      <LightSweep start={f(trust.chipsAt[2]) + 14} dur={46} opacity={0.07} />
    </Stage>
  );
};

/* ------------------------------------------------------------------ */
/* 7 — OUTRO: rays, the mark, the tagline, where to get it.            */
/* ------------------------------------------------------------------ */

export const Outro2: React.FC = () => {
  const frame = useCurrentFrame();
  const breathe = 0.94 + 0.05 * Math.sin(frame / 20);
  const raysIn = interpolate(frame, [0, 40], [0, 0.5], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return (
    <Stage>
      {/* slow rotating rays */}
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", opacity: raysIn }}>
        <div
          style={{
            width: 1700, height: 1700, borderRadius: 999,
            background: `conic-gradient(from ${frame * 0.12}deg, transparent 0deg, rgba(10,132,255,0.05) 12deg, transparent 26deg, transparent 60deg, rgba(10,132,255,0.045) 74deg, transparent 90deg, transparent 130deg, rgba(10,132,255,0.05) 145deg, transparent 160deg, transparent 210deg, rgba(10,132,255,0.045) 226deg, transparent 245deg, transparent 300deg, rgba(10,132,255,0.05) 315deg, transparent 330deg)`,
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
        <div style={{ fontSize: 66, fontWeight: 700, color: T.text, letterSpacing: "-0.02em", textAlign: "center" }}>
          Fluent in agent. <span style={{ color: T.gold }}>Speaks human.</span>
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
