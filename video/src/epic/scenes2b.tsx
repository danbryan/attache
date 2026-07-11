import React from "react";
import { AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig } from "remotion";
import { T, FPS } from "../theme";
import { Stage, BrandMark } from "../components";
import {
  Aurora, Particles, LightSweep, Camera, RingPulse, Terminal, TermLine, AppWindow,
  StatusRow, Composer, WordSweep, WaveBars, FloatingVerbs, typed as typeSlice,
} from "./components2";
import { ambient, live, twoway, f, karaokeEnd, ssec, stext } from "./timing2";

/* ------------------------------------------------------------------ */
/* 5 — AMBIENT: leave it in the corner; the activity heat map.         */
/* ------------------------------------------------------------------ */

// Verb sets rotate the way the real ActivityInsightHeatMap phrases shift
// with the focused session's tool activity.
const VERBS_EARLY = [
  { text: "rendering clips", weight: 0.95, color: "#0A84FF" },
  { text: "reading files", weight: 0.5, color: "#7A5CFF" },
  { text: "writing captions", weight: 0.78, color: "#0A84FF" },
  { text: "checking calendar", weight: 0.4, color: "#00C7BE" },
  { text: "sorting inbox", weight: 0.58, color: "#7A5CFF" },
  { text: "running tests", weight: 0.66, color: "#0A84FF" },
  { text: "browsing sponsors", weight: 0.34, color: "#00C7BE" },
  { text: "committing changes", weight: 0.45, color: "#7A5CFF" },
];
const VERBS_LATE = [
  { text: "uploading renders", weight: 0.9, color: "#0A84FF" },
  { text: "tagging b-roll", weight: 0.62, color: "#7A5CFF" },
  { text: "scheduling posts", weight: 0.84, color: "#0A84FF" },
  { text: "reconciling invoices", weight: 0.5, color: "#00C7BE" },
  { text: "drafting replies", weight: 0.44, color: "#7A5CFF" },
  { text: "summarizing filings", weight: 0.58, color: "#0A84FF" },
  { text: "reading files", weight: 0.3, color: "#00C7BE" },
  { text: "checking analytics", weight: 0.68, color: "#7A5CFF" },
];

export const Ambient2: React.FC = () => {
  const frame = useCurrentFrame();
  const swapF = f(ambient.len / 2);
  const verbs = frame < swapF ? VERBS_EARLY : VERBS_LATE;
  const breathe = 0.97 + 0.03 * Math.sin(frame / 22);
  return (
    <Stage>
      <Aurora accent="blue" strength={0.8} />
      <Particles count={24} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
        <AppWindow width={1240} style={{ height: 660 }}>
          <div style={{ position: "relative", height: 610 }}>
            {/* unread pill on the left edge, like the real idle window */}
            <div style={{ position: "absolute", left: 26, top: "44%", display: "flex", flexDirection: "column", alignItems: "center", gap: 6 }}>
              <div style={{ padding: "3px 11px", borderRadius: 999, border: `1.5px solid ${T.gold}`, color: T.gold, fontSize: 18, fontWeight: 700 }}>4</div>
              <div style={{ width: 3, height: 52, borderRadius: 2, background: T.gold, opacity: 0.8 }} />
            </div>
            <FloatingVerbs phrases={verbs} />
            <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
              <div style={{ transform: `scale(${breathe})` }}>
                <BrandMark size={190} animate={false} />
              </div>
            </AbsoluteFill>
          </div>
        </AppWindow>
      </AbsoluteFill>
      <LightSweep start={12} dur={60} opacity={0.05} />
    </Stage>
  );
};

/* ------------------------------------------------------------------ */
/* 6 — LIVE: talk to it; the composer shows what it's doing, unnarrated. */
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
      <Aurora accent="violet" strength={0.9} />
      <Particles count={26} />
      <RingPulse at={composerF} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", opacity: windowIn }}>
        <AppWindow width={1180} live={frame >= composerF}>
          <div style={{ padding: "30px 34px 30px", display: "flex", flexDirection: "column", gap: 26, minHeight: 430, justifyContent: "space-between" }}>
            <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 24, paddingTop: 16 }}>
              <BrandMark size={110} animate={speaking} barColor={speaking ? (i) => `rgba(10,132,255,${0.45 + 0.05 * i})` : undefined} />
              {frame >= listenF && frame < thinkF && (
                <>
                  <WaveBars n={26} height={30} color="rgba(242,242,245,0.75)" />
                  <div style={{ color: T.text, fontSize: 27, fontWeight: 600 }}>“Which clip performed best?”</div>
                </>
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
              {frame >= composerF && <Composer width={1050} destination="attache" status={status} />}
            </div>
          </div>
        </AppWindow>
      </AbsoluteFill>
      <LightSweep start={composerF} dur={44} opacity={0.07} />
    </Stage>
  );
};

/* ------------------------------------------------------------------ */
/* 7 — TWO-WAY: tell the agent its next move; the indicators are real. */
/* ------------------------------------------------------------------ */

const INSTRUCTION = "Post clip two and schedule the rest, one a day at nine.";
const TARGET = "Codex · episode 14 pipeline";

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

  const termLines: TermLine[] = [
    { at: 0, text: "▸ codex — episode 14 pipeline" },
    { at: 8, text: "▸ exporting caption files…" },
    { at: Math.round(quietF * 0.55), text: "▸ uploading renders…" },
    { at: quietF, text: "✓ turn complete — session quiet", color: "#30D158" },
    { at: deliverTypeF, text: `> attaché: ${INSTRUCTION}`, color: "#FF9F0A", type: true },
    { at: replyPrintF, text: "▸ posting clip 2 … done", color: T.dim },
    { at: replyPrintF + 12, text: "▸ scheduling 4 posts … done", color: T.dim },
    { at: replyPrintF + 24, text: "codex: Clip two is posted. Four scheduled, daily at 9:00.", color: "#30D158" },
  ];

  const composerTyped = typeSlice(INSTRUCTION, frame, typedF, typedDurF);
  const agentMode = frame >= chipFlipF;

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
      <Aurora accent="ember" strength={0.7} />
      <Particles count={22} />
      <Camera from={1} to={1.035} over={f(twoway.len)}>
        <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
          <div style={{ display: "flex", gap: 46, alignItems: "stretch" }}>
            <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
              <Terminal width={840} title="codex — episode 14 pipeline" lines={termLines} tilt={4} minHeight={430} fontSize={21} />
            </div>

            <AppWindow width={880} live style={{ alignSelf: "center" }}>
              <div style={{ padding: "26px 28px 28px", display: "flex", flexDirection: "column", gap: 20, minHeight: 470, justifyContent: "flex-end" }}>
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
